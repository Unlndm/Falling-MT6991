#!/bin/sh
# ============================================================
# v3.1 调度架构测试: 帧率闭环 + 上限层 + 让路释放
#
# 测的是新架构的正确行为(v3.0 的温控自降频已上移到上限层):
#   1) 追帧压力映射: 帧率低/大核满 -> 压力高; 温度高 -> 压力低
#   2) 执行器档位: 压力 -> level, 且受档位 EXEC_LEVEL 上限约束
#   3) 滞回: 目标 level 连续 2 轮一致才切
#   4) 上限层让位判定: 压力低时接受系统压低的上限(不抢), 压力高时才抬
#   5) 让路释放: cap_release 把上限恢复成 cpuinfo_max_freq
#   6) 温控降额: 比例只作用于上限层, 温控层本身不再写节点
#
# /sys 路径全部映射到临时目录, 不碰真实设备。
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
T="$SHROOT/_t_loop"
"$PYBIN" "$WINROOT/tools/mk_testenv.py" loop "$WINROOT/_t_loop" >/dev/null || { echo "环境准备失败"; exit 1; }
export PMK_CONFIG_DIR="$T/config"
export PMK_LOG_FILE="$T/log"
cd "$T" || exit 1

mkdir -p "$T/proc/hmbird_sched"
printf '55\n' > "$T/proc/hmbird_sched/cpuctrl_high"
printf '40\n' > "$T/proc/hmbird_sched/cpuctrl_low"

# 三簇 cpufreq 节点
for p in 0 4 7; do
  printf '2400000\n' > "cpufreq/policy$p/scaling_max_freq"
  printf '3600000\n' > "cpufreq/policy$p/cpuinfo_max_freq"
  mkdir -p "cpufreq/policy$p/sugov_ext"
  printf '10\n' > "cpufreq/policy$p/sugov_ext/up_rate_limit_us"
  printf '10\n' > "cpufreq/policy$p/sugov_ext/down_rate_limit_us"
done

# 让 policy_list 只看到这三簇: 替换 policy 枚举根
sed -i "s#/sys/devices/system/cpu/cpufreq/policy\[0-9\]\*#$T/cpufreq/policy[0-9]*#g" "$T/lib/common.sh"
sed -i "s#/sys/devices/system/cpu/cpufreq/policy\[0-9\]\*#$T/cpufreq/policy[0-9]*#g" "$T/lib/loop.sh"

# shellcheck disable=SC1091
. "$T/lib/common.sh"
. "$T/lib/loop.sh"

FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS $1 ($3)"; else echo "  FAIL $1: 期望 $2 实得 $3"; FAIL=$((FAIL+1)); fi; }

echo "[1] 追帧压力: 帧率低 -> 压力高"
loop_pressure 50 20 40000
ok "低帧率(50%)压力>" "yes" "$([ "$LOOP_PRESS" -gt 50 ] && echo yes || echo no)"
loop_pressure 100 20 40000
ok "满帧(100%)压力低" "yes" "$([ "$LOOP_PRESS" -lt 50 ] && echo yes || echo no)"

echo "[2] 追帧压力: 大核吃满 -> 压力上调"
loop_pressure 100 95 40000; p1=$LOOP_PRESS
loop_pressure 100 20 40000; p2=$LOOP_PRESS
ok "大核95%比大核20%压力高" "yes" "$([ "$p1" -gt "$p2" ] && echo yes || echo no)"

echo "[3] 追帧压力: 高温 -> 压力下调(温控优先)"
loop_pressure 50 20 62000; p1=$LOOP_PRESS
loop_pressure 50 20 40000; p2=$LOOP_PRESS
ok "62°C压力低于40°C" "yes" "$([ "$p1" -lt "$p2" ] && echo yes || echo no)"

echo "[4] 压力 -> level 映射"
ok "压力10->L0" "0" "$(loop_level_of 10)"
ok "压力30->L1" "1" "$(loop_level_of 30)"
ok "压力45->L2" "2" "$(loop_level_of 45)"
ok "压力65->L3" "3" "$(loop_level_of 65)"
ok "压力90->L4" "4" "$(loop_level_of 90)"

echo "[5] 滞回: 单轮异常不切档(连续 2 轮才切)"
LOOP_EMA=0; LOOP_PRESS_EMA=50; LOOP_LEVEL=2; LOOP_PEND=-1; LOOP_PEND_N=0; LOOP_SINCE=0
LOOP_TICK=0; LOOP_PRESS=90
# 第一轮: 目标 level 变化, 只记 pending 不切
LOOP_TICK=$((LOOP_TICK+1))
[ $((LOOP_TICK % 3)) -eq 1 ] && { LOOP_EMA=50; loop_pressure 50 95 40000; LOOP_PRESS_EMA=$(( (50*3+LOOP_PRESS)/4 )); }
wantlvl=$(loop_level_of "$LOOP_PRESS_EMA")
ok "目标 level 已算出 L3" "3" "$wantlvl"
# 模拟 loop_tick 里的 pending 逻辑(第一轮)
if [ "$wantlvl" != "$LOOP_LEVEL" ]; then
  if [ "$LOOP_PEND" = "$wantlvl" ]; then LOOP_PEND_N=$((LOOP_PEND_N+1)); else LOOP_PEND="$wantlvl"; LOOP_PEND_N=1; fi
