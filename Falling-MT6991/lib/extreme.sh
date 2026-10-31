#!/system/bin/sh
# ============================================================
# Falling-MT6991 极致省电限制层 (v3.4.0 新增)
#
# 它不是"第六个档位", 是叠加在当前档位之上的一个限制层:
#   档位决定基线(性能/均衡/省电/游戏), 极致省电把基线整体往下压。
#
# 语义(与 NovaSched 的「极限省电」一致):
#   - 全局开关: system.conf 的 extreme=1
#   - 优先级高于应用策略与自动评分 —— 它改的是"值", 不是"选哪个档"
#   - 游戏豁免: 命中游戏名单 / 游戏进程存活时, 整个限制层失效
#     (产品硬规则: 游戏 CPU 一律不管, 游戏不做极致省电)
#
# 为什么不做成新档位:
#   档位 = "选哪个", 极致省电 = "再压一层"。做成档位就必须让用户选,
#   而本模块的产品约定就是"用户不配置调度参数"(见 AGENTS.md)。
#
# 与"一个节点只能有一个写入者"(AGENTS.md)的关系:
#   本文件【不写任何系统节点】, 只做值变换, 写入者仍然是原来那一个:
#     CPU 频率上限  -> governor.sh 的 apply_cpu 写进 runtime/cap.target
#     执行器节奏    -> loop.sh 的 loop_apply_exec 写 sugov_ext/hmbird
#     调度策略      -> apply.sh 的 sched_effective 选档
#   所以没有引入第二个写入者, 也不存在两个写入者互相覆盖的问题。
#
# 数据来源(实测/官方, 不拿推断值冒充实测):
#   - CPU/GPU 频率点: config/device.conf 的实机频率表(安装时 detect.sh 读取)
#     钳制时从表里取 "<= 目标值" 的最大真实频点, 保证写入值一定可写
#   - sugov_ext 升降频速率语义: docs/arch-realdevice.md 实验 2/3
#     (写 200000 -> CPU 被钉在 798000 地板; 写 10 -> 能冲到 3600000)
#   - up_rate=50000 已实机标定(绑定 cpu7 满载, 0.2s 采样): 10000 约 0.4s 升到
#     3400000, 50000 约 3.2s, 200000 约 6.6s。取值与结论写在
#     config/profiles/extreme_overlay.conf 的注释里; 调参只改那一个文件。
#   - hmbird cpuctrl_high/low 是百分比阈值(越大越晚触发 boost), 机制见
#     config/profiles/sched_*.conf 的注释; 95/85 是本档的取值, 同样待标定。
#
# 故意不做的一件事(不猜):
#   cm_mgr 的 DRAM OPP 上下限方向未实机确证 —— 现有 powersave(6) 与
#   powersave+(7) 两个档位的数值方向本身就互相矛盾(见 README 待验证清单)。
#   在方向确证前, 极致省电【不覆写】DRAM OPP, 沿用当前档位的值,
#   避免把一个方向未定的节点写坏。
# ============================================================
# shellcheck disable=SC1091
MODDIR="${MODDIR:-$(dirname "$(dirname "$0")")}"
[ -f "$MODDIR/lib/common.sh" ] && . "$MODDIR/lib/common.sh"

# device.conf 路径: common.sh 的 dev_get 用 DEVICE_CONF 定位实机频率表。
# 本文件独立运行时也要能读到, 所以自己兜一个默认值(与 governor.sh 同路径)。
DEVICE_CONF="${DEVICE_CONF:-$PMK_CONFIG_DIR/device.conf}"

EXTREME_CONF="$PMK_CONFIG_DIR/profiles/extreme_overlay.conf"
EXTREME_STATE="$PMK_RUNTIME_DIR/extreme.state"

# 生效态与钳制参数
EXTREME_ON=0
EXTREME_MAXFREQ=""       # CPU 三簇上限目标(kHz), 顺序 policy0 policy4 policy7
EXTREME_UP_RATE=""       # sugov_ext up_rate_limit_us
EXTREME_DOWN_RATE=""     # sugov_ext down_rate_limit_us
EXTREME_CP_HIGH=""       # hmbird cpuctrl_high(百分比, 越大越晚 boost)
EXTREME_CP_LOW=""        # hmbird cpuctrl_low
EXTREME_GPU_UPBOUND=""   # GPU 上限(kHz)
EXTREME_GPU_BOOST=""     # GPU boost 频率(kHz)
EXTREME_GPU_BOOST_EN=""  # GPU boost 总开关
EXTREME_F=""             # extreme_snap_freq 的输出
EXTREME_MIN=""           # extreme_min 的输出
EXTREME_CHANGED=0        # 状态翻转标记(daemon 用它触发重应用)

