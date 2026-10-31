#!/system/bin/sh
# ============================================================
# Falling-MT6991 采样层 (v3.0)
#
# 为什么单独一层:
#   旧版 smart.sh 每次决策要起 6 个命令替换(temp/load/busy/cores/fps/temp_adj)
#   外加一次 awk 读帧率。命令替换本身就是 fork, 5s 一轮纯浪费。
#   本层把"一次采集"收进一个函数, 全部内建 read, 结果放全局变量,
#   决策层只做算术, 不再 fork。顺带把"分簇忙时"补齐。
#
# 输出(调用 met_collect 后有效):
#   MET_TEMP        最高 CPU/SoC/GPU 温度 (mC), 0 = 读不到
#   MET_BUSY        整机忙时占比 (%), -1 = 无基线/读不到
#   MET_CL0..CL7    各 policy 簇忙时占比 (%), -1 = 无基线/读不到
#   MET_NCL         有效簇数
#   MET_FPS         最低帧率达标率 (%), -1 = 无有效渲染器
#   MET_PSI         CPU 争用压力(cpu some avg10, %), -1 = 无 PSI 节点/读不到
#   MET_CORES       CPU 核数
#
# 信号来源(全部标准内核接口, 不猜):
#   温度   /sys/class/thermal/thermal_zone*/{type,temp}
#   忙时   /proc/stat 的 cpu 汇总行 + cpuN 分核行, 两次采样差值
#   分簇   /sys/devices/system/cpu/cpufreq/policyN/affected_cpus
#   帧率   /sys/kernel/fpsgo/fstb/fpsgo_status
#   争用   /proc/pressure/cpu (PSI, 需 CONFIG_PSI; 缺失返回 -1)
#
# 为什么分簇: 整机忙时 45% 可能是"小核全满、大核全闲", 也可能是"三簇各 45%"。
#   前者提频收益小(瓶颈在迁移/并行度), 后者才是真需要更高频率。
#   只做正向信号(大核吃满 -> 加分), 不做负向, 避免把"小核紧"误判成"不用提频"。
# ============================================================
# shellcheck disable=SC1091
MODDIR="${MODDIR:-$(dirname "$(dirname "$0")")}"
[ -f "$MODDIR/lib/common.sh" ] && . "$MODDIR/lib/common.sh"

MET_SAMPLE="$PMK_RUNTIME_DIR/cpu.sample"   # "<total> <idle> <p0t>:<p0i> ..."
MET_CLMAP="$PMK_RUNTIME_DIR/cluster.map"   # "policy0=0 1 2 3,policy4=4 5 6 7,"
MET_ZONES=""       # 温度 zone 路径缓存
MET_ZONE_TICK=0
MET_ZONE_REFRESH=12  # 12 轮 ≈ 60s

# ---------- 核数(缓存) ----------
MET_CORES=""
met_cores() {
  if [ -z "$MET_CORES" ]; then
    local n=0 c
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
      [ -d "$c" ] && n=$((n + 1))
    done
    [ "$n" -gt 0 ] || n=8
    MET_CORES="$n"
  fi
}

# ---------- 温度 zone 扫描(缓存; 热插拔 zone 靠定期刷新兜住) ----------
met_scan_zones() {
  MET_ZONES=""
  local z t
  for z in /sys/class/thermal/thermal_zone*; do
    [ -f "$z/type" ] || continue
    t=""
    read -r t < "$z/type" 2>/dev/null
    case "$t" in
      cpu-*|cpu_*|soc-*|soc_*|gpu*|mtkts*) MET_ZONES="$MET_ZONES $z" ;;
    esac
  done
}

met_temp() {
  MET_ZONE_TICK=$((MET_ZONE_TICK + 1))
  if [ -z "$MET_ZONES" ] || [ $((MET_ZONE_TICK % MET_ZONE_REFRESH)) -eq 0 ]; then
    met_scan_zones
    MET_ZONE_TICK=0
  fi
  local z v m=0
  for z in $MET_ZONES; do
    v=""
    read -r v < "$z/temp" 2>/dev/null
    case "$v" in ''|*[!0-9-]*) continue ;; esac
    [ "$v" -gt "$m" ] 2>/dev/null && m=$v
  done
  MET_TEMP="$m"
}

