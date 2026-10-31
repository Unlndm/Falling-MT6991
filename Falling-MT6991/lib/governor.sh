#!/system/bin/sh
# ============================================================
# Falling-MT6991 档位应用核心
# 覆盖: CPU 三簇调速器/频率上限/速率 / GPU devfreq+GED boost /
#       cm_mgr 性能模式与 DRAM OPP / c2ps 省电 / 温控开关。
# 所有写入带 available_* 白名单校验, 失败仅记日志不回滚。
# ============================================================
# shellcheck disable=SC1091
MODDIR="${MODDIR:-$(dirname "$(dirname "$0")")}"
[ -f "$MODDIR/lib/common.sh" ] && . "$MODDIR/lib/common.sh"
[ -f "$MODDIR/lib/extreme.sh" ] && . "$MODDIR/lib/extreme.sh"

DEVICE_CONF="$PMK_CONFIG_DIR/device.conf"
PROFILE_DIR="$PMK_CONFIG_DIR/profiles"
[ -f "$DEVICE_CONF" ] || sh "$MODDIR/lib/detect.sh" gen

# 官方风驰(scx)是否正在接管。
# 模块 v9.0 起不再写 scx, 因此任一簇为 scx 即代表官方 HyperBoost/风驰在管游戏 ——
# 此时本模块必须整体让路: 否则会把官方刚切好的 scx 顶回档位调速器
# (进游戏"刚有风驰就被顶成 performance"的根因)。
# 用内建 read 读 governor(实测单次 fork ~13ms, 每轮都在跑, 不该起子进程)
official_scx_active() {
  local p v
  policy_list >/dev/null
  for p in $PMK_POLICIES; do
    v=""
    read -r v < "$p/scaling_governor" 2>/dev/null
    [ "$v" = "scx" ] && return 0
  done
  return 1
}

# 是否有外部进程把 governor 切成 userspace。
# 这种情况下本模块不写 governor(否则会顶掉别人的接管)。
usergov_takeover() {
  local p v
  policy_list >/dev/null
  for p in $PMK_POLICIES; do
    v=""
    read -r v < "$p/scaling_governor" 2>/dev/null
    [ "$v" = "userspace" ] && return 0
  done
  return 1
}

