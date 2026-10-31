#!/system/bin/sh
# ============================================================
# Falling-MT6991 公共函数库
# 被 customize.sh / service.sh / bin/* 共同 source。
# 所有 sysfs 写入带权限解锁兜底(G1: 收紧为 root 属主 644,
# 不再 chmod 666 开放给所有进程; mt6991 上 cpufreq 节点属主
# system:system 0444, root 直写被拒, 解锁后成功)。
# ============================================================
# 必须用 ${VAR:-}: 调用方开 set -u 时, 未定义变量会直接终止被 source 的脚本
[ -n "${_PMK69_COMMON:-}" ] && return 0 2>/dev/null || true
_PMK69_COMMON=1

# 独立运行 lib/*.sh 时 MODDIR 回退到模块根(如 service.sh 已设则保留)
MODDIR="${MODDIR:-$(dirname "$(dirname "$0")")}"
PMK_ID="falling-mt6991"
PMK_DATA_DIR="${PMK_DATA_DIR:-/data/adb/modules/$PMK_ID}"
PMK_CONFIG_DIR="${PMK_CONFIG_DIR:-$PMK_DATA_DIR/config}"
PMK_RUNTIME_DIR="$PMK_CONFIG_DIR/runtime"
PMK_LOG_FILE="${PMK_LOG_FILE:-/data/local/tmp/falling_mt6991.log}"
PMK_TAG="Falling-MT6991"

# 运行时状态(与配置隔离)
PMK_CONTROL_FILE="$PMK_RUNTIME_DIR/control"

# 确保运行时目录存在
# 目录已存在就不起子进程: 这个函数每次决策要调 3~4 次(状态/遥测/统计各一次),
# 旧写法每次一个 mkdir, 稳态下每 5 秒白扔 3 次 fork。
runtime_dir() { [ -d "$PMK_RUNTIME_DIR" ] || mkdir -p "$PMK_RUNTIME_DIR" 2>/dev/null; runtime_fmt_check; }

# ---------- 运行时文件格式版本 ----------
# 为什么要版本: runtime/ 里的文件(cluster.map / cpu.sample / thermal.base /
# smart.state ...)是跨版本保留的。改过它们的字段分隔符或结构之后, 旧文件会被
# 新代码当成新格式解析 —— 实机踩过: cluster.map 从 "|" 改成 "," 之后, 旧缓存
# 被按逗号切, pol 整个串没切开, 循环既不推进也不退出, 守护进程直接死循环卡死。
# 所以任何改动 runtime 文件结构的地方, 必须把 PMK_FMT_VER 加 1。
# 校验在 runtime_dir() 里做, 进程内只查一次。
# v3.1 -> 3: 新增 loop.state / cap.base / cap.state / cap.target / cap.execmax
# v3.6 -> 4: smart.state / smart.trace 新增 psi 字段(CPU 争用)
PMK_FMT_VER="4"
PMK_FMT_OK=0