# ---------- 状态: runtime/extreme.state ----------
# 真源是 runtime 文件, 不是 system.conf:
#   daemon 每轮根据"用户开关 + 游戏豁免"算出最终态写进来,
#   各写入层(governor/loop)只读这个文件, 不各自判断游戏。
#   文件内容: extreme=1 | extreme=0
extreme_state_read() {
  EXTREME_ON=0
  [ -f "$EXTREME_STATE" ] || return 0
  local v=""
  read -r v < "$EXTREME_STATE" 2>/dev/null
  case "$v" in
    extreme=1) EXTREME_ON=1 ;;
  esac
  return 0
}

# 写状态; $1=0|1。状态翻转时置 EXTREME_CHANGED=1, 由 daemon 触发重应用。
extreme_state_write() {
  runtime_dir
  local want="extreme=$1" cur=""
  # 读旧值: 文件可能还不存在, 先判存在再读 ——
  # 否则 sh 会把 "No such file or directory" 报到 stderr(输入重定向失败
  # 发生在 2>/dev/null 生效之前, 屏蔽不掉), 首次开启时刷一条假错误。
  if [ -f "$EXTREME_STATE" ]; then
    read -r cur < "$EXTREME_STATE" 2>/dev/null
  fi
  if [ "$cur" = "$want" ]; then
    return 0
  fi
  printf '%s\n' "$want" > "$EXTREME_STATE" 2>/dev/null
  EXTREME_CHANGED=1
  log_info "extreme: 限制层状态 -> $1"
  return 0
}

# 发布最终生效态: $1=游戏进行中(0|1), $2=用户开关(0|1)
# 游戏优先: 游戏期间限制层一律失效(产品硬规则: 游戏不做极限省电)。
extreme_publish() {
  local want=0
  [ "${2:-0}" = "1" ] && want=1
  [ "${1:-0}" = "1" ] && want=0
  extreme_state_write "$want"
}

# ---------- 读钳制参数 ----------
# 从 config/profiles/extreme_overlay.conf 读(与其它档位同一套 INI 风格)。
# 这个文件是【标定入口】: 实机标定完只改它, 不动代码。
extreme_load() {
  EXTREME_MAXFREQ=""; EXTREME_UP_RATE=""; EXTREME_DOWN_RATE=""
  EXTREME_CP_HIGH=""; EXTREME_CP_LOW=""
  EXTREME_GPU_UPBOUND=""; EXTREME_GPU_BOOST=""; EXTREME_GPU_BOOST_EN=""
  [ -f "$EXTREME_CONF" ] || return 0
  local section="" line k v
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
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
        case "$v" in
          \"*\") v="${v#\"}"; v="${v%\"}" ;;
          \'*\') v="${v#\'}"; v="${v%\'}" ;;
        esac
        case "$section" in
          CPU)
            case "$k" in
              MAXFREQ)      EXTREME_MAXFREQ="$v" ;;
              UP_RATE)      EXTREME_UP_RATE="$v" ;;
              DOWN_RATE)    EXTREME_DOWN_RATE="$v" ;;
              CPUCTRL_HIGH) EXTREME_CP_HIGH="$v" ;;
              CPUCTRL_LOW)  EXTREME_CP_LOW="$v" ;;
            esac ;;
          GPU)
            case "$k" in
              GPU_UPBOUND)      EXTREME_GPU_UPBOUND="$v" ;;
              GPU_BOOST)        EXTREME_GPU_BOOST="$v" ;;
              GPU_BOOST_ENABLE) EXTREME_GPU_BOOST_EN="$v" ;;
            esac ;;
        esac ;;
    esac
  done < "$EXTREME_CONF"
  return 0
}

# ---------- 频率表钳制 ----------
# 从实机频率表里取 "<= 目标" 的最大频点; 结果放 EXTREME_F。
# 为什么必须取表内频点: 直接写一个表里没有的值, 内核会拒写,
# 于是"压上限"变成"没压", 甚至把节点写坏。
extreme_snap_freq() {
  local freqs="$1" target="$2" best=0 w
  EXTREME_F=""
  [ -n "$freqs" ] || return 1
  [ -n "$target" ] || return 1
  for w in $freqs; do
    case "$w" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$w" -le "$target" ] 2>/dev/null || continue
    [ "$w" -gt "$best" ] 2>/dev/null && best="$w"
  done
  [ "$best" -gt 0 ] || return 1
  EXTREME_F="$best"
  return 0
}

# 两数取小 -> EXTREME_MIN (0 视为"未设置", 取另一个)
extreme_min() {
  local a="$1" b="$2"
  case "$a" in ''|*[!0-9]*) a=0 ;; esac
  case "$b" in ''|*[!0-9]*) b=0 ;; esac
  if [ "$a" -gt 0 ] 2>/dev/null && { [ "$b" -le 0 ] 2>/dev/null || [ "$a" -le "$b" ] 2>/dev/null; }; then
    EXTREME_MIN="$a"
  else
    EXTREME_MIN="$b"
  fi
  return 0
}