# ---------- /proc/stat 采样 ----------
# 输出 ST_TOTAL/ST_IDLE(汇总) 与 CPU_T="|0=total:idle|1=total:idle|"
# 只读到 ctxt/processes 之前: 那些行字段不足, read 会返回非 0, 循环自然结束
met_read_stat() {
  ST_TOTAL=0; ST_IDLE=0; CPU_T=","
  local tag u n s idl iow irq sirq st rest t i
  while read -r tag u n s idl iow irq sirq st rest; do
    case "$tag" in
      cpu|cpu[0-9]*) ;;
      *) break ;;
    esac
    # 缺项(老内核无 steal)按 0 处理, 否则算术会报语法错
    u=${u:-0}; n=${n:-0}; s=${s:-0}; idl=${idl:-0}
    iow=${iow:-0}; irq=${irq:-0}; sirq=${sirq:-0}; st=${st:-0}
    case "$u$n$s$idl$iow$irq$sirq$st" in
      ''|*[!0-9]*) continue ;;
    esac
    t=$((u + n + s + idl + iow + irq + sirq + st))
    # iowait 在内核里同样不占 CPU, 归到空闲侧
    i=$((idl + iow))
    if [ "$tag" = cpu ]; then
      ST_TOTAL=$t; ST_IDLE=$i
    else
      CPU_T="$CPU_T${tag#cpu}=$t:$i,"
    fi
  done < /proc/stat 2>/dev/null
}

# 从 CPU_T 取某核 "total idle" -> CP_T CP_I; 找不到返回 1
met_cpu_pair() {
  local rest
  CP_T=""; CP_I=""
  rest="${CPU_T#*,$1=}"
  [ "$rest" = "$CPU_T" ] && return 1
  rest="${rest%%,*}"
  CP_T="${rest%%:*}"
  CP_I="${rest#*:}"
  case "$CP_T$CP_I" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

# ---------- 分簇映射(按 policy affected_cpus; 开机不变, 缓存到 runtime) ----------
met_load_map() {
  if [ -s "$MET_CLMAP" ]; then
    read -r MET_MAP_RAW < "$MET_CLMAP" 2>/dev/null
    # 缓存必须是逗号分隔的新格式; 出现 "|" 说明是老版本留下的, 当场作废重建。
    # (v3.0 之前用 "|", mksh 上按新格式解析会切不开 -> 死循环)
    case "$MET_MAP_RAW" in
      *,*) case "$MET_MAP_RAW" in *'|'*) MET_MAP_RAW="" ;; esac ;;
    esac
    case "$MET_MAP_RAW" in *policy*) return 0 ;; esac
  fi
  local p cpus
  MET_MAP_RAW=""
  for p in /sys/devices/system/cpu/cpufreq/policy[0-9]*; do
    [ -d "$p" ] || continue
    cpus=""
    read -r cpus < "$p/affected_cpus" 2>/dev/null
    [ -n "$cpus" ] || read -r cpus < "$p/related_cpus" 2>/dev/null
    case "$cpus" in ''|*[!0-9\ ]*) continue ;; esac
    MET_MAP_RAW="$MET_MAP_RAW${p##*/}=$cpus,"
  done
  runtime_dir
  printf '%s\n' "$MET_MAP_RAW" > "$MET_CLMAP" 2>/dev/null
  return 0
}

# 由差值算百分比 -> P_PCT; 参数: cur_total cur_idle prev_total prev_idle
met_pct() {
  local ct="$1" ci="$2" pt="$3" pi="$4" dt db
  P_PCT=-1
  [ "${pt:-0}" -gt 0 ] 2>/dev/null || return 1
  dt=$((ct - pt))
  [ "$dt" -gt 0 ] || return 1
  db=$((dt - (ci - pi)))
  [ "$db" -lt 0 ] && db=0
  P_PCT=$((db * 100 / dt))
  [ "$P_PCT" -gt 100 ] && P_PCT=100
  return 0
}