# 格式对不上(升级/首次运行)就把 runtime 里的旧文件内容清空。
# 用「移走」而不是「截断」: 截断后文件仍然存在([ -f ] 为真),
# 而 sched.sh 的 sched_reassert 会因为 [ -f "$STARGET" ] 为真却读到空内容,
# 误判成"目标表已构建但无漂移", 导致漂移自愈静默失效。
# 移走 = 真正让文件不存在, 与删除语义一致。
# 目录一律跳过(daemon.lock 由它自己的 pid 存活判定处理)。
runtime_fmt_check() {
  [ "$PMK_FMT_OK" = 1 ] && return 0
  local v="" f
  [ -f "$PMK_RUNTIME_DIR/.fmt" ] && read -r v < "$PMK_RUNTIME_DIR/.fmt" 2>/dev/null
  if [ "$v" != "$PMK_FMT_VER" ]; then
    for f in "$PMK_RUNTIME_DIR"/* "$PMK_RUNTIME_DIR"/.[!.]*; do
      [ -e "$f" ] || continue
      [ -d "$f" ] && continue
      case "$f" in *"/.[!.]*"|*"/\*") continue ;; esac   # glob 未匹配时的字面量
      : > "$f" 2>/dev/null
      mv "$f" "$f.old" 2>/dev/null
    done
    printf '%s\n' "$PMK_FMT_VER" > "$PMK_RUNTIME_DIR/.fmt" 2>/dev/null
  fi
  PMK_FMT_OK=1
  return 0
}

# 读全局开关(config/system.conf); $1=key $2=默认
# 注意: 走 grep|cut|head 三次 fork; 只为兼容老调用点保留, 守护内循环请用 cfg_get
sys_opt() {
  grep "^$1=" "$PMK_CONFIG_DIR/system.conf" 2>/dev/null | cut -d= -f2- | head -1
}

# 零 fork 读 system.conf 单项 -> 结果放 _CFG_VAL
# 守护进程每轮都要判开关(触控/游戏模式), 用 sys_opt 等于每轮 3 次 fork,
# 内建 read 扫一个二十来行的小文件成本远低于 fork。
cfg_get() {
  _CFG_VAL=""
  [ -f "$PMK_CONFIG_DIR/system.conf" ] || return 1
  local line
  while IFS= read -r line; do
    case "$line" in
      "$1="*) _CFG_VAL="${line#*=}"; return 0 ;;
    esac
  done < "$PMK_CONFIG_DIR/system.conf" 2>/dev/null
  return 0
}

# 零 fork 读整个文本文件 -> 结果放 _FILE_BUF(用于配置变更检测)
file_slurp() {
  _FILE_BUF=""
  [ -f "$1" ] || return 1
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    _FILE_BUF="$_FILE_BUF$line
"
  done < "$1" 2>/dev/null
  return 0
}

# ---------- 写文件(幂等, 失败不断链) ----------
# 直写失败 -> 权限解锁(chown root:root + chmod 644)重试 -> 仍失败记日志。
# 记录改动前后值, 便于审计。
write_file() {
  local file="$1"; shift
  [ -n "$file" ] && [ -e "$file" ] || return 1
  # v3.0: 读写全走内建, 不再 $(cat) —— 一次切档要写十几到几十个节点,
  #       每次两个命令替换就是几十次 fork, 是"切档要 1~2 秒"的主要来源
  local before="" after="" want="$*"
  read -r before < "$file" 2>/dev/null
  # v7.0.1 幂等: 值相同直接跳过(省 sysfs 写 + 回读, 消除无谓写导致的调度抖)
  # 触发型节点(boost_up/boost_down 等边沿触发)除外, 保持每次写
  case "$file" in
    */boost_up|*/boost_down|*/boost_ta|*/boost_fg) ;;
    *) [ "$before" = "$want" ] && return 0 ;;
  esac
  if printf '%s\n' "$want" > "$file" 2>/dev/null; then
    read -r after < "$file" 2>/dev/null
    [ "$before" != "$after" ] && log_debug "[w] $file: '$before' -> '$after'"
    # 回读校验(信息级): 一致或系统吸附(clamp 到更低)均视为成功, 差异仅记日志不阻断
    [ -n "$after" ] && [ "$after" != "$want" ] && \
      log_debug "[w] $file 回读不同: want='$want' got='$after' (系统吸附/clamp)"
    return 0
  fi
  if chown root:root "$file" 2>/dev/null && chmod 644 "$file" 2>/dev/null; then
    if printf '%s\n' "$want" > "$file" 2>/dev/null; then
      read -r after < "$file" 2>/dev/null
      [ "$before" != "$after" ] && log_debug "[w+chmod] $file: '$before' -> '$after'"
      return 0
    fi
  fi
  log_err "write failed: $file <- $*"
  return 1
}

# ---------- 日志(带轮转) ----------
PMK_LOG_MAX=200000
PMK_LOG_LINES=300

PMK_LOG_N=0
_log_append() {
  local lvl="$1" msg="$2"
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$lvl" "$msg" >> "$PMK_LOG_FILE" 2>/dev/null
  # 轮转检查: 每 50 条查一次大小(旧版每条都 stat, 一次切档几十条日志就是几十次 fork)
  PMK_LOG_N=$((PMK_LOG_N + 1))
  [ $((PMK_LOG_N % 50)) -eq 1 ] || return 0
  local sz
  sz=$(stat -c '%s' "$PMK_LOG_FILE" 2>/dev/null)
  if [ -n "$sz" ] && [ "$sz" -gt "$PMK_LOG_MAX" ] 2>/dev/null; then
    tail -n "$PMK_LOG_LINES" "$PMK_LOG_FILE" > "$PMK_LOG_FILE.tmp" 2>/dev/null \
      && mv "$PMK_LOG_FILE.tmp" "$PMK_LOG_FILE" 2>/dev/null
  fi
}

# logcat 通道: 只在 /system/bin/log 真存在时才 exec。
# 少了这个判断, 每个日志点都要 fork 一次注定失败的 exec(恢复模式/测试环境里全是白费)。
PMK_HAS_ALOG=0
[ -x /system/bin/log ] && PMK_HAS_ALOG=1

