#!/system/bin/sh
# ============================================================
# Falling-MT6991 设备检测 -> 生成 config/device.conf
# 数据全部来自实机 sysfs 读取。
# ============================================================
# shellcheck disable=SC1091
MODDIR="${MODDIR:-$(dirname "$(dirname "$0")")}"
[ -f "$MODDIR/lib/common.sh" ] && . "$MODDIR/lib/common.sh"

gen_device_conf() {
  mkdir -p "$PMK_CONFIG_DIR" 2>/dev/null
  local out="$PMK_CONFIG_DIR/device.conf"
  {
    echo "# Falling-MT6991 device.conf (auto-generated $(date '+%F %T'))"
    echo "DEVICE=$(get_prop ro.product.device)"
    echo "MODEL=$(get_prop ro.product.model)"
    echo "SOC=$(get_prop ro.board.platform)"
    echo "ANDROID=$(get_prop ro.build.version.release)"
    echo "SDK=$(get_prop ro.build.version.sdk)"
    echo "KERNEL=$(uname -r)"

    local i=0 p
    for p in $(policy_list); do
      echo "POLICY${i}_CPUS=$(cat "$p/related_cpus" 2>/dev/null)"
      echo "POLICY${i}_GOVS=$(cat "$p/scaling_available_governors" 2>/dev/null)"
      echo "POLICY${i}_FREQS=$(cat "$p/scaling_available_frequencies" 2>/dev/null)"
      echo "POLICY${i}_MAX=$(cat "$p/cpuinfo_max_freq" 2>/dev/null)"
      echo "POLICY${i}_MIN=$(cat "$p/cpuinfo_min_freq" 2>/dev/null)"
      i=$((i+1))
    done
    echo "N_POLICY=$i"

    # GPU
    for d in /sys/class/devfreq/*mali*; do
      [ -e "$d" ] || continue
      echo "GPU_DEV=$(basename "$d")"
      echo "GPU_GOVS=$(cat "$d/available_governors" 2>/dev/null)"
      echo "GPU_FREQS=$(cat "$d/available_frequencies" 2>/dev/null)"
      echo "GPU_MAX=$(cat "$d/max_freq" 2>/dev/null)"
      echo "GPU_MIN=$(cat "$d/min_freq" 2>/dev/null)"
      break
    done

    # cm_mgr (新平台替代 /proc/ppm)
    if [ -f /sys/kernel/cm_mgr/dbg_cm_mgr ]; then
      echo "CM_MGR=1"
    else
      echo "CM_MGR=0"
    fi

    # 温控 zone(仅 CPU/GPU 相关, 供分析/文档使用)
    local z t
    for z in /sys/class/thermal/thermal_zone*; do
      t=$(cat "$z/type" 2>/dev/null)
      case "$t" in
        cpu-*|gpu*|soc*|apu*)
          echo "THZ=$(basename "$z"):$t" ;;
      esac
    done
  } > "$out" 2>/dev/null

  if [ -s "$out" ]; then
    log_info "device.conf generated ($(grep -c . "$out") lines)"
    return 0
  fi
  log_err "device.conf generation failed"
  return 1
}

# source 守卫: 仅直接执行时进入命令分发
[ "$(basename "$0" 2>/dev/null)" = "detect.sh" ] || return 0 2>/dev/null
case "$1" in
  gen) gen_device_conf ;;
esac
