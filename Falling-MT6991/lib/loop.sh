#!/system/bin/sh
# ============================================================
# Falling-MT6991 帧率闭环 + CPU 上限决策层 (v3.1)
#
# 为什么要有这一层(架构依据来自实机实验, 不是猜的):
#
#   实机(Node: PLC110 / MT6991 / Android 17 / ColorOS)测了三类节点的存活情况:
#     - scaling_max_freq        : 系统高频抢占(p0 在 1200M↔2400M 跳), 写上去
#                                  经常几秒内就被改回去 —— 不可靠
#     - sugov_ext/*_rate_limit_us: 能撑 50 秒不被改, 但系统会间歇重置回 10,
#                                  需要守护每轮重申 —— 半可靠, 但效果极强
#     - /proc/hmbird_sched/*    : 写进去 60 秒纹丝不动 —— 最可靠
#     (详见 docs/arch-realdevice.md)
#
#   所以档位重心按可靠度重排:
#     主力 = hmbird 百分比阈值(稳) + sugov_ext 升降频速率(强, 需重申)
#     兜底 = scaling_max_freq(不可靠, 只在追帧时抬, 且让位给系统)
#
# 本文件承担两件事:
#   1) loop_tick : 帧率闭环。按帧率达标率 + 大核占用 + 温度算"追帧压力",
#                  映射到执行器档位(level 0..4), 落到 hmbird 阈值与
#                  sugov_ext 速率上。
#   2) cap_apply : scaling_max_freq 的唯一写入者。档位目标上限 ∩ 温控降额,
#                  并做"让位判定" —— 系统主动压低且追帧压力不高时接受系统的值,
#                  不跟系统抢同一个节点。
#
# 控制链只有一条(AGENTS 硬规则):
#   governor.sh 不再写 scaling_max_freq, thermal.sh 不再自己降频,
#   两者都只提供输入, 由本文件统一落盘。
# ============================================================
# shellcheck disable=SC1091
MODDIR="${MODDIR:-$(dirname "$(dirname "$0")")}"
[ -f "$MODDIR/lib/common.sh" ] && . "$MODDIR/lib/common.sh"
[ -f "$MODDIR/lib/extreme.sh" ] && . "$MODDIR/lib/extreme.sh"

LOOP_STATE="$PMK_RUNTIME_DIR/loop.state"
CAP_BASE="$PMK_RUNTIME_DIR/cap.base"     # policyN <target> <applied>
CAP_STATE="$PMK_RUNTIME_DIR/cap.state"   # released=0|1  last=<ts>  written=<n>
# v3.4.0 极致省电: 这四个节点的出厂值备份(退出限制层时照原样写回)
#   <policy>/sugov_ext/up_rate_limit_us, down_rate_limit_us
#   /proc/hmbird_sched/cpuctrl_high, cpuctrl_low
# 不写死还原值: 第一次生效前把当前值存下来, 退出时写回 ——
# 与 sched.sh / io.sh 的备份还原同一套做法(AGENTS.md: 不猜出厂值)。
EXTREME_BACKUP="$PMK_CONFIG_DIR/extreme_backup"

# 备份出厂值(只备份一次)
loop_backup_extreme() {
  [ -f "$EXTREME_BACKUP" ] && return 0
  : > "$EXTREME_BACKUP" 2>/dev/null
  local p v i=0
  policy_list >/dev/null
  for p in $PMK_POLICIES; do
    v=""
    read -r v < "$p/sugov_ext/up_rate_limit_us" 2>/dev/null
    [ -n "$v" ] && echo "p${i}_up $v" >> "$EXTREME_BACKUP" 2>/dev/null
    v=""
    read -r v < "$p/sugov_ext/down_rate_limit_us" 2>/dev/null
    [ -n "$v" ] && echo "p${i}_down $v" >> "$EXTREME_BACKUP" 2>/dev/null
    i=$((i + 1))
  done
  v=""
  read -r v < /proc/hmbird_sched/cpuctrl_high 2>/dev/null
  [ -n "$v" ] && echo "cp_high $v" >> "$EXTREME_BACKUP" 2>/dev/null
  v=""
  read -r v < /proc/hmbird_sched/cpuctrl_low 2>/dev/null
  [ -n "$v" ] && echo "cp_low $v" >> "$EXTREME_BACKUP" 2>/dev/null
  log_info "loop: 已备份执行器出厂值 ($(grep -c . "$EXTREME_BACKUP" 2>/dev/null) 项)"
  return 0
}

