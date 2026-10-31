#!/bin/sh
# ============================================================
# v3.4.0 极致省电限制层测试
#
# 测的是限制层必须满足的性质:
#   1) 生效态: 只看 runtime/extreme.state, 游戏期间强制失效
#   2) 钳制方向: 一律取更严的一侧(min), 绝不把档位放宽
#   3) 频率取值: 必须落在实机频率表内(内核才肯写)
#   4) GPU: 上限压到表内低频点, boost 全关, 调速器 powersave
#   5) cm_mgr: 关性能模式; DRAM OPP 不被覆写(方向未确证, 不猜)
#   6) 执行器: 限制层生效时用固定节奏(升得极慢/掉得极快),
#      不按 level 分簇递减
#   7) 退出还原: 执行器节点照出厂值写回, 且备份只在首次生效时做一次
#   8) 调度策略: 限制层生效时一律用最省电的那套
#
# /sys 路径全部映射到临时目录, 不碰真实设备。
# ============================================================

set -u
SRC="D:/76578/treawoek/projeck/6aa51f33bbf8d3c8bc9b3a07/Falling-MT6991"
PYBIN="${PYBIN:-python}"
WINROOT="$(cd "$PWD" && pwd -W 2>/dev/null || echo "$PWD")"
SHROOT="$(cd "$PWD" && pwd 2>/dev/null || echo "$PWD")"
T="$SHROOT/_t_extreme"
"$PYBIN" "$WINROOT/tools/mk_testenv.py" extreme "$WINROOT/_t_extreme" >/dev/null || { echo "环境准备失败"; exit 1; }
export PMK_CONFIG_DIR="$T/config"
export PMK_LOG_FILE="$T/log"
cd "$T" || exit 1

mkdir -p "$T/proc/hmbird_sched"
printf '55\n' > "$T/proc/hmbird_sched/cpuctrl_high"
printf '40\n' > "$T/proc/hmbird_sched/cpuctrl_low"

# 三簇 cpufreq 节点(频率表按实机 probe_idle.txt 的值)
for p in 0 4 7; do
  printf '2400000\n' > "cpufreq/policy$p/scaling_max_freq"
  printf '3600000\n' > "cpufreq/policy$p/cpuinfo_max_freq"
  mkdir -p "cpufreq/policy$p/sugov_ext"
  printf '10\n' > "cpufreq/policy$p/sugov_ext/up_rate_limit_us"
  printf '10\n' > "cpufreq/policy$p/sugov_ext/down_rate_limit_us"
done

# 让 policy_list 只看到这三簇
sed -i "s#/sys/devices/system/cpu/cpufreq/policy\[0-9\]\*#$T/cpufreq/policy[0-9]*#g" "$T/lib/common.sh"
sed -i "s#/sys/devices/system/cpu/cpufreq/policy\[0-9\]\*#$T/cpufreq/policy[0-9]*#g" "$T/lib/loop.sh"

# device.conf: 实机频率表(测钳制取值必须落表内)
cat > "$T/config/device.conf" <<'EOF'
DEVICE=test
N_POLICY=3
POLICY0_CPUS=0 1 2 3
POLICY0_FREQS=2400000 2300000 2200000 2100000 2000000 1900000 1800000 1700000 1600000 1500000 1400000 1300000 1200000 1100000 1000000 900000 800000 700000 600000 500000 400000 339000
POLICY1_CPUS=4 5 6
POLICY1_FREQS=3300000 3200000 3100000 3000000 2900000 2800000 2700000 2600000 2500000 2400000 2300000 2200000 2100000 2000000 1900000 1800000 1700000 1600000 1500000 1400000 1300000 1200000 1100000 1000000 900000 800000 700000 622000
POLICY2_CPUS=7
POLICY2_FREQS=3730000 3600000 3500000 3400000 3300000 3200000 3100000 3000000 2900000 2800000 2700000 2600000 2500000 2400000 2300000 2200000 2100000 2000000 1900000 1800000 1700000 1600000 1500000 1400000 1300000 1200000 1100000 1000000 900000 798000
GPU_DEV=48000000.mali
GPU_FREQS=1508000000 1482000000 1456000000 1430000000 1404000000 1378000000 1352000000 1326000000 1300000000 1274000000 1248000000 1222000000 1196000000 1170000000 1144000000 1118000000 1092000000 1066000000 1040000000 1014000000 988000000 962000000 936000000 910000000 884000000 858000000 832000000 806000000 780000000 754000000 728000000 702000000 676000000 650000000 624000000 598000000 572000000 546000000
EOF