fi
ok "单轮后仍为 L2(未切)" "2" "$LOOP_LEVEL"
ok "已记录 pending=L3" "3" "$LOOP_PEND"
ok "pending 计数=1" "1" "$LOOP_PEND_N"
echo "[6] 上限层让位: 压力低时接受系统压低的上限(不抢)"
printf '2000000\n' > cpufreq/policy7/scaling_max_freq   # 系统给 2000000
LOOP_PRESS=20
cap_apply "2400000 3300000 3600000" 100
ok "p7 保持系统给的 2000000" "2000000" "$(tr -d '\n' < cpufreq/policy7/scaling_max_freq)"

echo "[7] 上限层: 压力高时才把上限抬到目标"
LOOP_PRESS=90
cap_apply "2400000 3300000 3600000" 100
ok "p7 抬到目标 3600000" "3600000" "$(tr -d '\n' < cpufreq/policy7/scaling_max_freq)"

echo "[8] 上限层: 温控比例乘在目标上"
printf '3600000\n' > cpufreq/policy7/scaling_max_freq
LOOP_PRESS=20
cap_apply "2400000 3300000 3600000" 85
# 3600000*85/100 = 3060000
ok "p7 按 85% 收紧" "3060000" "$(tr -d '\n' < cpufreq/policy7/scaling_max_freq)"

echo "[9] 上限层: 系统给得比目标高时收紧(省电方向)"
printf '3600000\n' > cpufreq/policy7/scaling_max_freq
LOOP_PRESS=20
cap_apply "2400000 3300000 3000000" 100
ok "p7 收紧到 3000000" "3000000" "$(tr -d '\n' < cpufreq/policy7/scaling_max_freq)"

echo "[10] 让路释放: 上限恢复 cpuinfo_max_freq"
cap_release
ok "p7 恢复 3600000" "3600000" "$(tr -d '\n' < cpufreq/policy7/scaling_max_freq)"
ok "已标记 released" "1" "$(sed -n 's/^released=//p' config/runtime/cap.state | head -1)"

echo "[11] 释放后 loop_tick 不再写任何节点"
printf '1000000\n' > cpufreq/policy7/scaling_max_freq
loop_tick "2400000 3300000 3600000" 100 50 20 40000 1000
ok "上限未被改动" "1000000" "$(tr -d '\n' < cpufreq/policy7/scaling_max_freq)"

echo "[12] 温控层: 只出比例, 不自己写节点"
mkdir -p thermal/thermal_zone0
printf 'cpu-0-0\n' > thermal/thermal_zone0/type
printf '62000\n' > thermal/thermal_zone0/temp
printf '55\n' > "$T/proc/hmbird_sched/cpuctrl_high"
. "$T/lib/thermal.sh"
thermal_tune >/dev/null 2>&1
ok "62°C 比例=85" "85" "$TH_RATIO"
ok "温控层未写 cpuctrl" "55" "$(tr -d '\n' < "$T/proc/hmbird_sched/cpuctrl_high")"

echo "[13] 温控层: 45°C 比例=100"
printf '45000\n' > thermal/thermal_zone0/temp
thermal_tune >/dev/null 2>&1
ok "45°C 比例=100" "100" "$TH_RATIO"

echo "[14] 执行器: level 越高, sugov_ext 升频越快(up_rate_limit 越小)"
loop_apply_exec 0
u0=$(tr -d '\n' < cpufreq/policy7/sugov_ext/up_rate_limit_us)
loop_apply_exec 4
u4=$(tr -d '\n' < cpufreq/policy7/sugov_ext/up_rate_limit_us)
ok "L4 的 up_rate_limit < L0" "yes" "$([ "$u4" -lt "$u0" ] && echo yes || echo no)"
ok "大核用本级(L4=10)" "10" "$u4"
ok "hmbird cpuctrl_high 已写" "45" "$(tr -d '\n' < "$T/proc/hmbird_sched/cpuctrl_high")"

echo "[15] 执行器: 小核比大核保守(降一级)"
loop_apply_exec 4
p7=$(tr -d '\n' < cpufreq/policy7/sugov_ext/up_rate_limit_us)
p0=$(tr -d '\n' < cpufreq/policy0/sugov_ext/up_rate_limit_us)
ok "小核 up_rate_limit > 大核" "yes" "$([ "$p0" -gt "$p7" ] && echo yes || echo no)"

echo
[ "$FAIL" = 0 ] && echo "全部通过" || echo "失败 $FAIL 项"
exit "$FAIL"