# policy 序号 -> 路径; 结果放 LOOP_POL
LOOP_POL=""
loop_policy_by_index() {
  local idx="$1" p i=0
  LOOP_POL=""
  policy_list >/dev/null
  for p in $PMK_POLICIES; do
    if [ "$i" = "$idx" ]; then LOOP_POL="$p"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

# 还原出厂值(限制层退出时调用)
loop_restore_extreme() {
  [ -f "$EXTREME_BACKUP" ] || return 0
  local k v p
  while read -r k v; do
    [ -n "$k" ] || continue
    case "$k" in
      p*_up|p*_down)
        p="${k%%_*}"
        p="${p#p}"
        case "$p" in ''|*[!0-9]*) continue ;; esac
        loop_policy_by_index "$p" || continue
        case "$k" in
          *_up)
            [ -f "$LOOP_POL/sugov_ext/up_rate_limit_us" ] && \
              write_file "$LOOP_POL/sugov_ext/up_rate_limit_us" "$v"
            ;;
          *_down)
            [ -f "$LOOP_POL/sugov_ext/down_rate_limit_us" ] && \
              write_file "$LOOP_POL/sugov_ext/down_rate_limit_us" "$v"
            ;;
        esac
        ;;
      cp_high)
        [ -f /proc/hmbird_sched/cpuctrl_high ] && \
          write_file /proc/hmbird_sched/cpuctrl_high "$v"
        ;;
      cp_low)
        [ -f /proc/hmbird_sched/cpuctrl_low ] && \
          write_file /proc/hmbird_sched/cpuctrl_low "$v"
        ;;
    esac
  done < "$EXTREME_BACKUP"
  log_info "loop: 执行器出厂值已还原"
  return 0
}

# ---------- 执行器档位表 ----------
# 索引 = level 0..4 (0 最保守, 4 最激进)
# UP   : sugov_ext/up_rate_limit_us   两次升频的最小间隔(us), 越小升得越快
#        实测: 10 -> 满载能冲到 3600000; 200000 -> CPU 被钉在 798000 地板
# DOWN : sugov_ext/down_rate_limit_us 两次降频的最小间隔(us), 越小掉得越快
#        省电档要"升得慢、降得快"(=10, 与系统默认一致)
# HI/LO: hmbird cpuctrl_high/low      boost 触发/退出的百分比阈值, 越小越激进
LOOP_UP="3000 1500 700 300 10"
LOOP_DOWN="10 10 100 1000 10000"
LOOP_HI="80 70 60 52 45"
LOOP_LO="60 52 45 40 35"

LOOP_EMA=0        # 帧率达标率 EMA(%), -1 = 无数据
LOOP_PRESS=50     # 追帧压力(0..100)
LOOP_PRESS_EMA=50 # 压力 EMA(用于滞回)
LOOP_LEVEL=2      # 执行器档位 0..4
LOOP_PEND=-1      # 待确认档位(滞回用)
LOOP_PEND_N=0     # 待确认轮数
LOOP_SINCE=0      # 距上次换 level 的秒数
LOOP_MIN_HOLD=20  # 换 level 的最小间隔(秒)
LOOP_TICK=0       # 每 N 轮才重算一次 EMA/压力(省开销)

