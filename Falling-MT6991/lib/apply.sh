#!/system/bin/sh
# ============================================================
# Falling-MT6991 档位编排 (v1.3.0 唯一编排入口)
# 一个档位 = 频率档位 + 调度策略 + IO 的组合, 由档位直接派生, 无需用户配置
#
# 为什么没有场景层了:
#   旧版是"场景 = 档位+调度+触控+IO 的组合", 用户要维护 4 个场景文件。
#   v1.3.0 起取消场景, 只保留档位; 调度与 IO 由档位自动派生,
#   什么时候用哪个档位由守护进程按"息屏 / 应用策略 / 方案默认档"自动决定。
#
# 本文件只做组合与顺序; 调速器仍由 apply_profile 写入,
# 禁止在别处改 scaling_governor (AGENTS: 控制链只有一条)
# ============================================================
# shellcheck disable=SC1091
MODDIR="${MODDIR:-$(dirname "$(dirname "$0")")}"
[ -f "$MODDIR/lib/common.sh" ] && . "$MODDIR/lib/common.sh"
[ -f "$MODDIR/lib/governor.sh" ] && . "$MODDIR/lib/governor.sh"
[ -f "$MODDIR/lib/extreme.sh" ] && . "$MODDIR/lib/extreme.sh"

# 档位 -> 调度策略(game / balance / powersave)
sched_of_profile() {
  case "$1" in
    performance|game_medium) echo game ;;
    powersave|powersave+)    echo powersave ;;
    *)                       echo balance ;;
  esac
}

# 档位 -> IO 策略(game / daily)
io_of_profile() {
  case "$1" in
    performance) echo game ;;
    *)           echo daily ;;
  esac
}

# v3.4.0 极致省电: 限制层生效时, 调度策略一律用最省电的那一套。
#   复用【已有的】sched_powersave.conf(本机实机验证可写的节点),
#   不新造一套数值 —— 实测数据里没有的取值不写进代码(AGENTS.md 纪律)。
#   真正额外的收紧来自另外两层:
#     governor 层: CPU 频率上限 / GPU 上限 / boost / cm_perf / c2ps
#     loop 层:     sugov_ext 升降频节奏 + hmbird boost 阈值
#   这两层的杠杆都有实机实验数据支撑(docs/arch-realdevice.md)。
sched_effective() {
  local prof="$1" s
  s=$(sched_of_profile "$prof")
  extreme_state_read
  [ "$EXTREME_ON" = 1 ] && s=powersave
  echo "$s"
}

# 应用档位编排: <profile>
# 顺序: 频率档位(调速器) -> 调度策略(PELT/uclamp, 不动调速器) -> IO
# 触控不在编排内: 由守护进程每轮按 触控.md 的游戏名单独立决定(采样率 != CPU 调度)
#
# v3.1: 频率上限不再在 apply_cpu 里直接写节点 ——
#   apply_cpu 只写调速器与最低频率, 并把档位目标上限记到 runtime/cap.target,
#   由 lib/loop.sh 的 cap_apply 统一落盘(唯一写入者)。
#   这样温控降额与档位上限不会互相覆盖。
sys_apply() {
  local prof="${1:-balanced}" sched io
  runtime_dir
  apply_profile "$prof" || { log_err "apply: 档位 $prof 应用失败"; return 1; }
  sched=$(sched_effective "$prof")
  if [ -f "$MODDIR/lib/sched.sh" ]; then
    MODDIR="$MODDIR" PMK_DATA_DIR="$PMK_DATA_DIR" PMK_CONFIG_DIR="$PMK_CONFIG_DIR" \
      sh "$MODDIR/lib/sched.sh" apply "$sched" 2>/dev/null
  fi
  io=$(io_of_profile "$prof")
  if [ -f "$MODDIR/lib/io.sh" ]; then
    MODDIR="$MODDIR" PMK_DATA_DIR="$PMK_DATA_DIR" PMK_CONFIG_DIR="$PMK_CONFIG_DIR" \
      sh "$MODDIR/lib/io.sh" apply "$io" 2>/dev/null
  fi
  echo "$prof" > "$PMK_RUNTIME_DIR/profile.applied" 2>/dev/null
  log_info "apply: $prof (sched=$sched io=$io)"
  return 0
}

# source 守卫
[ "$(basename "$0" 2>/dev/null)" = "apply.sh" ] || return 0 2>/dev/null
case "$1" in
  apply) shift; sys_apply "$1" ;;
  sched-of) shift; sched_of_profile "$1" ;;
  io-of) shift; io_of_profile "$1" ;;
esac
