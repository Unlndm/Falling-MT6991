#!/system/bin/sh
# ============================================================
# Falling-MT6991 智能温控 (Thermalcore)
# 温度分档动态降频, 保帧率底线; 由 daemon 每轮调用
# 分档: <55°C 100% | 55-70°C 85% | 70-80°C 70% | >80°C 55%
#
# v2.2 性能改造(行为不变):
#   旧版每轮 30~50 次 fork —— 每个 thermal_zone 两次 cat, 每个 policy 一次
#   grep|cut + cat + tr|awk。5s 一轮就是每秒 6~10 次 fork(实机 fork ~13ms),
#   等于常驻 8%~13% 的 CPU 花在"读自己的温度"上。
#   现在全部改成内建 read + 字符串索引:
#     - thermal_zone 路径缓存 60s, 温度用 read 读
#     - 降频基线表读进内存, 用 |policyN=freq| 字符串查
#     - 可用频率表用 read 整行 + 词分割取 ≤目标 的最大值
#   实测每轮 fork 从 30+ 降到 0(只有真正写频率时才 sysfs 写一次)。
# ============================================================
# shellcheck disable=SC1091
MODDIR="${MODDIR:-$(dirname "$(dirname "$0")")}"
[ -f "$MODDIR/lib/common.sh" ] && . "$MODDIR/lib/common.sh"

# ---- 温度采样 ----
# zone 列表运行期基本不变(偶发热插拔), 缓存起来; 每 12 轮(≈60s)重扫一次
TH_ZONES=""
TH_ZONE_TICK=0
TH_ZONE_REFRESH=12
TH_TEMP=0
TH_RATIO=100

thermal_scan_zones() {
  local z t
  TH_ZONES=""
  for z in /sys/class/thermal/thermal_zone*; do
    [ -f "$z/type" ] || continue
    t=""
    read -r t < "$z/type" 2>/dev/null
    # 口径与 lib/metrics.sh 的 met_scan_zones 保持一致:
    # 实机(MT6991)同时存在 soc-top*/soc-bot*(连字符) 与 soc_max(下划线),
    # GPU 是 gpu0/gpu1, 三者都要算进来, 否则 UI 显示的温度和温控实际用的温度不是一回事。
    case "$t" in
      cpu-*|cpu_*|soc-*|soc_*|gpu*|mtkts*) TH_ZONES="$TH_ZONES $z" ;;
    esac
  done
}

# 最高 CPU/SoC/GPU 温度(mC); 结果同时写 TH_TEMP, 内循环直接用变量避免命令替换
thermal_max_temp() {
  [ -n "$TH_ZONES" ] || thermal_scan_zones
  local z v m=0
  for z in $TH_ZONES; do
    v=""
    read -r v < "$z/temp" 2>/dev/null
    case "$v" in ''|*[!0-9-]*) continue ;; esac
    [ "$v" -gt "$m" ] 2>/dev/null && m=$v
  done
  TH_TEMP=$m
  printf '%s' "$m"
}

# 温度降频比例(%); 结果同时写 TH_RATIO
thermal_ratio_set() {
  local t="$1"
  if [ "$t" -lt 55000 ] 2>/dev/null; then TH_RATIO=100
  elif [ "$t" -lt 70000 ] 2>/dev/null; then TH_RATIO=85
  elif [ "$t" -lt 80000 ] 2>/dev/null; then TH_RATIO=70
  else TH_RATIO=55; fi
  printf '%s' "$TH_RATIO"
}
thermal_ratio() { thermal_ratio_set "$1"; }

# v3.1 架构: 温控不再自己写 scaling_max_freq。
#   原因: 同一个节点有两个写入者(温控 + 上限层)必然互相覆盖 ——
#   温控写完 85%, 上限层按档位目标写回 100%, 两者反复抢,
#   结果既不是温控的也不是档位的, 还刷日志。
#   现在温控只做一件事: 算出降额比例 TH_RATIO, 交给上限层(cap_apply)统一落盘。
#   TH_RATIO=100 时上限层写档位目标, <100 时按比例收紧。
#
# 保留 thermal_tune 这个名字与入口(守护进程每轮调), 但内部只更新比例。
# 旧的三列基线表(thermal.base)逻辑已上移到上限层(cap.base),
# 那里用同样的"当前值 == 本模块上次写入值"判定, 雪崩防护不变。
thermal_tune() {
  # zone 缓存定期刷新(热插拔/新增 zone)
  TH_ZONE_TICK=$((TH_ZONE_TICK + 1))
  if [ -z "$TH_ZONES" ]; then
    thermal_scan_zones
  elif [ $((TH_ZONE_TICK % TH_ZONE_REFRESH)) -eq 0 ]; then
    thermal_scan_zones
  fi

  thermal_max_temp >/dev/null
  thermal_ratio_set "$TH_TEMP" >/dev/null
  [ "$TH_RATIO" = 100 ] && return 0
  log_debug "thermal: ${TH_TEMP}mC 降额比例 ${TH_RATIO}%"
  return 1
}

# 温度回落: 比例回到 100(上限层下一轮会恢复档位目标)
thermal_restore() {
  TH_RATIO=100
  log_info "thermal_tune: 温度回落, 降额比例恢复 100%"
  return 0
}

thermal_status() {
  thermal_max_temp >/dev/null
  thermal_ratio_set "$TH_TEMP" >/dev/null
  echo "enabled=1"
  echo "temp=$TH_TEMP"
  echo "ratio=$TH_RATIO"
}

# source 守卫
[ "$(basename "$0" 2>/dev/null)" = "thermal.sh" ] || return 0 2>/dev/null
case "$1" in
  tune)   thermal_tune ;;
  status) thermal_status ;;
esac