# 追帧压力: 帧率是主因, 大核占用是佐证, 温度是刹车
loop_pressure() {
  local fps="${1:--1}" prime="${2:--1}" temp="${3:-0}"
  local p=50
  if [ "$fps" != "-1" ]; then
    if   [ "$fps" -lt 70 ];  then p=$((p + 25))
    elif [ "$fps" -lt 85 ];  then p=$((p + 12))
    elif [ "$fps" -gt 97 ];  then p=$((p - 12))
    fi
  fi
  # 大核吃满 = 上限真的不够, 追帧压力上调
  if [ "$prime" -ge 90 ] 2>/dev/null; then p=$((p + 15))
  elif [ "$prime" -ge 70 ] 2>/dev/null; then p=$((p + 8))
  fi
  # 温度刹车: 高温下不再追帧, 让温控说话
  if   [ "$temp" -ge 60000 ] 2>/dev/null; then p=$((p - 40))
  elif [ "$temp" -ge 55000 ] 2>/dev/null; then p=$((p - 20))
  elif [ "$temp" -gt 0 ] && [ "$temp" -le 45000 ] 2>/dev/null; then p=$((p - 8))
  fi
  [ "$p" -lt 0 ] && p=0
  [ "$p" -gt 100 ] && p=100
  LOOP_PRESS=$p
}

# 压力 -> level(带滞回: 连续 2 轮落在新区间才切)
loop_level_of() {
  local v="$1" want
  if   [ "$v" -lt 20 ]; then want=0
  elif [ "$v" -lt 35 ]; then want=1
  elif [ "$v" -lt 55 ]; then want=2
  elif [ "$v" -lt 75 ]; then want=3
  else want=4
  fi
  printf '%s' "$want"
}

# 读回状态(跨轮保持 EMA 与 level)
loop_load() {
  local a b c d
  LOOP_EMA=0; LOOP_PRESS_EMA=50; LOOP_LEVEL=2; LOOP_PEND=-1; LOOP_PEND_N=0; LOOP_SINCE=0
  [ -f "$LOOP_STATE" ] || return 0
  while IFS=' ' read -r a b c d; do
    case "$a" in
      ema)   case "$b" in ''|*[!0-9-]*) ;; *) LOOP_EMA="$b" ;; esac ;;
      press) case "$b" in ''|*[!0-9]*) ;; *) LOOP_PRESS_EMA="$b" ;; esac ;;
      level) case "$b" in ''|*[!0-9]*) ;; *) LOOP_LEVEL="$b" ;; esac ;;
      pend)  case "$b" in ''|*[!0-9-]*) ;; *) LOOP_PEND="$b" ;; esac ;;
      pendn) case "$b" in ''|*[!0-9]*) ;; *) LOOP_PEND_N="$b" ;; esac ;;
      since) case "$b" in ''|*[!0-9]*) ;; *) LOOP_SINCE="$b" ;; esac ;;
    esac
  done < "$LOOP_STATE" 2>/dev/null
  return 0
}

loop_save() {
  runtime_dir
  printf 'ema=%s press=%s level=%s pend=%s pendn=%s since=%s\n' \
    "$LOOP_EMA" "$LOOP_PRESS_EMA" "$LOOP_LEVEL" "$LOOP_PEND" "$LOOP_PEND_N" "$LOOP_SINCE" \
    > "$LOOP_STATE" 2>/dev/null
}

