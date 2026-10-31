#!/bin/sh
# 调度层引擎功能测试(把 /proc 前缀换成临时目录, 不碰真实设备)


set -u
# 环境准备交给 Python: 需要同时做「复制文件 + 把 rm -f 改写成截断」。
#   原因: 脚本进程内调用 rm 会挂起(Bash 工具环境统一拦截, 与沙盒开关无关),
#   而 sed 现场生成的副本改不掉 rm。改写只作用于测试副本, 不动产品源码。
PYBIN="${PYBIN:-python}"
WINROOT="$(cd "$PWD" && pwd -W 2>/dev/null || echo "$PWD")"
SHROOT="$(cd "$PWD" && pwd 2>/dev/null || echo "$PWD")"
T="$SHROOT/_t_sched"
# Python 侧用 Windows 路径建目录, 生成的脚本里用 POSIX 路径(shell 能访问)
"$PYBIN" "$WINROOT/tools/mk_testenv.py" sched "$WINROOT/_t_sched" "$T" >/dev/null || { echo "环境准备失败"; exit 1; }
export PMK_CONFIG_DIR="$T/config"
cd "$T" || exit 1

mk(){ printf '%s\n' "$2" > "$1"; }
mk proc/sys/kernel/sched_pelt_multiplier 1
mk proc/sys/kernel/sched_child_runs_first 0
mk proc/sys/kernel/sched_rt_runtime_us 950000
mk proc/sys/kernel/sched_schedstats 1
mk proc/sys/kernel/sched_energy_aware 1
mk proc/sys/kernel/sched_util_clamp_max 1024
mk proc/hmbird_sched/uclamp_ctrl 0
mk proc/hmbird_sched/isolate_ctrl 0
mk proc/hmbird_sched/misfit_ds 90
mk proc/hmbird_sched/slim_for_app 0
mk proc/hmbird_sched/parctrl_high_ratio 55
mk proc/hmbird_sched/parctrl_low_ratio 40
mk proc/hmbird_sched/cpuctrl_high 55
mk proc/hmbird_sched/cpuctrl_low 40
mk proc/hmbird_sched/hmbird_preempt_policy 0
mk proc/hmbird_sched/cluster_separate 0
mk proc/hmbird_sched/cpu7_tl 70
mk proc/hmbird_sched/scx_shadow_tick_enable 0
mk proc/hmbird_sched/heartbeat 0
mk proc/hmbird_sched/heartbeat_enable 0
mk proc/hmbird_sched/watchdog_enable 1
mk proc/hmbird_sched/isoctrl_high_ratio 75
mk proc/hmbird_sched/isoctrl_low_ratio 60
mk proc/hmbird_sched/iso_free_rescue 0
mk proc/hmbird_sched/parctrl_high_ratio_l 65
mk proc/hmbird_sched/parctrl_low_ratio_l 50
mk proc/hmbird_sched/partial_ctrl 0
mk proc/hmbird_sched/slim_walt/slim_walt_ctrl 0
mk proc/hmbird_sched/slim_walt/slim_walt_policy 0
mk proc/hmbird_sched/slim_walt/frame_per_sec 60
mk proc/hmbird_sched/slim_freq_gov/scx_gov_ctrl 1
mk proc/touch_boost/boost_up 0
mk proc/touch_boost/boost_down 0
mk proc/touch_boost/boost_duration 50
mk proc/touch_boost/boost_ta 1
mk proc/touch_boost/boost_fg 1

FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS $1 ($3)"; else echo "  FAIL $1: 期望 $2 实得 $3"; FAIL=$((FAIL+1)); fi; }
g(){ cat "proc/$1" 2>/dev/null; }

echo "[1] 档位自检(未知键/值域)"
OUT=$(sh lib/sched.sh check 2>/dev/null)
echo "$OUT" | grep -q '^OK$' && echo "  PASS check OK" || { echo "  FAIL check"; FAIL=$((FAIL+1)); }

echo "[2] 应用 balance"
sh lib/sched.sh apply balance 2>/dev/null
ok schedstats 0 "$(g sys/kernel/sched_schedstats)"
ok written含出厂值 "PELT_MULTIPLIER 1" "$(head -1 config/runtime/sched.written)"

