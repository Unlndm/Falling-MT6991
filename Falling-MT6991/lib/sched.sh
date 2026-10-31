#!/system/bin/sh
# ============================================================
# Falling-MT6991 调度策略(真调度层)
# 直接调内核调度器参数: PELT/EAS 响应 + MTK uclamp + 触控 boost
#          + CFS 调度器参数 + MTK hmbird 比值
#
# 设计契约(v1.2.0 起):
#   1. 探测式写入: 节点存在才写, 不存在跳过(不猜不捏造)
#   2. 键名校验: 档位 conf 里的键必须在本文件节点表内, 否则拒写并记录
#   3. 值域校验: 越界值拒写(防手改 conf 把设备写挂)
#   4. 差量还原: 切档只还原"本会话写过且新档不再需要"的键, 不做全量恢复再写
#   5. 漂移自愈: 同档重复调用只修复被系统改回的键, 不重写全部
#   6. 零 fork 查找: 节点表/出厂表/会话表在进程内建成字符串索引,
#      主循环与漂移重申不起子进程(设备上单次 fork 约 13ms)
#
# 档位: config/profiles/sched_<name>.conf, 当前: config/sched_profile
# 出厂备份: config/sched_backup  |  会话写记录: runtime/sched.written
# 目标表: runtime/sched.target(KEY PATH VALUE)  |  漂移计数: runtime/sched.drift
# 拒写记录: runtime/sched.badkeys / sched.badcount
# ============================================================
# shellcheck disable=SC1091
MODDIR="${MODDIR:-$(dirname "$(dirname "$0")")}"
[ -f "$MODDIR/lib/common.sh" ] && . "$MODDIR/lib/common.sh"

SDIR="$PMK_CONFIG_DIR/profiles"
SSTATE="$PMK_CONFIG_DIR/sched_profile"
SBACKUP="$PMK_CONFIG_DIR/sched_backup"
SWRITTEN="$PMK_RUNTIME_DIR/sched.written"
STARGET="$PMK_RUNTIME_DIR/sched.target"
SDRIFT="$PMK_RUNTIME_DIR/sched.drift"
SBAD="$PMK_RUNTIME_DIR/sched.badkeys"
SBADN="$PMK_RUNTIME_DIR/sched.badcount"