# ---------- 执行器落盘 ----------
# 把 level 映射到三簇。簇序按内核枚举顺序: policy0(小) policy4(中) policy7(大)。
# 大核是最后一个, 它决定帧率, 用本级; 中核降 1 级; 小核降 2 级(不低于 0)。
# 追帧时资源集中到大核, 小核不必跟着激进。
#
# v3.4.0 极致省电: 限制层生效时, 节奏不再由追帧压力决定 ——
#   升频间隔拉到很大(升得极慢)、降频间隔拉到最小(掉得极快),
#   hmbird boost 阈值拉到很高(很少触发 boost)。
#   这是实机验证过最强的省电杠杆(docs/arch-realdevice.md 实验2:
#   up_rate=200000 -> CPU 被钉在 798000 地板)。
loop_apply_exec() {
  local lvl="$1" i=0 n=0
  local up down hi lo p lv last=""
  policy_list >/dev/null
  # 先数有几个簇(用于算"从后往前第几簇是大核")
  for p in $PMK_POLICIES; do n=$((n + 1)); last="$p"; done
  [ "$n" -le 0 ] && return 0

  # 极致省电: 用限制层给的固定节奏, 不按 level 分簇递减
  extreme_state_read
  if [ "$EXTREME_ON" = 1 ]; then
    extreme_load
    up="$EXTREME_UP_RATE"
    down="$EXTREME_DOWN_RATE"
    hi="$EXTREME_CP_HIGH"
    lo="$EXTREME_CP_LOW"
    # 第一次生效前先备份出厂值, 退出限制层时照原样写回
    loop_backup_extreme
    i=0
    for p in $PMK_POLICIES; do
      [ -f "$p/sugov_ext/up_rate_limit_us" ] && [ -n "$up" ] && \
        write_file "$p/sugov_ext/up_rate_limit_us" "$up"
      [ -f "$p/sugov_ext/down_rate_limit_us" ] && [ -n "$down" ] && \
        write_file "$p/sugov_ext/down_rate_limit_us" "$down"
      i=$((i + 1))
    done
    [ -f /proc/hmbird_sched/cpuctrl_high ] && [ -n "$hi" ] && \
      write_file /proc/hmbird_sched/cpuctrl_high "$hi"
    [ -f /proc/hmbird_sched/cpuctrl_low ] && [ -n "$lo" ] && \
      write_file /proc/hmbird_sched/cpuctrl_low "$lo"
    return 0
  fi

  i=0
  for p in $PMK_POLICIES; do
    # 距大核的距离: 0=大核, 1=中核, 2=小核
    lv=$((lvl - (n - 1 - i)))
    [ "$lv" -lt 0 ] && lv=0
    [ "$lv" -gt 4 ] && lv=4
    up=$(field "$LOOP_UP" $((lv + 1)))
    down=$(field "$LOOP_DOWN" $((lv + 1)))
    # hmbird 阈值是全局的, 只用大核那一档的值
    if [ "$p" = "$last" ]; then
      hi=$(field "$LOOP_HI" $((lv + 1)))
      lo=$(field "$LOOP_LO" $((lv + 1)))
    fi
    [ -f "$p/sugov_ext/up_rate_limit_us" ] && [ -n "$up" ] && \
      write_file "$p/sugov_ext/up_rate_limit_us" "$up"
    [ -f "$p/sugov_ext/down_rate_limit_us" ] && [ -n "$down" ] && \
      write_file "$p/sugov_ext/down_rate_limit_us" "$down"
    i=$((i + 1))
  done
  [ -f /proc/hmbird_sched/cpuctrl_high ] && [ -n "$hi" ] && \
    write_file /proc/hmbird_sched/cpuctrl_high "$hi"
  [ -f /proc/hmbird_sched/cpuctrl_low ] && [ -n "$lo" ] && \
    write_file /proc/hmbird_sched/cpuctrl_low "$lo"
  return 0
}

# ---------- scaling_max_freq 唯一写入层 ----------
# cap_apply <档位目标上限csv> <温控比例%>
#   目标 = 档位上限 * 温控比例
#   让位: 系统把上限压得比目标低, 且追帧压力不高 -> 接受系统的值, 不抢
#         追帧压力高 -> 才把上限抬回目标(这是"追帧"才做的事, 不是常态)
#
# 基线表 cap.base 每行 "policyN <目标> <本模块上次写入值>"
#   当前值 == 上次写入值 -> 是本模块压的, 基线不动(防雪崩的关键)
#   当前值 != 上次写入值 -> 是系统/换档改的, 基线跟随(恢复时不写回旧高值)
cap_apply() {
  local target_csv="$1" ratio="${2:-100}"
  runtime_dir
  local i=0 p cur want applied base ap rest
  local wrote=0 out=""

  # 让路状态: 已释放上限就不再写 —— 否则温控兜底(>=70°C)会重新写上限,
  # 跟官方风驰抢同一个节点, 让路就白让了。
  if [ -f "$CAP_STATE" ]; then
    local k v rel=0
    while IFS='=' read -r k v; do
      [ "$k" = "released" ] && rel="$v"
    done < "$CAP_STATE" 2>/dev/null
    [ "$rel" = "1" ] && return 0
  fi

  [ -n "$target_csv" ] || target_csv=""

  policy_list >/dev/null
  for p in $PMK_POLICIES; do
    want=$(field "$target_csv" $((i + 1)))
    case "$want" in ''|*[!0-9]*) want=0 ;; esac
    if [ "$want" -gt 0 ] 2>/dev/null; then
      # 温控降额
      want=$((want * ratio / 100))
    fi
    if [ "$want" -le 0 ] 2>/dev/null; then
      i=$((i + 1)); continue
    fi

    cur=""
    read -r cur < "$p/scaling_max_freq" 2>/dev/null
    case "$cur" in ''|*[!0-9]*) { i=$((i + 1)); continue; } ;; esac

    # 读基线表里这个 policy 的记录(零 fork, 内建 read 扫小文件)
    applied=""
    if [ -f "$CAP_BASE" ]; then
      while read -r base ap; do
        [ "$base" = "${p##*/}" ] && { applied="$ap"; break; }
      done < "$CAP_BASE" 2>/dev/null
    fi

    if [ "$cur" -lt "$want" ] 2>/dev/null; then
      # 当前低于目标
      if [ "$LOOP_PRESS" -ge 60 ] 2>/dev/null; then
        # 追帧压力大: 值得抬一次(这是"追帧"行为, 不是常态)
        write_file "$p/scaling_max_freq" "$want" && wrote=1
        out="$out${p##*/} $want $want