# ---------- 对档位值做钳制 ----------
# 在 apply_profile 载入档位之后调用。只改 PMK_* 值, 不写节点。
# 语义是【取更严的一侧】(min), 绝不会把档位放宽。
# PMK_POLICIES 依赖 policy_list() 的进程内缓存, 调用方须已 policy_list 过。
extreme_clamp_profile() {
  # 自己读一次状态: 不依赖调用方先调 extreme_state_read ——
  # 否则"忘了读"的调用点会静默不生效(比报错更难查)。
  extreme_state_read
  [ "$EXTREME_ON" = 1 ] || return 0
  extreme_load
  local i=0 p freqs target cur got out=""

  # --- CPU 三簇上限: min(档位上限, 极致上限), 再取表内不超过它的真实频点 ---
  for p in $PMK_POLICIES; do
    target=$(field "$EXTREME_MAXFREQ" $((i + 1)))
    case "$target" in
      ''|*[!0-9]*) target=0 ;;
    esac
    cur=$(field "${PMK_CPU_MAXFREQ:-}" $((i + 1)))
    case "$cur" in
      ''|*[!0-9]*) cur=0 ;;
    esac
    extreme_min "$cur" "$target"
    got="$EXTREME_MIN"
    if [ "$got" -gt 0 ] 2>/dev/null; then
      freqs=""
      dev_get "POLICY${i}_FREQS" && freqs="$DEV_V"
      if [ -n "$freqs" ]; then
        extreme_snap_freq "$freqs" "$got" && got="$EXTREME_F"
      fi
      # 表里没有可用频点(device.conf 缺失)时保留原值:
      # 后续 apply_cpu 仍会按 device.conf 白名单校验, 不合法就拒写并记日志
    fi
    out="$out $got"
    i=$((i + 1))
  done
  # 三簇都有有效上限时才整体覆盖, 避免把某一簇写成 0(0 会被当成"不限制")
  case "$out" in
    *" 0"*|" 0"|"") : ;;
    *) PMK_CPU_MAXFREQ="$out" ;;
  esac

  # --- GPU: 上限取更严的一侧, boost 全关, 调速器 powersave ---
  if [ -n "$EXTREME_GPU_UPBOUND" ]; then
    target="$EXTREME_GPU_UPBOUND"
    case "$target" in
      ''|*[!0-9]*) target=0 ;;
    esac
    cur="${PMK_GPU_UPBOUND:-}"
    case "$cur" in
      ''|*[!0-9]*) cur=0 ;;
    esac
    extreme_min "$cur" "$target"
    got="$EXTREME_MIN"
    if [ "$got" -gt 0 ] 2>/dev/null; then
      freqs=""
      dev_get GPU_FREQS && freqs="$DEV_V"
      if [ -n "$freqs" ]; then
        # device.conf 的 GPU 频率表单位是 Hz, overlay 里用 kHz, 换算后再取点
        extreme_snap_freq "$freqs" $((got * 1000)) && got=$((EXTREME_F / 1000))
      fi
    fi
    [ -n "$got" ] && PMK_GPU_UPBOUND="$got"
  fi
  [ -n "$EXTREME_GPU_BOOST" ] && PMK_GPU_BOOST="$EXTREME_GPU_BOOST"
  [ -n "$EXTREME_GPU_BOOST_EN" ] && PMK_GPU_BOOST_EN="$EXTREME_GPU_BOOST_EN"
  # GPU 调速器一律 powersave(与省电档同一取值, 本机已验证可写)
  PMK_GPU_GOVERNOR="powersave"

  # --- cm_mgr: 关性能模式 ---
  # DRAM OPP 上下限: 方向未确证, 故意不覆写(见文件头说明), 沿用档位值
  PMK_CM_PERF_EN="0"
  PMK_CM_PERF_OPP="0"

  # --- c2ps 省电模式 ---
  PMK_C2PS_UM="Y"

  log_info "extreme: 档位值已钳制 (cpu_max=$PMK_CPU_MAXFREQ gpu_up=$PMK_GPU_UPBOUND)"
  return 0
}

# ---------- 状态输出(日志/排障) ----------
extreme_status() {
  extreme_state_read
  extreme_load
  echo "enabled=$EXTREME_ON"
  echo "cpu_maxfreq=$EXTREME_MAXFREQ"
  echo "up_rate=$EXTREME_UP_RATE"
  echo "down_rate=$EXTREME_DOWN_RATE"
  echo "cpuctrl_high=$EXTREME_CP_HIGH"
  echo "cpuctrl_low=$EXTREME_CP_LOW"
  echo "gpu_upbound=$EXTREME_GPU_UPBOUND"
  echo "gpu_boost=$EXTREME_GPU_BOOST"
  echo "gpu_boost_enable=$EXTREME_GPU_BOOST_EN"
}

# source 守卫: 仅直接执行时进入命令分发
[ "$(basename "$0" 2>/dev/null)" = "extreme.sh" ] || return 0 2>/dev/null
case "$1" in
  state)  extreme_state_read; echo "$EXTREME_ON" ;;
  status) extreme_status ;;
  load)   extreme_load; extreme_status ;;
esac