# 节点表: 键 路径
# 第一组: 实机验证(MT6991 KernelSU root), 实测存在且可写(W)
# 第二组: 通用内核 sched sysctl, 探测式(本机 6.6 内核多数没有, 没有就跳过)
SCHED_NODES="
PELT_MULTIPLIER /proc/sys/kernel/sched_pelt_multiplier
CHILD_RUNS_FIRST /proc/sys/kernel/sched_child_runs_first
RT_RUNTIME_US /proc/sys/kernel/sched_rt_runtime_us
HMBIRD_UCLAMP /proc/hmbird_sched/uclamp_ctrl
TOUCH_UP /proc/touch_boost/boost_up
TOUCH_DOWN /proc/touch_boost/boost_down
TOUCH_DURATION /proc/touch_boost/boost_duration
CFS_SCHEDSTATS /proc/sys/kernel/sched_schedstats
CFS_ENERGY_AWARE /proc/sys/kernel/sched_energy_aware
CFS_UCLAMP_MAX /proc/sys/kernel/sched_util_clamp_max
TOUCH_BOOST_TA /proc/touch_boost/boost_ta
TOUCH_BOOST_FG /proc/touch_boost/boost_fg
HMBIRD_ISOLATE /proc/hmbird_sched/isolate_ctrl
HMBIRD_MISFIT /proc/hmbird_sched/misfit_ds
HMBIRD_SLIM /proc/hmbird_sched/slim_for_app
HMBIRD_PARC_HIGH /proc/hmbird_sched/parctrl_high_ratio
HMBIRD_PARC_LOW /proc/hmbird_sched/parctrl_low_ratio
# 注意: HMBIRD_CPUCTRL_HIGH / HMBIRD_CPUCTRL_LOW 已从节点表移除(v3.1)。
#   这两个节点归帧率闭环层(lib/loop.sh)按追帧压力驱动, 调度层不写。
#   留在节点表里 = 同一个节点两个写入者, 互相覆盖。
HMBIRD_PREEMPT /proc/hmbird_sched/hmbird_preempt_policy
HMBIRD_CLUSTER_SEP /proc/hmbird_sched/cluster_separate
HMBIRD_C7TL /proc/hmbird_sched/cpu7_tl
HMBIRD_SCX_TICK /proc/hmbird_sched/scx_shadow_tick_enable
HMBIRD_HEARTBEAT /proc/hmbird_sched/heartbeat
HMBIRD_HEARTBEAT_EN /proc/hmbird_sched/heartbeat_enable
HMBIRD_WATCHDOG /proc/hmbird_sched/watchdog_enable
ISOCTRL_HIGH /proc/hmbird_sched/isoctrl_high_ratio
ISOCTRL_LOW /proc/hmbird_sched/isoctrl_low_ratio
ISO_FREE_RESCUE /proc/hmbird_sched/iso_free_rescue
PARC_HIGH_L /proc/hmbird_sched/parctrl_high_ratio_l
PARC_LOW_L /proc/hmbird_sched/parctrl_low_ratio_l
PARTIAL_CTRL /proc/hmbird_sched/partial_ctrl
SLIM_WALT_CTRL /proc/hmbird_sched/slim_walt/slim_walt_ctrl
SLIM_WALT_POLICY /proc/hmbird_sched/slim_walt/slim_walt_policy
SLIM_FPS /proc/hmbird_sched/slim_walt/frame_per_sec
SCX_GOV_CTRL /proc/hmbird_sched/slim_freq_gov/scx_gov_ctrl
CFS_UCLAMP_MIN /proc/sys/kernel/sched_util_clamp_min
CFS_LATENCY_NS /proc/sys/kernel/sched_latency_ns
CFS_MIN_GRAN_NS /proc/sys/kernel/sched_min_granularity_ns
CFS_WAKEUP_GRAN_NS /proc/sys/kernel/sched_wakeup_granularity_ns
CFS_BASE_SLICE_NS /proc/sys/kernel/sched_base_slice_ns
RT_PERIOD_US /proc/sys/kernel/sched_rt_period_us
"

# 探测式候补节点(写格式实机未确认): 只展示可用性, 不参与档位写入
PENDING_NODES="
SCX_ENABLE /proc/hmbird_sched/scx_enable
SAVE_GOV /proc/hmbird_sched/save_gov
CPU_CLUSTER_MASKS /proc/hmbird_sched/cpu_cluster_masks
HMBIRDCORE_DEBUG /proc/hmbird_sched/hmbirdcore_debug
HIGHRES_DBG /proc/hmbird_sched/highres_tick_ctrl_dbg
SLIM_GOV_DEBUG /proc/hmbird_sched/slim_freq_gov/slim_gov_debug
SLIM_STATS /proc/hmbird_sched/slim_stats
SLIM_WALT_DUMP /proc/hmbird_sched/slim_walt/slim_walt_dump
"

# 触发型节点: 写入即触发一次动作, 读回值无意义
# 不参与漂移检测、不参与出厂兜底还原(否则每次还原都会触发一次升频)
SCHED_TRIGGER_KEYS="TOUCH_UP TOUCH_DOWN TOUCH_BOOST_TA TOUCH_BOOST_FG"

# ---------- 进程内索引(全部纯字符串, 零 fork) ----------
NP_MAP=""    # |KEY=path|
SB_MAP=""    # |KEY=factory|
SB_READY=""  # 出厂表已装载
SW_KEYS=""   # " K1 K2 "
_PATH=""     # sched_path_of 输出
_BASE=""     # sched_base_of 输出

sched_load_nodes() {
  local k p
  NP_MAP=","
  while read -r k p; do
    [ -n "$k" ] && [ -n "$p" ] && NP_MAP="$NP_MAP$k=$p,"
  done <<EOF
$SCHED_NODES
EOF
}