"
      else
        # 让位给系统: 记下它给的低值, 不抢
        out="$out${p##*/} $cur $cur
"
      fi
    elif [ "$cur" -gt "$want" ] 2>/dev/null; then
      # 系统给得比我们目标高 -> 收紧(省电方向, 系统一般不抢)
      write_file "$p/scaling_max_freq" "$want" && wrote=1
      out="$out${p##*/} $want $want
"
    else
      out="$out${p##*/} $want $want
"
    fi
    i=$((i + 1))
  done
  printf '%s' "$out" > "$CAP_BASE" 2>/dev/null
  printf 'released=0\nwritten=%s\n' "$wrote" > "$CAP_STATE" 2>/dev/null
  [ "$wrote" = 1 ] && log_debug "cap_apply: 上限已落盘 (press=$LOOP_PRESS ratio=$ratio)"
  return 0
}

# 让路时解除自己的频率上限(交给官方风驰/系统自己管)
# Kin-Daemon 的洞见: 只"不再写"是半让路 —— 之前写的上限还留在节点上。
cap_release() {
  runtime_dir
  local p cur
  policy_list >/dev/null
  for p in $PMK_POLICIES; do
    [ -f "$p/scaling_max_freq" ] || continue
    cur=""
    read -r cur < "$p/cpuinfo_max_freq" 2>/dev/null
    case "$cur" in ''|*[!0-9]*) continue ;; esac
    write_file "$p/scaling_max_freq" "$cur"
  done
  : > "$CAP_BASE" 2>/dev/null
  printf 'released=1\nwritten=0\n' > "$CAP_STATE" 2>/dev/null
  log_info "cap_release: 已解除本模块的频率上限, 交还官方调度"
  return 0
}

# 紧急降额(让路期间的温度兜底)
# 让路时官方调度接管, 但 >=70°C 仍要保命 —— 这时临时重新落盘上限。
# 一次性动作: 降完把 released 清回 0, 下一轮让路判定会再释放。
cap_emergency_throttle() {
  local ratio="${1:-70}"
  runtime_dir
  local p cur want
  policy_list >/dev/null
  for p in $PMK_POLICIES; do
    [ -f "$p/scaling_max_freq" ] || continue
    cur=""
    read -r cur < "$p/cpuinfo_max_freq" 2>/dev/null
    case "$cur" in ''|*[!0-9]*) continue ;; esac
    want=$((cur * ratio / 100))
    [ "$want" -gt 0 ] 2>/dev/null || continue
    write_file "$p/scaling_max_freq" "$want"
  done
  printf 'released=0\nwritten=1\n' > "$CAP_STATE" 2>/dev/null
  log_warn "cap_emergency_throttle: 让路期间高温兜底, 上限压到 ${ratio}%"
  return 0
}