# 注意: 三个 log_* 必须显式 return 0。
# 写成 `[ cond ] && cmd` 时, cond 为假会让整个函数返回 1,
# 调用点的 `write_file ... && log_info ...` 就会被误判成写入失败。
log_info() {
  local msg="$1"
  _log_append info "$msg"
  if [ "$PMK_HAS_ALOG" = 1 ]; then
    /system/bin/log -t "$PMK_TAG" -p i "$msg" 2>/dev/null || true
  fi
  return 0
}
log_err() {
  local msg="$1"
  _log_append error "$msg"
  if [ "$PMK_HAS_ALOG" = 1 ]; then
    /system/bin/log -t "$PMK_TAG" -p e "$msg" 2>/dev/null || true
  fi
  return 0
}
log_warn() {
  local msg="$1"
  _log_append warn "$msg"
  if [ "$PMK_HAS_ALOG" = 1 ]; then
    /system/bin/log -t "$PMK_TAG" -p w "$msg" 2>/dev/null || true
  fi
  return 0
}

# 详细调试日志(受 system.conf debug 开关控制)
# debug 标志按调用次数缓存(每 10 次重读一次 system.conf, 守护进程约 10s):
# 每次 log_debug 都去 grep system.conf 会起子进程, 实测单次 fork ~13ms,
# 而守护进程每轮会调 log_debug 多次, 是纯浪费。
PMK_DEBUG_ON="" PMK_DEBUG_N=0
log_debug() {
  PMK_DEBUG_N=$((PMK_DEBUG_N + 1))
  if [ "$PMK_DEBUG_N" -ge 10 ] || [ -z "$PMK_DEBUG_ON" ]; then
    PMK_DEBUG_N=0
    cfg_get debug
    PMK_DEBUG_ON="$_CFG_VAL"
  fi
  [ "$PMK_DEBUG_ON" = "1" ] || return 0
  _log_append debug "$1"
}

# ---------- 属性 ----------
get_prop() { getprop "$1" 2>/dev/null; }

is_mtk() {
  case "$(get_prop ro.board.platform)" in mt*|MT*) return 0 ;; esac
  return 1
}

# ---------- policy 列表(按内核枚举顺序) ----------
# v3.0: 一次切档会调十几次(official_scx_active/usergov_takeover/unlock/apply 各一次),
#       旧版每次都 ls 一个, 光这里就是十几次 fork。缓存到进程内, 显式刷新时重扫。
PMK_POLICIES=""
policy_list() {
  if [ -z "$PMK_POLICIES" ]; then
    local p out=""
    for p in /sys/devices/system/cpu/cpufreq/policy[0-9]*; do
      [ -d "$p" ] && out="$out $p"
    done
    PMK_POLICIES="${out# }"
  fi
  printf '%s' "$PMK_POLICIES"
}
policy_list_refresh() { PMK_POLICIES=""; policy_list >/dev/null; }

# ---------- device.conf 读取(一次读入, 字符串索引) ----------
# 旧版 apply_cpu 每个 policy 两次 grep|cut, 三簇就是 6 次 fork。
DEV_MAP=""
dev_load() {
  [ -n "$DEV_MAP" ] && return 0
  DEV_MAP=","
  local conf="${DEVICE_CONF:-$PMK_CONFIG_DIR/device.conf}"
  [ -f "$conf" ] || return 1
  local k v
  while IFS='=' read -r k v; do
    [ -n "$k" ] && DEV_MAP="$DEV_MAP$k=$v,"
  done < "$conf" 2>/dev/null
  return 0
}
# 取值 -> DEV_V; 未命中返回 1
dev_get() {
  local rest
  dev_load
  [ -n "$1" ] || return 1
  rest="${DEV_MAP#*,$1=}"
  [ "$rest" = "$DEV_MAP" ] && { DEV_V=""; return 1; }
  DEV_V="${rest%%,*}"
  return 0
}

# ---------- 调速器白名单 ----------
# 注意: toybox grep 不支持 \b, 用 ERE 边界 (^| )/( |$)
governor_allowed() {
  local policy="$1" gov="$2"
  [ -f "$policy/available_governors" ] || return 1
  grep -Eq "(^| )$gov( |\$)" "$policy/available_governors" 2>/dev/null
}

# ---------- 词是否在空格分隔列表中(替代 echo|grep, 不起子进程) ----------
list_has() {
  local w
  [ -n "$1" ] && [ -n "$2" ] || return 1
  for w in $1; do
    [ "$w" = "$2" ] && return 0
  done
  return 1
}

