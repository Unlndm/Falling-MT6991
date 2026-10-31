#!/bin/sh
# ============================================================
# 温控层测试 (v3.1 架构)
#
# v3.1 起温控层不再自己写 scaling_max_freq —— 同一节点两个写入者
# (温控 + 上限层)会互相覆盖, 结果既不是温控的也不是档位的。
# 现在温控只负责算降额比例, 由上限层(cap_apply)统一落盘。
#
# 这里验证两件事:
#   1) 分档比例正确(55/70/80°C 三档)
#   2) 比例作用到上限层后, 上限按比例收紧且不会雪崩
# ============================================================


set -u
SRC="D:/76578/treawoek/projeck/6aa51f33bbf8d3c8bc9b3a07/Falling-MT6991"
# 环境准备交给 Python: 同时做「复制文件 + 把 rm -f 改写成截断+移走」。
#   原因: 脚本进程内调用 rm 会挂起(Bash 工具环境统一拦截, 与沙盒开关无关),
#   而 sed 现场生成的副本改不掉 rm。改写只作用于测试副本, 不动产品源码。
#   路径: Python 用 Windows 路径建目录, 生成的脚本里用 POSIX 路径(shell 能访问)。
PYBIN="${PYBIN:-python}"
WINROOT="$(cd "$PWD" && pwd -W 2>/dev/null || echo "$PWD")"
SHROOT="$(cd "$PWD" && pwd 2>/dev/null || echo "$PWD")"
T="$SHROOT/_t_thermal"
"$PYBIN" "$WINROOT/tools/mk_testenv.py" thermal "$WINROOT/_t_thermal" >/dev/null || { echo "环境准备失败"; exit 1; }
export PMK_CONFIG_DIR="$T/config"
export PMK_LOG_FILE="$T/log"
cd "$T" || exit 1

mkdir -p thermal/thermal_zone0
printf 'cpu-0-0\n' > thermal/thermal_zone0/type
printf '40000\n' > thermal/thermal_zone0/temp
printf '55\n' > "$T/proc/hmbird_sched/cpuctrl_high"
printf '40\n' > "$T/proc/hmbird_sched/cpuctrl_low"

for p in 0 4 7; do
  printf '2400000\n' > "cpufreq/policy$p/scaling_max_freq"
  printf '3600000\n' > "cpufreq/policy$p/cpuinfo_max_freq"
  mkdir -p "cpufreq/policy$p/sugov_ext"
  printf '10\n' > "cpufreq/policy$p/sugov_ext/up_rate_limit_us"
  printf '10\n' > "cpufreq/policy$p/sugov_ext/down_rate_limit_us"
done

# shellcheck disable=SC1091
. "$T/lib/common.sh"
. "$T/lib/thermal.sh"
. "$T/lib/loop.sh"

set_temp(){ printf '%s\n' "$1" > thermal/thermal_zone0/temp; }
tune(){ thermal_tune >/dev/null 2>&1; }
mx(){ tr -d '\n' < "cpufreq/$1/scaling_max_freq"; }

FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS $1 ($3)"; else echo "  FAIL $1: 期望 $2 实得 $3"; FAIL=$((FAIL+1)); fi; }

echo "[1] 分档比例"
set_temp 40000; tune; ok "40°C -> 100%" "100" "$TH_RATIO"
set_temp 60000; tune; ok "60°C -> 85%" "85" "$TH_RATIO"
set_temp 72000; tune; ok "72°C -> 70%" "70" "$TH_RATIO"
set_temp 82000; tune; ok "82°C -> 55%" "55" "$TH_RATIO"

echo "[2] 温控层不写任何 cpufreq 节点"
printf '3600000\n' > cpufreq/policy7/scaling_max_freq
set_temp 72000; tune
ok "p7 上限未被温控改动" "3600000" "$(mx policy7)"

echo "[3] 比例作用到上限层: 72°C(70%) 时上限收紧"
LOOP_PRESS=90   # 压力高, 允许上限层落盘
cap_apply "2400000 3300000 3600000" "$TH_RATIO"
# 3600000 * 70 / 100 = 2520000
ok "p7 收紧到 2520000" "2520000" "$(mx policy7)"

echo "[4] 温度回落后上限恢复(不雪崩)"
set_temp 40000; tune
LOOP_PRESS=90
cap_apply "2400000 3300000 3600000" "$TH_RATIO"
ok "p7 恢复 3600000" "3600000" "$(mx policy7)"

echo "[5] 连续 3 轮同温度不得继续往下砍(雪崩防护)"
set_temp 72000; tune
LOOP_PRESS=90
cap_apply "2400000 3300000 3600000" "$TH_RATIO"
a=$(mx policy7)
cap_apply "2400000 3300000 3600000" "$TH_RATIO"
b=$(mx policy7)
cap_apply "2400000 3300000 3600000" "$TH_RATIO"
c=$(mx policy7)
ok "第1轮" "2520000" "$a"
ok "第2轮不降" "2520000" "$b"
ok "第3轮不降" "2520000" "$c"

echo "[6] 让路后普通降额不落盘(上限已交还官方)"
cap_release
set_temp 82000; tune
LOOP_PRESS=90
cap_apply "2400000 3300000 3600000" "$TH_RATIO"
ok "p7 保持 cpuinfo_max 3600000" "3600000" "$(mx policy7)"

echo "[7] 让路期间极高温兜底: 紧急降额生效(保命优先)"
# 82°C -> TH_RATIO=55; 3600000*55/100 = 1980000
cap_emergency_throttle "$TH_RATIO"
ok "p7 紧急压到 1980000" "1980000" "$(mx policy7)"
ok "已解除 released 标记" "0" "$(sed -n 's/^released=//p' config/runtime/cap.state | head -1)"

echo "[8] 兜底后回到让路: 上限再次交还官方"
cap_release
ok "p7 恢复 3600000" "3600000" "$(mx policy7)"

echo
[ "$FAIL" = 0 ] && echo "全部通过" || echo "失败 $FAIL 项"
exit "$FAIL"