# ---------- CPU: 每 policy 应用 ----------
# 注意: 本平台 available_governors/available_frequencies 属性会间歇性消失,
# 不能作为写入前置校验; 直接写, 由内核拒绝非法值, write_file 记失败日志。
apply_cpu() {
  if official_scx_active; then
    log_info "apply_cpu: 官方风驰(scx)生效中, 让路不写 CPU 参数"
    return 0
  fi
  unlock_cpufreq
  local i=0 p gov minf maxf freqs govs rc=0
  CAP_TARGET=""
  policy_list >/dev/null
  for p in $PMK_POLICIES; do
    gov=$(field "$PMK_CPU_GOVERNOR" $((i+1)))
    minf=$(field "$PMK_CPU_MINFREQ" $((i+1)))
    maxf=$(field "$PMK_CPU_MAXFREQ" $((i+1)))

    # G5: device.conf 有实机表时先校验; 表缺失记 WARN 再写
    # v3.0: device.conf 一次读入内存再查找, 不用每簇两次 grep|cut
    freqs=""; govs=""
    dev_get "POLICY${i}_FREQS" && freqs="$DEV_V"
    dev_get "POLICY${i}_GOVS"  && govs="$DEV_V"
    if [ -n "$freqs" ] && [ -n "$maxf" ]; then
      list_has "$freqs" "$maxf" || { log_err "policy$((i)) max=$maxf 不在实机频率表, 跳过"; maxf=""; }
    elif [ -z "$freqs" ] && [ -n "$maxf" ]; then
      log_debug "policy$((i)) 无频率表, 直接写 $maxf"
    fi
    if [ -n "$govs" ] && [ -n "$gov" ]; then
      list_has "$govs" "$gov" || { log_err "policy$((i)) gov=$gov 不在实机调速器表, 跳过"; gov=""; }
    elif [ -z "$govs" ] && [ -n "$gov" ]; then
      log_debug "policy$((i)) 无调速器表, 直接写 $gov"
    fi

    # v3.1 架构: 频率上限不再由本层写节点。
    #   实机结论(PLC110/ColorOS): scaling_max_freq 被系统高频抢占
    #   (p0 在 1200000↔2400000 之间反复跳), 写上去常被改回去,
    #   硬写还会跟官方风驰抢同一个节点。
    #   现在唯一写入者是 lib/loop.sh 的 cap_apply(档位目标 ∩ 温控降额 + 让位判定)。
    #   本层只管"调速器 + 最低频率"—— 实机验证这两样系统不抢。
    if [ -n "$maxf" ]; then
      # 只记录目标, 交给上限层落盘(不写节点)
      CAP_TARGET="$CAP_TARGET $maxf"
      log_debug "policy$((i)) 上限目标=$maxf (交上限层落盘)"
    fi
    [ -n "$minf" ] && write_file "$p/scaling_min_freq" "$minf" && log_debug "policy$((i)) min=$minf"
    [ -n "$gov" ] && ! usergov_takeover && write_file "$p/scaling_governor" "$gov" && log_debug "policy$((i)) gov=$gov"

    # v3.1: sugov_ext 速率由闭环层按帧率压力统一驱动(见 lib/loop.sh)。
    #   档位里的 UP_RATE/DOWN_RATE 改为"该档允许的执行器区间",
    #   实际每轮落盘的数值由闭环层算 —— 两个写入者会互相覆盖, 所以只留一个。
    i=$((i+1))
  done
  # 记录档位目标上限 + 该档允许的执行器上限, 供上限层/闭环层使用
  if [ -n "$CAP_TARGET" ]; then
    runtime_dir
    printf '%s\n' "$CAP_TARGET" > "$PMK_RUNTIME_DIR/cap.target" 2>/dev/null
    # EXEC_LEVEL: 该档允许的闭环最高档位(空=不限, 也就是 4)
    lvl="$PMK_CPU_EXEC_LEVEL"
    case "$lvl" in
      ''|*[!0-9]*) lvl=4 ;;
    esac
    [ "$lvl" -gt 4 ] 2>/dev/null && lvl=4
    printf '%s\n' "$lvl" > "$PMK_RUNTIME_DIR/cap.execmax" 2>/dev/null
  fi
  return $rc
}

# ---------- GPU: devfreq + GED boost ----------
apply_gpu() {
  local d=""
  dev_get GPU_DEV && d="$DEV_V"
  [ -n "$d" ] && [ -d "/sys/class/devfreq/$d" ] || return 0
  local gdev="/sys/class/devfreq/$d"

  [ -n "$PMK_GPU_GOVERNOR" ] && write_file "$gdev/governor" "$PMK_GPU_GOVERNOR" \
    && log_info "gpu gov=$PMK_GPU_GOVERNOR"

  # GED boost 参数(kHz; 实机验证可写)
  [ -f /sys/module/ged/parameters/gpu_cust_upbound_freq ] && [ -n "$PMK_GPU_UPBOUND" ] && \
    write_file /sys/module/ged/parameters/gpu_cust_upbound_freq "$PMK_GPU_UPBOUND"
  [ -f /sys/module/ged/parameters/gpu_cust_boost_freq ] && [ -n "$PMK_GPU_BOOST" ] && \
    write_file /sys/module/ged/parameters/gpu_cust_boost_freq "$PMK_GPU_BOOST"
  if [ -n "$PMK_GPU_BOOST_EN" ]; then
    write_file /sys/module/ged/parameters/boost_gpu_enable "$PMK_GPU_BOOST_EN"
    # 总开关语义跟随 BOOST_EN(原恒写 1, BOOST_EN=0 时总开关被误开)
    write_file /sys/module/ged/parameters/ged_boost_enable "$PMK_GPU_BOOST_EN"
  fi
}