# ---------- 频率是否在可用表中 ----------
freq_valid() {
  local policy="$1" f="$2"
  [ -f "$policy/scaling_available_frequencies" ] || return 1
  grep -Eq "(^| )$f( |\$)" "$policy/scaling_available_frequencies" 2>/dev/null
}

# ---------- INI 配置解析 ----------
# 用法: load_profile <file>; 结果写入 PMK_* 全局变量。
# 数组型键(如 MAXFREQ)以空格分隔, 按 policy 顺序对齐; 空位=保持默认。
load_profile() {
  local conf="$1"
  [ -f "$conf" ] || return 1
  # 每档重新解析前清空, 防止旧档残留键(比 unset 一长串便宜且不易漏)
  PMK_CPU_GOVERNOR=""; PMK_CPU_MAXFREQ=""; PMK_CPU_MINFREQ=""
  PMK_CPU_EXEC_LEVEL=""
  PMK_GPU_GOVERNOR=""; PMK_GPU_UPBOUND=""; PMK_GPU_BOOST=""; PMK_GPU_BOOST_EN=""
  PMK_CM_PERF_EN=""; PMK_CM_PERF_OPP=""; PMK_CM_DRAM_CEIL=""; PMK_CM_DRAM_FLOOR=""
  PMK_C2PS_UM=""
  local section="" line k v
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    # v3.0: 去 CR / 去首尾空白用参数扩展, 不再每行 printf|tr|sed 起两个子进程
    line="${line//$'\r'/}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in
      \[*\])
        section="${line#\[}"
        section="${section%\]}"
        ;;
      *=*)
        k="${line%%=*}"
        v="${line#*=}"
        # 去成对引号(配置里允许 "value" / 'value')
        case "$v" in
          \"*\") v="${v#\"}"; v="${v%\"}" ;;
          \'*\') v="${v#\'}"; v="${v%\'}" ;;
        esac
        case "$section" in
          CPU)
            case "$k" in
              GOVERNOR) PMK_CPU_GOVERNOR="$v" ;;
              MAXFREQ)  PMK_CPU_MAXFREQ="$v" ;;
              MINFREQ)  PMK_CPU_MINFREQ="$v" ;;
              # v3.1: 该档允许的闭环执行器最高档位(0~4)
              EXEC_LEVEL) PMK_CPU_EXEC_LEVEL="$v" ;;
            esac ;;
          GPU)
            case "$k" in
              DEVFREQ_GOVERNOR) PMK_GPU_GOVERNOR="$v" ;;
              GPU_UPBOUND)      PMK_GPU_UPBOUND="$v" ;;
              GPU_BOOST)        PMK_GPU_BOOST="$v" ;;
              GPU_BOOST_ENABLE) PMK_GPU_BOOST_EN="$v" ;;
            esac ;;
          CM)
            case "$k" in
              CM_PERF_MODE_ENABLE) PMK_CM_PERF_EN="$v" ;;
              CM_PERF_CEILING_OPP) PMK_CM_PERF_OPP="$v" ;;
              CM_DRAM_OPP_CEILING) PMK_CM_DRAM_CEIL="$v" ;;
              CM_DRAM_OPP_FLOOR)   PMK_CM_DRAM_FLOOR="$v" ;;
            esac ;;
          C2PS)
            [ "$k" = "C2PS_UM_MODE" ] && PMK_C2PS_UM="$v"
            ;;
        esac ;;
    esac
  done < "$conf"
  return 0
}

# ---------- 数组取第 i 项(1-based) ----------
# 用法: field "$var" $i; 空/越界输出空串
# v3.0: 纯内建分词(旧版每次 awk, apply_cpu 一个档位调 15 次就是 15 次 fork)
field() {
  local s="$1" n="$2" i=1 w
  [ -n "$s" ] || return 0
  for w in $s; do
    [ "$i" = "$n" ] && { printf '%s' "$w"; return 0; }
    i=$((i + 1))
  done
  return 0
}

# ---------- 回滚保护(防 bootloop, 沿用 Falling 契约; 运行时状态放 runtime/) ----------
PMK_ROLLBACK_FILE="$PMK_RUNTIME_DIR/.rollback"
PMK_BOOT_FAIL_THRESHOLD=2