# ---------- 忙时(整机 + 分簇) ----------
met_cpu() {
  MET_BUSY=-1; MET_NCL=0
  MET_CL0=-1; MET_CL1=-1; MET_CL2=-1; MET_CL3=-1
  met_read_stat
  [ "$ST_TOTAL" -gt 0 ] 2>/dev/null || { MET_BUSY=-1; return 1; }

  # 上次采样: "<total> <idle> <p0t>:<p0i> ..."
  local pt=0 pi=0 entry rest i=0 sum_t sum_i first=1 saved=""
  if [ -s "$MET_SAMPLE" ]; then
    read -r pt pi rest < "$MET_SAMPLE" 2>/dev/null
    saved="$rest"
  fi
  case "${pt:-0}${pi:-0}" in ''|*[!0-9]*) pt=0; pi=0 ;; esac

  met_load_map
  local map="$MET_MAP_RAW" pol cpus c
  CL_OUT=""
  while [ -n "$map" ]; do
    pol="${map%%,*}"
    map="${map#*,}"
    [ -n "$pol" ] || continue
    cpus="${pol#*=}"
    pol="${pol%%=*}"
    sum_t=0; sum_i=0
    for c in $cpus; do
      met_cpu_pair "$c" || continue
      sum_t=$((sum_t + CP_T)); sum_i=$((sum_i + CP_I))
    done
    [ "$sum_t" -gt 0 ] || continue
    # 该簇上次值(saved 形如 ",policy0=t:i,policy4=t:i")
    local pv="" pvt=0 pvi=0
    pv="${saved#*,$pol=}"
    if [ "$pv" != "$saved" ]; then
      pv="${pv%%,*}"
      pvt="${pv%%:*}"; pvi="${pv#*:}"
      case "$pvt$pvi" in ''|*[!0-9]*) pvt=0; pvi=0 ;; esac
    fi
    met_pct "$sum_t" "$sum_i" "$pvt" "$pvi"
    # 索引按簇顺序走, 不看 met_pct 是否成功, 否则首轮无基线会让簇号错位
    case "$i" in
      0) MET_CL0=$P_PCT ;; 1) MET_CL1=$P_PCT ;;
      2) MET_CL2=$P_PCT ;; 3) MET_CL3=$P_PCT ;;
    esac
    i=$((i + 1))
    CL_OUT="$CL_OUT,$pol=$sum_t:$sum_i"
  done
  MET_NCL=$i

  met_pct "$ST_TOTAL" "$ST_IDLE" "$pt" "$pi" && MET_BUSY=$P_PCT

  # 写回本次采样(下次算差值用); CL_OUT 自带前导 ,
  runtime_dir
  printf '%s %s %s\n' "$ST_TOTAL" "$ST_IDLE" "$CL_OUT" > "$MET_SAMPLE" 2>/dev/null
  return 0
}

# ---------- 帧率: 取所有活跃渲染器里最差的达标率 ----------
# fpsgo_status 实际列结构(实机 od -c 验证, 一加 Ace 5 至尊版 / MT6991):
#   tid \t bufID \t name \t currentFPS \t <空> \t targetFPS \t <空> \t sbe_state \t ...
#   样例: "3872 0xcdc00000001 ndroid.systemui 33 30 ..." -> currentFPS=33, 目标=30
#   样例: "2655 0x322700000369 encent.mobileqq 63 63 ..." -> 目标 63
#   目标值与 /sys/kernel/fpsgo/fstb/fstb_tfps_info 的 target_fps 一致(实测 63 对得上),
#   所以 read a b c d e 取到的 d=当前帧率, e=目标帧率 是对的。
# 内建 read 遇到连续空白会压缩, 正好把中间那个空列跳过, 不会错位。
#
# 两处修正:
#   1) 达标率可能 >100(当前 33 / 目标 30 = 110%), 必须封顶, 否则 UI 显示 110% 很不像话
#   2) 只让"目标帧率 >= 45"的行参与判定: 30fps 类的老应用/省电屏掉到 20fps 时
#      达标率也只有 66%, 但那不是 CPU 性能不够(给它 120Hz 也一样),
#      放进来会让模块误判成"帧率撑不住"去升性能, 白白拉高频率。
met_fps() {
  MET_FPS=-1
  local f=/sys/kernel/fpsgo/fstb/fpsgo_status
  [ -f "$f" ] || return 0
  local a b c d e rest low="" r n=0
  while read -r a b c d e rest; do
    n=$((n + 1))
    [ "$n" -gt 40 ] && break
    case "$d$e" in ''|*[!0-9]*) continue ;; esac
    [ "$d" -gt 0 ] 2>/dev/null || continue
    [ "$e" -ge 45 ] 2>/dev/null || continue
    r=$((d * 100 / e))
    [ "$r" -gt 100 ] && r=100
    if [ -z "$low" ] || [ "$r" -lt "$low" ]; then low=$r; fi
  done < "$f" 2>/dev/null
  [ -n "$low" ] && MET_FPS="$low"
  return 0
}