# 键 -> 路径; 命中返回 0 并设 _PATH, 未命中返回 1
sched_path_of() {
  [ -n "$NP_MAP" ] || sched_load_nodes
  local rest="${NP_MAP#*,$1=}"
  [ "$rest" = "$NP_MAP" ] && return 1
  _PATH="${rest%%,*}"
  [ -n "$_PATH" ] || return 1
  return 0
}

# 兼容旧调用点: 键 -> 路径(输出)。内部不再使用, 保留给外部脚本
node_path() { sched_path_of "$1" && printf '%s' "$_PATH"; }

# 出厂基线: sched_backup -> |KEY=value|
sched_load_base() {
  local k v
  SB_MAP=","
  SB_READY=1
  [ -f "$SBACKUP" ] || return 0
  while read -r k v; do
    [ -n "$k" ] && SB_MAP="$SB_MAP$k=$v,"
  done < "$SBACKUP"
}

# 取出厂值; 命中返回 0 并设 _BASE
sched_base_of() {
  local rest
  [ -n "$SB_READY" ] || sched_load_base
  rest="${SB_MAP#*,$1=}"
  [ "$rest" = "$SB_MAP" ] && return 1
  _BASE="${rest%%,*}"
  return 0
}

# 会话已写键 -> " K1 K2 "
sched_load_written() {
  local k v
  SW_KEYS=" "
  [ -f "$SWRITTEN" ] || return 0
  while read -r k v; do
    [ -n "$k" ] && SW_KEYS="$SW_KEYS$k "
  done < "$SWRITTEN"
}

# 读节点值(内建 read, 零 fork)
node_get() {
  local v=""
  [ -f "$1" ] && read -r v < "$1" 2>/dev/null
  printf '%s' "${v%"${v##*[![:space:]]}"}"
}

# 触发型键?
sched_trigger_key() {
  case " $SCHED_TRIGGER_KEYS " in *" $1 "*) return 0 ;; esac
  return 1
}

# 键值域 [下限 上限]
sched_key_range() {
  case "$1" in
    PELT_MULTIPLIER) echo "1 4" ;;
    RT_RUNTIME_US|RT_PERIOD_US) echo "1 1000000" ;;
    CFS_UCLAMP_MAX|CFS_UCLAMP_MIN|HMBIRD_MISFIT) echo "0 1024" ;;
    SLIM_FPS) echo "1 240" ;;
    CFS_LATENCY_NS|CFS_MIN_GRAN_NS|CFS_WAKEUP_GRAN_NS|CFS_BASE_SLICE_NS) echo "100000 200000000" ;;
    *) echo "0 100" ;;
  esac
}

# 值域校验(纯数字 + 区间; PELT 只接受 1/2/4, 内核只认这三个倍率)
sched_value_ok() {
  local k="$1" v="$2" lo hi
  case "$v" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$k" in
    PELT_MULTIPLIER) case "$v" in 1|2|4) ;; *) return 1 ;; esac ;;
  esac
  set -- $(sched_key_range "$k")
  lo="$1"; hi="$2"
  [ "$v" -ge "$lo" ] 2>/dev/null && [ "$v" -le "$hi" ] 2>/dev/null || return 1
  return 0
}

# 归一化档位文件(去注释/去 CR/去首尾空白/去空行) -> stdout
sched_norm() {
  sed -e 's/#.*//' -e 's/\r//' \
      -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      -e '/^$/d' "$1" 2>/dev/null
}

# 建目标表: runtime/sched.target, 每行 "KEY PATH VALUE"(未知键路径记 -)
# 路径只在这里解析一次; 之后的写入与漂移重申全部内建 read
sched_target_build() {
  local conf="$1" k v p
  runtime_dir
  : > "$STARGET" 2>/dev/null
  sched_norm "$conf" | while IFS='=' read -r k v; do
    [ -n "$k" ] || continue
    if sched_path_of "$k"; then p="$_PATH"; else p="-"; fi
    echo "$k $p $v" >> "$STARGET" 2>/dev/null
  done
  [ -s "$STARGET" ]
}