# shellcheck disable=SC1091
. "$T/lib/common.sh"
. "$T/lib/extreme.sh"
. "$T/lib/loop.sh"
# apply.sh 提供 sched_effective(限制层 -> 调度策略的映射)
# 它会 source governor.sh(本机不存在真实节点, 只是取函数), 所以用
# "只取函数不执行"的方式加载: apply.sh 末尾有 source 守卫, 不会误触发。
. "$T/lib/apply.sh" 2>/dev/null

FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS $1 ($3)"; else echo "  FAIL $1: 期望 $2 实得 $3"; FAIL=$((FAIL+1)); fi; }
yesno(){ if [ "$2" = "$3" ]; then echo "  PASS $1 ($3)"; else echo "  FAIL $1: 期望 $2 实得 $3"; FAIL=$((FAIL+1)); fi; }

echo "[1] 生效态: 默认关闭"
extreme_state_read
ok "默认 extreme=0" "0" "$EXTREME_ON"

echo "[2] 生效态: 状态文件写 1 后读出 1"
extreme_state_write 1 >/dev/null
extreme_state_read
ok "读到 extreme=1" "1" "$EXTREME_ON"

echo "[3] 游戏豁免: 游戏进行中 -> 强制关闭"
extreme_publish 1 1 >/dev/null
extreme_state_read
ok "游戏时 extreme=0" "0" "$EXTREME_ON"

echo "[4] 游戏豁免: 非游戏 -> 开关说了算"
extreme_publish 0 1 >/dev/null
extreme_state_read
ok "非游戏时 extreme=1" "1" "$EXTREME_ON"
extreme_publish 0 0 >/dev/null
extreme_state_read
ok "开关关闭时 extreme=0" "0" "$EXTREME_ON"

echo "[5] 钳制方向: 取更严的一侧(不放宽)"
# 档位给的是高频上限, 极致层的目标更低 -> 应取低的
extreme_min 2400000 1000000
ok "min(档位2400000, 极致1000000)" "1000000" "$EXTREME_MIN"
# 档位给的是低频上限, 极致层的目标更高 -> 应取低的那个
extreme_min 800000 1000000
ok "min(档位800000, 极致1000000)" "800000" "$EXTREME_MIN"
# 档位没给(0) -> 用极致层的值
extreme_min 0 1000000
ok "档位未设置时用极致值" "1000000" "$EXTREME_MIN"

echo "[6] 频率取值: 必须落在实机频率表内"
extreme_snap_freq "2400000 1300000 1000000 339000" 1000000
ok "取 <=1000000 的最大频点" "1000000" "$EXTREME_F"
extreme_snap_freq "2400000 1300000 1000000 339000" 1500000
ok "取 <=1500000 的最大频点" "1300000" "$EXTREME_F"
extreme_snap_freq "2400000 1300000" 500000
ok "表内无合适频点时失败" "1" "$?"

echo "[7] 档位钳制: CPU 上限取更严的一侧且落表内"
extreme_state_write 1 >/dev/null
PMK_CPU_GOVERNOR="sugov_ext sugov_ext sugov_ext"
PMK_CPU_MAXFREQ="2400000 3300000 3730000"
PMK_GPU_GOVERNOR="dummy"
PMK_GPU_UPBOUND="1508000"
PMK_CM_PERF_EN="1"
PMK_CM_PERF_OPP="0"
PMK_CM_DRAM_CEIL="-1"
PMK_C2PS_UM="N"
policy_list >/dev/null
extreme_clamp_profile >/dev/null
ok "p0 上限(目标1000000)" "1000000" "$(field "$PMK_CPU_MAXFREQ" 1)"
ok "p4 上限(目标1200000)" "1200000" "$(field "$PMK_CPU_MAXFREQ" 2)"
ok "p7 上限(目标1400000)" "1400000" "$(field "$PMK_CPU_MAXFREQ" 3)"

echo "[8] 钳制后: GPU 压低 / boost 关 / 调速器 powersave"
ok "GPU 上限" "546000" "$PMK_GPU_UPBOUND"
ok "GPU boost 开关" "0" "$PMK_GPU_BOOST_EN"
ok "GPU 调速器" "powersave" "$PMK_GPU_GOVERNOR"