# ---------- cm_mgr(新平台替代 /proc/ppm; 语法 "key value") ----------
apply_cm() {
  local f=/sys/kernel/cm_mgr/dbg_cm_mgr
  [ -f "$f" ] || return 0
  # G4: 与其它 sysfs 同一套 write_file(含失败日志), 不 chmod 此节点
  [ -n "$PMK_CM_PERF_EN" ]  && write_file "$f" "cm_perf_mode_enable $PMK_CM_PERF_EN"
  [ -n "$PMK_CM_PERF_OPP" ] && write_file "$f" "cm_perf_mode_ceiling_opp $PMK_CM_PERF_OPP"
  [ -n "$PMK_CM_DRAM_CEIL" ] && write_file "$f" "cm_mgr_dram_opp_ceiling $PMK_CM_DRAM_CEIL"
  [ -n "$PMK_CM_DRAM_FLOOR" ] && write_file "$f" "cm_mgr_dram_opp_floor $PMK_CM_DRAM_FLOOR"
  log_info "cm_mgr applied (perf_en=$PMK_CM_PERF_EN ceil_opp=$PMK_CM_PERF_OPP dram=$PMK_CM_DRAM_CEIL)"
}

# ---------- c2ps 省电调度(最佳努力) ----------
apply_c2ps() {
  [ -n "$PMK_C2PS_UM" ] || return 0
  local f=/sys/module/mtk_c2ps/parameters/c2ps_um_mode_on
  [ -f "$f" ] || return 0
  write_file "$f" "$PMK_C2PS_UM" && log_info "c2ps um_mode=$PMK_C2PS_UM"
}

# ---------- 极致省电限制层退出时的非 CPU 还原 ----------
# 限制层生效时, GPU / cm_mgr / c2ps 三个节点的取值被压低了。
# 限制层退出(用户关开关, 或游戏开始触发豁免)时必须把它们恢复成档位原值,
# 否则会出现"游戏已经接管, 但 GPU 还钉在最低频"的怪状态。
#
# 为什么不复用 apply_profile: 它会连带写 CPU(调速器/最低频率),
# 而游戏让路(交官方调度)期间模块不允许碰 CPU 节点。
# 所以这里只还原非 CPU 的三个部分, CPU 由上限层/让路路径自己处理。
apply_profile_non_cpu() {
  local name="$1" conf="$PROFILE_DIR/$1.conf"
  [ -f "$conf" ] || return 1
  # 先备份出厂值, 再套限制层钳制 —— 与 apply_profile 的顺序一致,
  # 保证写出去的仍然是"档位原值", 而不是被钳制过的值
  load_profile "$conf"
  apply_gpu
  apply_cm
  apply_c2ps
  return 0
}

# ---------- 主入口 ----------
apply_profile() {
  local name="$1"
  local conf="$PROFILE_DIR/$name.conf"
  [ -f "$conf" ] || { log_err "profile not found: $name"; return 1; }
  load_profile "$conf"
  # v3.4.0 极致省电限制层: 在档位值之上叠一层更狠的钳制。
  #   它只改 PMK_* 值, 不写节点 —— 写入者仍然是下面那四个 apply_* 函数,
  #   所以"一个节点一个写入者"这条硬规则不受影响。
  #   生效态来自 runtime/extreme.state(daemon 写), 游戏期间自动为 0。
  if [ -f "$MODDIR/lib/extreme.sh" ]; then
    extreme_state_read
    extreme_clamp_profile
  fi
  # CPU 上限写失败 -> 返回失败(供 bootloop 回滚判定, 不误 ack)
  runtime_dir
  apply_cpu || { log_err "profile $name: CPU 上限写入失败"; return 1; }
  apply_gpu
  apply_cm
  apply_c2ps
  # C3: 运行时生效档记录(WebUI 显示 生效/默认 两行)
  echo "$name" > "$PMK_RUNTIME_DIR/profile.runtime" 2>/dev/null
  log_info "profile applied: $name"
  return 0
}