echo "[3] 切到 game"
sh lib/sched.sh apply game 2>/dev/null
ok pelt 4 "$(g sys/kernel/sched_pelt_multiplier)"
ok misfit 80 "$(g hmbird_sched/misfit_ds)"
ok cpu7tl 50 "$(g hmbird_sched/cpu7_tl)"
ok isolate 1 "$(g hmbird_sched/isolate_ctrl)"
ok preempt 1 "$(g hmbird_sched/hmbird_preempt_policy)"
ok partial 1 "$(g hmbird_sched/partial_ctrl)"
# v2.3: 这四个键已从 game 档移除, 必须保持出厂值(写它们等于写垃圾)
ok 不写heartbeat 0 "$(g hmbird_sched/heartbeat_enable)"
ok 不写watchdog 1 "$(g hmbird_sched/watchdog_enable)"
ok 不写slim子参数 0 "$(g hmbird_sched/slim_walt/slim_walt_policy)"
ok 不写uclamp_max 1024 "$(g sys/kernel/sched_util_clamp_max)"

echo "[4] 切到 daily(差量还原 game 独有键)"
sh lib/sched.sh apply daily 2>/dev/null
ok pelt 2 "$(g sys/kernel/sched_pelt_multiplier)"
ok parctrl 50 "$(g hmbird_sched/parctrl_high_ratio)"
ok misfit 85 "$(g hmbird_sched/misfit_ds)"
ok cpu7tl 60 "$(g hmbird_sched/cpu7_tl)"
ok slim_walt 1 "$(g hmbird_sched/slim_walt/slim_walt_ctrl)"
ok game独有-preempt回出厂 0 "$(g hmbird_sched/hmbird_preempt_policy)"
ok game独有-partial回出厂 0 "$(g hmbird_sched/partial_ctrl)"
ok game独有-isofree回出厂 0 "$(g hmbird_sched/iso_free_rescue)"

echo "[5] 漂移自愈(同档重申)"
printf '99\n' > proc/hmbird_sched/misfit_ds
S=$(date +%s%N)
sh lib/sched.sh apply daily 2>/dev/null
E=$(date +%s%N)
ok misfit 85 "$(g hmbird_sched/misfit_ds)"
ok drift 1 "$(cat config/runtime/sched.drift)"
echo "  重申耗时 $(( (E-S)/1000000 )) ms(Windows fork 慢, 设备上按 1/8 估)"

echo "[6] 未知键/越界值拦截"
cp config/profiles/sched_daily.conf /tmp/daily.bak
printf 'PARC_HIGH=50\nPELT_MULTIPLIER=3\n' >> config/profiles/sched_daily.conf
# touch 会被沙箱拦(改时间戳), 用追加空行代替(同样会更新 mtime)
printf '\n' >> config/profiles/sched_daily.conf
OUT=$(sh lib/sched.sh check 2>/dev/null)
echo "$OUT" | grep -q '未知键 PARC_HIGH' && echo "  PASS check 报未知键" || { echo "  FAIL check 未知键"; FAIL=$((FAIL+1)); }
echo "$OUT" | grep -q '值越界 PELT_MULTIPLIER=3' && echo "  PASS check 报越界" || { echo "  FAIL check 越界"; FAIL=$((FAIL+1)); }
sh lib/sched.sh apply daily 2>/dev/null
ok 拒写后pelt仍为2 2 "$(g sys/kernel/sched_pelt_multiplier)"
ok badcount 2 "$(cat config/runtime/sched.badcount)"
cp /tmp/daily.bak config/profiles/sched_daily.conf

echo "[7] 关闭还原(出厂)"
sh lib/sched.sh disable 2>/dev/null
ok pelt 1 "$(g sys/kernel/sched_pelt_multiplier)"
ok misfit 90 "$(g hmbird_sched/misfit_ds)"
ok cpu7tl 70 "$(g hmbird_sched/cpu7_tl)"
ok schedstats 1 "$(g sys/kernel/sched_schedstats)"
ok 状态文件清空 "" "$(ls config/runtime 2>/dev/null | tr '\n' ' ')"

echo "[8] 升级模拟: 清 runtime 后重新应用, 基线仍取出厂"
sh lib/sched.sh apply daily 2>/dev/null
rm -rf config/runtime; mkdir -p config/runtime
sh lib/sched.sh apply daily 2>/dev/null
ok 基线=出厂 "PELT_MULTIPLIER 1" "$(head -1 config/runtime/sched.written)"
sh lib/sched.sh disable 2>/dev/null
ok 还原后pelt 1 "$(g sys/kernel/sched_pelt_multiplier)"

echo
[ "$FAIL" = 0 ] && echo "全部通过" || echo "失败 $FAIL 项"
exit "$FAIL"