echo "[9] 钳制后: cm_mgr 关性能模式, DRAM OPP 不被覆写"
ok "cm_perf 关闭" "0" "$PMK_CM_PERF_EN"
ok "DRAM OPP 沿用档位值" "-1" "$PMK_CM_DRAM_CEIL"
ok "c2ps 开" "Y" "$PMK_C2PS_UM"

echo "[10] 钳制后: 不会把档位放宽"
PMK_CPU_MAXFREQ="800000 900000 900000"
extreme_clamp_profile >/dev/null
ok "档位更低时保持档位值" "800000" "$(field "$PMK_CPU_MAXFREQ" 1)"
ok "p4 保持档位值" "900000" "$(field "$PMK_CPU_MAXFREQ" 2)"
ok "p7 保持档位值" "900000" "$(field "$PMK_CPU_MAXFREQ" 3)"

echo "[11] 执行器: 限制层生效时用固定节奏"
extreme_state_write 1 >/dev/null
loop_apply_exec 0
ok "up_rate 用限制层值" "50000" "$(tr -d '\n' < cpufreq/policy7/sugov_ext/up_rate_limit_us)"
ok "down_rate 用限制层值" "10" "$(tr -d '\n' < cpufreq/policy7/sugov_ext/down_rate_limit_us)"
ok "cpuctrl_high 用限制层值" "95" "$(tr -d '\n' < "$T/proc/hmbird_sched/cpuctrl_high")"
ok "cpuctrl_low 用限制层值" "85" "$(tr -d '\n' < "$T/proc/hmbird_sched/cpuctrl_low")"

echo "[12] 执行器: 限制层关闭后回到 level 语义"
extreme_state_write 0 >/dev/null
loop_apply_exec 0
ok "L0 的 up_rate=3000" "3000" "$(tr -d '\n' < cpufreq/policy7/sugov_ext/up_rate_limit_us)"
ok "L0 的 cpuctrl_high=80" "80" "$(tr -d '\n' < "$T/proc/hmbird_sched/cpuctrl_high")"

echo "[13] 备份/还原: 出厂值只备份一次, 退出时照原样写回"
# 重置节点到出厂值, 再走一次完整的"生效->退出"流程
printf '10\n' > cpufreq/policy7/sugov_ext/up_rate_limit_us
printf '10\n' > cpufreq/policy0/sugov_ext/up_rate_limit_us
printf '55\n' > "$T/proc/hmbird_sched/cpuctrl_high"
printf '40\n' > "$T/proc/hmbird_sched/cpuctrl_low"
extreme_state_write 1 >/dev/null
loop_apply_exec 0
ok "生效后 up_rate 已钉住" "50000" "$(tr -d '\n' < cpufreq/policy7/sugov_ext/up_rate_limit_us)"
ok "已生成出厂值备份" "1" "$([ -s "$T/config/extreme_backup" ] && echo 1 || echo 0)"
loop_restore_extreme
ok "还原后 up_rate 回到出厂值" "10" "$(tr -d '\n' < cpufreq/policy7/sugov_ext/up_rate_limit_us)"
ok "还原后 cpuctrl_high 回到出厂值" "55" "$(tr -d '\n' < "$T/proc/hmbird_sched/cpuctrl_high")"
ok "还原后 cpuctrl_low 回到出厂值" "40" "$(tr -d '\n' < "$T/proc/hmbird_sched/cpuctrl_low")"

echo "[14] 备份: 第二次生效不覆盖已备份的出厂值"
# 手工把备份改成标记值, 再生效一次, 备份不应被覆盖
printf 'p2_up 99999\n' > "$T/config/extreme_backup"
extreme_state_write 1 >/dev/null
loop_apply_exec 0
ok "出厂值备份未被覆盖" "99999" "$(sed -n 's/^p2_up //p' "$T/config/extreme_backup" | head -1)"

echo "[15] 调度策略: 限制层生效时用最省电的一套"
extreme_state_write 1 >/dev/null
extreme_state_read
ok "performance 档 -> powersave 策略" "powersave" "$(sched_effective performance)"
ok "balanced 档 -> powersave 策略" "powersave" "$(sched_effective balanced)"
extreme_state_write 0 >/dev/null
extreme_state_read
ok "限制层关闭 -> 回到档位自身策略" "game" "$(sched_effective performance)"

echo
[ "$FAIL" = 0 ] && echo "全部通过" || echo "失败 $FAIL 项"
exit "$FAIL"