# 节点可用性探测(WebUI 展示): SCHED_NODES + PENDING_NODES
# 输出: KEY PATH ok VALUE | KEY PATH missing
sched_probe() {
  local k p v line
  for line in $SCHED_NODES $PENDING_NODES; do
    case "$line" in
      /*)
        p="$line"
        if [ -f "$p" ]; then
          v=$(node_get "$p")
          echo "$k $p ok ${v:-}"
        else
          echo "$k $p missing"
        fi
        ;;
      *) k="$line" ;;
    esac
  done
}

# 首次备份出厂值(卸载/关闭还原用)
sched_backup() {
  [ -f "$SBACKUP" ] && return 0
  runtime_dir
  : > "$SBACKUP" 2>/dev/null
  local k p
  while read -r k p; do
    [ -n "$k" ] || continue
    [ -f "$p" ] || continue
    echo "$k $(node_get "$p")" >> "$SBACKUP" 2>/dev/null
  done <<EOF
$SCHED_NODES
EOF
  SB_MAP=""
  SB_READY=""
  log_info "sched: 出厂值已备份 ($(grep -c . "$SBACKUP" 2>/dev/null) 项)"
}

# 写节点 + 记录基线(仅首次)
# 基线优先取出厂备份(升级时 runtime 被清也不会把本档值当成原值, 保证零残留)
# 同值直接跳过: 不写 sysfs, 也不触发 write_file 的回读
sched_write_path() {
  local p="$1" k="$2" v="$3" now=""
  if ! sched_trigger_key "$k"; then
    case "$SW_KEYS" in
      *" $k "*) ;;
      *)
        if sched_base_of "$k"; then now="$_BASE"; else read -r now < "$p" 2>/dev/null; fi
        if [ -n "$now" ]; then
          echo "$k $now" >> "$SWRITTEN" 2>/dev/null
          SW_KEYS="$SW_KEYS$k "
        fi
        ;;
    esac
    now=""
    read -r now < "$p" 2>/dev/null
    [ "$now" = "$v" ] && return 0
  fi
  write_file "$p" "$v"
}

# 还原本会话写过的全部键(原值), 清记录
sched_reset() {
  [ -f "$SWRITTEN" ] || return 0
  local k v
  while read -r k v; do
    [ -n "$k" ] || continue
    sched_trigger_key "$k" && continue
    sched_path_of "$k" || continue
    write_file "$_PATH" "$v"
  done < "$SWRITTEN"
  rm -f "$SWRITTEN" 2>/dev/null
  SW_KEYS=" "
}

# 差量还原: 只还原"本会话写过、但新档不再需要"的键
# 仍在目标里的键保留基线记录(新档继续写它, 将来仍可还原)
sched_restore_absent() {
  local keep=" $1 " k v
  [ -f "$SWRITTEN" ] || return 0
  : > "$SWRITTEN.new" 2>/dev/null
  while read -r k v; do
    [ -n "$k" ] || continue
    case "$keep" in
      *" $k "*)
        echo "$k $v" >> "$SWRITTEN.new" 2>/dev/null
        continue
        ;;
    esac
    sched_trigger_key "$k" && continue
    sched_path_of "$k" || continue
    write_file "$_PATH" "$v"
  done < "$SWRITTEN"
  mv -f "$SWRITTEN.new" "$SWRITTEN" 2>/dev/null
}

# 漂移自愈: 同档重复调用时, 只把被系统改回的键写回目标值
# 触发型节点不参与(否则每轮重申都会触发一次升频)
sched_reassert() {
  local k p v cur drift=0
  [ -f "$STARGET" ] || return 0
  sched_load_written
  while read -r k p v; do
    [ -n "$k" ] || continue
    [ "$p" = "-" ] && continue
    sched_trigger_key "$k" && continue
    [ -f "$p" ] || continue
    cur=""
    read -r cur < "$p" 2>/dev/null
    [ "$cur" = "$v" ] && continue
    sched_write_path "$p" "$k" "$v"
    drift=$((drift + 1))
    log_info "sched: 漂移修复 $k '$cur' -> '$v'"
  done < "$STARGET"
  runtime_dir
  echo "$drift" > "$SDRIFT" 2>/dev/null
  [ "$drift" -gt 0 ] && log_info "sched: 重申修复 $drift 项"
  return 0
}

# 应用档位 <name>
sched_apply() {
  local name="$1"
  local conf="$SDIR/sched_$name.conf"
  local cur_state
  [ -f "$conf" ] || { log_err "sched profile not found: $name"; return 1; }
  runtime_dir
  cur_state=$(cat "$SSTATE" 2>/dev/null)
  # 同档且档位文件没被改过: 只做漂移自愈(不重写全部, 避免调度抖)
  # conf 比 target 新(用户改了档位文件)则走完整应用, 保证改动即时生效
  if [ "$cur_state" = "$name" ] && [ -f "$STARGET" ] && [ ! "$conf" -nt "$STARGET" ]; then
    log_debug "sched: $name 已应用, 走漂移自愈"
    sched_reassert
    return 0
  fi
  sched_backup
  sched_target_build "$conf" || { log_err "sched: $conf 解析失败"; return 1; }
  sched_load_written

  # 目标键清单 -> 差量还原
  local keys=" " k p v
  while read -r k p v; do
    [ -n "$k" ] && keys="$keys$k "
  done < "$STARGET"
  sched_restore_absent "$keys"
  sched_load_written

  : > "$SBAD" 2>/dev/null
  local applied=0 skipped=0 missing=0
  while read -r k p v; do
    [ -n "$k" ] || continue
    if [ "$p" = "-" ]; then
      echo "$k unknown_key" >> "$SBAD" 2>/dev/null
      skipped=$((skipped + 1))
      log_err "sched: 未知键 $k (档位 $name), 已拒写"
      continue
    fi
    if ! sched_value_ok "$k" "$v"; then
      echo "$k bad_value_$v" >> "$SBAD" 2>/dev/null
      skipped=$((skipped + 1))
      log_err "sched: 值越界 $k=$v (档位 $name), 已拒写"
      continue
    fi
    if [ ! -f "$p" ]; then
      missing=$((missing + 1))
      log_debug "sched: 节点缺失 $k ($p), 跳过"
      continue
    fi
    sched_write_path "$p" "$k" "$v"
    applied=$((applied + 1))
  done < "$STARGET"

  echo 0 > "$SDRIFT" 2>/dev/null
  echo "$skipped" > "$SBADN" 2>/dev/null
  echo "$name" > "$SSTATE" 2>/dev/null
  log_info "sched profile applied: $name (写入 $applied 项, 节点缺失 $missing, 拒写 $skipped)"
  [ "$skipped" -gt 0 ] && log_warn "sched: 档位 $name 有 $skipped 项被拒写, 详见 runtime/sched.badkeys"
  return 0
}

# 关闭调度层: 还原会话改动 -> 出厂备份兜底 -> 清状态
# 会话记录在(常规情况)只还原本模块写过的键, 不动别的模块/系统自己改的值;
# 会话记录丢失(运行目录被清)时才用出厂备份兜底, 保证卸载零残留。
sched_disable() {
  local had_written=0 k v p cur
  [ -f "$SWRITTEN" ] && had_written=1
  sched_reset
  if [ "$had_written" = 0 ] && [ -f "$SBACKUP" ]; then
    while read -r k v; do
      [ -n "$k" ] || continue
      sched_trigger_key "$k" && continue
      sched_path_of "$k" || continue
      p="$_PATH"
      [ -f "$p" ] || continue
      cur=""
      read -r cur < "$p" 2>/dev/null
      [ "$cur" = "$v" ] && continue
      write_file "$p" "$v"
    done < "$SBACKUP"
  fi
  rm -f "$SSTATE" "$SBACKUP" "$STARGET" "$SDRIFT" "$SBAD" "$SBADN" 2>/dev/null
  log_info "sched: 已还原出厂"
}

sched_status() {
  local cur drift bad
  cur=$(cat "$SSTATE" 2>/dev/null)
  drift=""; read -r drift < "$SDRIFT" 2>/dev/null
  bad=""; read -r bad < "$SBADN" 2>/dev/null
  echo "profile=${cur:-none}"
  echo "drift=${drift:-0}"
  echo "badkeys=${bad:-0}"
  echo "pelt=$(node_get /proc/sys/kernel/sched_pelt_multiplier)"
  echo "uclamp_ctrl=$(node_get /proc/hmbird_sched/uclamp_ctrl)"
  echo "uclamp_max=$(node_get /proc/sys/kernel/sched_util_clamp_max)"
  echo "touch_boost=$(node_get /proc/touch_boost/boost_up)/$(node_get /proc/touch_boost/boost_duration)"
  echo "cfs_energy_aware=$(node_get /proc/sys/kernel/sched_energy_aware)"
  echo "boost_ta=$(node_get /proc/touch_boost/boost_ta)"
  echo "hmbird_isolate=$(node_get /proc/hmbird_sched/isolate_ctrl)"
  echo "hmbird_parctrl=$(node_get /proc/hmbird_sched/parctrl_high_ratio)/$(node_get /proc/hmbird_sched/parctrl_low_ratio)"
  echo "hmbird_misfit=$(node_get /proc/hmbird_sched/misfit_ds)"
  echo "hmbird_slim=$(node_get /proc/hmbird_sched/slim_for_app)"
  echo "isoctrl=$(node_get /proc/hmbird_sched/isoctrl_high_ratio)/$(node_get /proc/hmbird_sched/isoctrl_low_ratio)"
  echo "scx_gov_ctrl=$(node_get /proc/hmbird_sched/slim_freq_gov/scx_gov_ctrl)"
  echo "slim_walt=$(node_get /proc/hmbird_sched/slim_walt/slim_walt_ctrl)"
}

# 全部调度档自检: 未知键 / 值越界 / 本机缺节点
# 有任何未知键或越界值返回 1(打包前与 WebUI 都可调用)
sched_check() {
  local rc=0 f base tmp k v uk bv miss found=0
  runtime_dir
  tmp="$PMK_RUNTIME_DIR/.sched_check.tmp"
  for f in "$SDIR"/sched_*.conf; do
    [ -f "$f" ] || continue
    found=$((found + 1))
    base=$(basename "$f" .conf)
    uk=0; bv=0; miss=0
    sched_norm "$f" > "$tmp" 2>/dev/null || continue
    while IFS='=' read -r k v; do
      [ -n "$k" ] || continue
      if ! sched_path_of "$k"; then
        echo "FAIL $base: 未知键 $k"
        uk=$((uk + 1))
        continue
      fi
      if ! sched_value_ok "$k" "$v"; then
        echo "FAIL $base: 值越界 $k=$v"
        bv=$((bv + 1))
        continue
      fi
      [ -f "$_PATH" ] || miss=$((miss + 1))
    done < "$tmp"
    [ $((uk + bv)) -gt 0 ] && rc=1
    echo "CHECK $base: 未知键 $uk, 越界 $bv, 本机缺节点 $miss"
  done
  rm -f "$tmp" 2>/dev/null
  # 目录空/路径错不算通过(否则"没检查到"会被当成"检查通过")
  if [ "$found" = 0 ]; then
    echo "FAIL 档位目录没有 sched_*.conf: $SDIR"
    return 1
  fi
  [ "$rc" = 0 ] && echo "OK" || echo "FAIL"
  return $rc
}

# source 守卫: 仅直接执行时进入命令分发
[ "$(basename "$0" 2>/dev/null)" = "sched.sh" ] || return 0 2>/dev/null
case "$1" in
  apply)    shift; sched_apply "$1" ;;
  reassert) sched_reassert ;;
  disable)  sched_disable ;;
  status)   sched_status ;;
  backup)   sched_backup ;;
  reset)    sched_reset ;;
  probe)    sched_probe ;;
  check)    sched_check ;;
esac