# ---------- 主入口: 每轮调用 ----------
# loop_tick <档位目标上限csv> <温控比例%> <帧率> <大核占用> <温度> <now>
loop_tick() {
  local target_csv="$1" ratio="${2:-100}" fps="${3:--1}" prime="${4:--1}" temp="${5:-0}" now="${6:-0}"
  runtime_dir

  # 让路状态: 释放后不再写任何 CPU 参数
  if [ -f "$CAP_STATE" ]; then
    local k v rel=0
    while IFS='=' read -r k v; do
      [ "$k" = "released" ] && rel="$v"
    done < "$CAP_STATE" 2>/dev/null
    [ "$rel" = "1" ] && return 0
  fi

  loop_load

  # EMA 与压力每 3 轮算一次(15 秒), 中间轮沿用
  LOOP_TICK=$((LOOP_TICK + 1))
  if [ $((LOOP_TICK % 3)) -eq 1 ] || [ "$LOOP_EMA" = "0" ]; then
    if [ "$fps" != "-1" ]; then
      if [ "$LOOP_EMA" = "0" ]; then
        LOOP_EMA="$fps"
      else
        LOOP_EMA=$(( (LOOP_EMA * 7 + fps * 3) / 10 ))
      fi
    fi
    loop_pressure "$LOOP_EMA" "$prime" "$temp"
    LOOP_PRESS_EMA=$(( (LOOP_PRESS_EMA * 3 + LOOP_PRESS) / 4 ))
  fi

  # 滞回换档: 目标 level 连续 2 轮一致才切, 且距上次切换 >= 20s
  wantlvl=$(loop_level_of "$LOOP_PRESS_EMA")
  # 档位允许的执行器上限: 该档再激进也不能超过这个值
  # 文件可能不存在(首次运行/换档前), 必须先判存在再 read, 否则报错刷屏
  execmax=""
  if [ -f "$PMK_RUNTIME_DIR/cap.execmax" ]; then
    read -r execmax < "$PMK_RUNTIME_DIR/cap.execmax" 2>/dev/null
  fi
  case "$execmax" in
    ''|*[!0-9]*) execmax=4 ;;
  esac
  [ "$execmax" -gt 4 ] 2>/dev/null && execmax=4
  [ "$wantlvl" -gt "$execmax" ] 2>/dev/null && wantlvl="$execmax"
  if [ "$wantlvl" != "$LOOP_LEVEL" ]; then
    if [ "$LOOP_PEND" = "$wantlvl" ]; then
      LOOP_PEND_N=$((LOOP_PEND_N + 1))
    else
      LOOP_PEND="$wantlvl"; LOOP_PEND_N=1
    fi
    if [ "$LOOP_PEND_N" -ge 2 ] 2>/dev/null; then
      LOOP_LEVEL="$LOOP_PEND"
      LOOP_SINCE="$now"
      LOOP_PEND=-1; LOOP_PEND_N=0
      loop_apply_exec "$LOOP_LEVEL"
      log_info "loop: 执行器档位 -> L$LOOP_LEVEL (压力=$LOOP_PRESS ema=$LOOP_PRESS_EMA fps=$LOOP_EMA)"
    fi
  else
    LOOP_PEND=-1; LOOP_PEND_N=0
  fi

  # 执行器每 2 轮重申(系统会间歇重置 sugov_ext, 必须压住)
  [ $((LOOP_TICK % 2)) -eq 0 ] && loop_apply_exec "$LOOP_LEVEL"

  cap_apply "$target_csv" "$ratio"
  loop_save
  return 0
}

loop_status() {
  loop_load
  echo "ema_fps=$LOOP_EMA"
  echo "pressure=$LOOP_PRESS"
  echo "pressure_ema=$LOOP_PRESS_EMA"
  echo "level=$LOOP_LEVEL"
  echo "up=$LOOP_UP"
  echo "down=$LOOP_DOWN"
}

# source 守卫
[ "$(basename "$0" 2>/dev/null)" = "loop.sh" ] || return 0 2>/dev/null
case "$1" in
  tick)   shift; loop_tick "$@" ;;
  status) loop_status ;;
  release) cap_release ;;
esac