rollback_mark_boot() {
  runtime_dir
  local profile="${1:-balanced}" old_p="" old_f=0 new_f=1
  if [ -f "$PMK_ROLLBACK_FILE" ]; then
    old_p=$(awk '{print $1}' "$PMK_ROLLBACK_FILE" 2>/dev/null)
    old_f=$(awk '{print $2}' "$PMK_ROLLBACK_FILE" 2>/dev/null)
    [ -n "$old_f" ] || old_f=0
  fi
  [ "$old_p" = "$profile" ] && [ "$profile" != "balanced" ] && new_f=$((old_f+1))
  echo "$profile $new_f" > "$PMK_ROLLBACK_FILE" 2>/dev/null
}
rollback_ack() {
  [ -f "$PMK_ROLLBACK_FILE" ] || return 0
  local p
  p=$(awk '{print $1}' "$PMK_ROLLBACK_FILE" 2>/dev/null)
  printf '%s 0\n' "$p" > "$PMK_ROLLBACK_FILE.new" 2>/dev/null \
    && mv "$PMK_ROLLBACK_FILE.new" "$PMK_ROLLBACK_FILE"
}
rollback_should_revert() {
  [ -f "$PMK_ROLLBACK_FILE" ] || return 1
  local profile fails
  profile=$(awk '{print $1}' "$PMK_ROLLBACK_FILE" 2>/dev/null)
  fails=$(awk '{print $2}' "$PMK_ROLLBACK_FILE" 2>/dev/null)
  [ -z "$fails" ] && fails=0
  [ "$profile" = "balanced" ] && return 1
  if [ "$fails" -ge "$PMK_BOOT_FAIL_THRESHOLD" ]; then
    log_err "boot-loop guard: fallback to balanced (fails=$fails)"
    return 0
  fi
  return 1
}

# ---------- cpufreq 节点解锁(G1: root 属主 644, 不开放给所有进程) ----------
# 首次解锁前备份原属主/权限, 供卸载还原
cpufreq_perm_backup() {
  local b="$PMK_CONFIG_DIR/cpufreq_perm_backup"
  [ -f "$b" ] && return 0
  : > "$b" 2>/dev/null
  local p f u g m
  policy_list >/dev/null
  for p in $PMK_POLICIES; do
    for f in scaling_governor scaling_min_freq scaling_max_freq; do
      [ -f "$p/$f" ] || continue
      u=$(stat -c '%u' "$p/$f" 2>/dev/null)
      g=$(stat -c '%g' "$p/$f" 2>/dev/null)
      m=$(stat -c '%a' "$p/$f" 2>/dev/null)
      echo "$(basename "$p") $f $u $g $m" >> "$b" 2>/dev/null
    done
  done
}

cpufreq_perm_restore() {
  local b="$PMK_CONFIG_DIR/cpufreq_perm_backup"
  [ -f "$b" ] || return 0
  local p f u g m
  while read -r p f u g m; do
    [ -f "/sys/devices/system/cpu/cpufreq/$p/$f" ] || continue
    [ -n "$u" ] && [ -n "$g" ] && chown "$u:$g" "/sys/devices/system/cpu/cpufreq/$p/$f" 2>/dev/null
    [ -n "$m" ] && chmod "$m" "/sys/devices/system/cpu/cpufreq/$p/$f" 2>/dev/null
  done < "$b"
  rm -f "$b" 2>/dev/null
}

# v3.0: 先探一个节点, 已经是 root:root 644 就整段跳过。
#   旧版每次切档都跑 9 次 chown + 9 次 chmod = 18 次 fork, 而系统只在开机重置属主,
#   切档时绝大多数情况已经是解锁状态。重启后属主会变回 system, 所以不能用标志文件,
#   必须每次真读一次(stat 一次, 三个字段同一行输出)。
unlock_cpufreq() {
  policy_list >/dev/null
  local p first="" u g m st
  for p in $PMK_POLICIES; do first="$p"; break; done
  [ -n "$first" ] && [ -f "$first/scaling_max_freq" ] || return 0
  # 一次 stat 同时取三个字段(进程替换是 bash 专有语法, mksh 上没有)
  st=$(stat -c '%u %g %a' "$first/scaling_max_freq" 2>/dev/null)
  u="${st%% *}"
  g="${st#* }"; g="${g%% *}"
  m="${st##* }"
  [ "$u" = 0 ] && [ "$g" = 0 ] && [ "$m" = 644 ] && return 0

  cpufreq_perm_backup
  for p in $PMK_POLICIES; do
    for f in scaling_governor scaling_min_freq scaling_max_freq; do
      [ -f "$p/$f" ] && { chown root:root "$p/$f" 2>/dev/null; chmod 644 "$p/$f" 2>/dev/null; }
    done
  done
}