# ---------- 温控开关 ----------
# thermal_limit <enable|disable>; 仅操作 CPU/GPU/soc 类 zone, 备份原状态。
# 内核 mode 节点取值: enabled/disabled (注意与 enable/disable 语义区分)
# v2.3: UI 的"绕过温控"已在 v2.0 移除, 现在只有 uninstall.sh 调 enable,
# 用来还原 v1.x 用户当年留下的 disabled 状态; 不再写 thermal_state 文件。
thermal_limit() {
  local act="$1" kw out="$PMK_CONFIG_DIR/thermal_backup"
  case "$act" in
    enable)  kw=enabled ;;
    disable) kw=disabled ;;
    *) log_err "thermal_limit: bad action $act"; return 1 ;;
  esac
  local found=0 z t
  for z in /sys/class/thermal/thermal_zone*; do
    t=$(cat "$z/type" 2>/dev/null)
    case "$t" in
      cpu-*|gpu*|soc*|apu*)
        found=1
        if [ "$act" = disable ]; then
          grep -q "^$(basename "$z") " "$out" 2>/dev/null || \
            echo "$(basename "$z") $(cat "$z/mode" 2>/dev/null)" >> "$out" 2>/dev/null
        fi
        write_file "$z/mode" "$kw"
        ;;
    esac
  done
  if [ "$act" = enable ]; then
    while read -r z mode; do
      [ -n "$z" ] && [ -d "/sys/class/thermal/$z" ] && write_file "/sys/class/thermal/$z/mode" "$mode"
    done < "$out" 2>/dev/null
    rm -f "$out" 2>/dev/null
  fi
  [ "$found" = 1 ] && log_info "thermal_limit: $act" || log_err "thermal_limit: no target zones"
}

# ---------- 校验档位(对照 device.conf 持久表) ----------
validate_profile() {
  local name="$1" rc=0
  local conf="$PROFILE_DIR/$name.conf"
  [ -f "$conf" ] || { echo "profile not found: $name"; return 2; }
  load_profile "$conf"

  local i=0 gov maxf govs freqs np=0
  dev_get N_POLICY && np="$DEV_V"
  [ -n "$np" ] || np=0
  while [ "$i" -lt "$np" ]; do
    gov=$(field "$PMK_CPU_GOVERNOR" $((i+1)))
    maxf=$(field "$PMK_CPU_MAXFREQ" $((i+1)))
    govs=""; freqs=""
    dev_get "POLICY${i}_GOVS"  && govs="$DEV_V"
    dev_get "POLICY${i}_FREQS" && freqs="$DEV_V"
    [ -n "$govs" ] && [ -n "$gov" ] && ! list_has "$govs" "$gov" \
      && { echo "FAIL policy$i: gov $gov not allowed"; rc=1; }
    [ -n "$freqs" ] && [ -n "$maxf" ] && ! list_has "$freqs" "$maxf" \
      && { echo "FAIL policy$i: freq $maxf not in table"; rc=1; }
    i=$((i+1))
  done
  [ "$np" = 0 ] && echo "WARN device.conf missing policy tables"

  local d govs2
  d=""; dev_get GPU_DEV && d="$DEV_V"
  if [ -n "$d" ] && [ -n "$PMK_GPU_GOVERNOR" ]; then
    govs2=""; dev_get GPU_GOVS && govs2="$DEV_V"
    list_has "$govs2" "$PMK_GPU_GOVERNOR" || { echo "FAIL gpu: gov $PMK_GPU_GOVERNOR not allowed"; rc=1; }
  fi
  [ "$rc" = 0 ] && echo "OK $name"
  return $rc
}

# ---------- 配置备份 ----------
backup_config() {
  local dst="/data/local/tmp/falling_mt6991_backup_$(date '+%Y%m%d_%H%M%S')"
  cp -r "$PMK_CONFIG_DIR" "$dst" 2>/dev/null && { echo "backup -> $dst"; return 0; }
  echo "backup FAIL"; return 1
}

# ---------- 内部调用入口(替代 CLI; 供 WebUI/服务/外部脚本调用) ----------
# source 守卫: 仅直接执行时进入命令分发, 避免被 daemon/service source 时误触发
[ "$(basename "$0" 2>/dev/null)" = "governor.sh" ] || return 0 2>/dev/null
case "$1" in
  apply)
    shift
    # v2.0: 手动选档入口已移除(全智能); 保留此命令只作排障时直接套档
    apply_profile "$1" && rollback_ack
    ;;
  thermal)  shift; thermal_limit "$1" ;;
  validate) shift; validate_profile "$1" ;;
  backup)   backup_config ;;
esac