# ---------- PSI CPU 争用: 任务因抢不到 CPU 而等待的时间占比 ----------
# /proc/pressure/cpu 格式(内核文档 accounting/psi.rst):
#   some avg10=0.00 avg60=0.00 avg300=0.00 total=0
# cpu 只有 some 行(full 对 cpu 无意义); some = 至少一个任务被阻塞的时间占比。
#
# 为什么用它: /proc/stat 的忙时是"平均利用率", 会把"任务在排队等 CPU"平均掉。
# 利用率没到顶但任务在等(突发/多任务争用)时, PSI 才看得出真实需求。
#
# 为什么用 avg10 而不是 total 差分: total 是累计微秒, 差分需要记录采样时刻
#   (date 是 fork)。本层 5 秒一轮, avg10 已是时间归一化的百分比, 足够决策粒度。
#
# 为什么只当"二级判据": CPU PSI 只说明供给不足, 10s 平滑会吞掉短卡顿,
#   GPU/合成卡顿也不会体现在这里。决策层必须再叠加一个绝对需求下限才采用。
#
# 缺失(CONFIG_PSI 关/旧内核) -> MET_PSI=-1, 调用方跳过(AGENTS: 读不到就跳过)。
met_psi() {
  MET_PSI=-1
  local f=/proc/pressure/cpu a b rest v
  [ -f "$f" ] || return 0
  while read -r a b rest; do
    [ "$a" = "some" ] || continue
    v="${b#avg10=}"
    [ "$v" != "$b" ] || continue
    v="${v%%.*}"                  # 只取整数部分(向下取整, 保守)
    case "$v" in ''|*[!0-9]*) continue ;; esac
    [ "$v" -gt 100 ] && v=100
    MET_PSI="$v"
    break
  done < "$f" 2>/dev/null
  return 0
}

# ---------- 一次采集 ----------
# PMK_MET_READY 标志: 守护进程主进程采集完后置 1, 表示"本轮信号已就绪"。
#   为什么需要: met_cpu 会把本次采样写回 runtime/cpu.sample 当下次基线。
#   如果同一轮里采集两次, 第二次就拿"刚写的基线"算差值 -> dt=0 -> busy 变成 -1。
#
#   场景: 守护进程主进程要采集(闭环层要读 MET_FPS/SM_PRIME),
#   而 smart_decide 是在命令替换的子进程里跑的 ——
#   子进程继承父进程的 PMK_MET_READY=1, 直接跳过采集, 两边读到同一份数据。
#
#   为什么要用显式标志而不是"采集过就永久标记":
#   隐式标记无法区分"本轮已采集"和"上一轮采集过"。
#   同进程连续调用(测试、外部脚本直接调 smart_decide)会从第二轮起
#   全部读不到新数据 —— 实测踩过: 温度/占用率全部变成首轮的值。
#   所以: 守护进程每轮开头显式 met_collect_reset; 而 PMK_MET_READY
#   只在守护进程采集后由主进程设置, 其它调用路径永远读到 0。
met_collect_reset() { MET_DONE=0; PMK_MET_READY=0; }
met_collect() {
  [ "${MET_DONE:-0}" = "1" ] && return 0
  runtime_dir
  met_cores
  met_temp
  met_cpu
  met_fps
  met_psi
  MET_DONE=1
  return 0
}

# 供 UI/排障: 一行文本快照
met_status() {
  met_collect
  echo "temp=${MET_TEMP:-0}"
  echo "busy=${MET_BUSY:--1}"
  echo "cluster0=${MET_CL0:--1}"
  echo "cluster1=${MET_CL1:--1}"
  echo "cluster2=${MET_CL2:--1}"
  echo "clusters=${MET_NCL:-0}"
  echo "fps=${MET_FPS:--1}"
  echo "psi=${MET_PSI:--1}"
  echo "cores=${MET_CORES:-0}"
}

# source 守卫
[ "$(basename "$0" 2>/dev/null)" = "metrics.sh" ] || return 0 2>/dev/null
case "$1" in
  status) met_status ;;
  temp)   met_temp; printf '%s\n' "$MET_TEMP" ;;
  busy)   met_cpu; printf '%s\n' "$MET_BUSY" ;;
  fps)    met_fps; printf '%s\n' "$MET_FPS" ;;
esac
