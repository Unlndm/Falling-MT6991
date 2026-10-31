#!/bin/sh
# 智能调度引擎逻辑测试(v3.0)
# 把 /sys /proc 前缀映射到临时目录, 用可控的 /proc/stat 计数器驱动分簇占用


set -u
SRC="$(cd "$(dirname "$0")" && pwd)/Falling-MT6991"
# 环境准备: 同时做「复制文件 + 把 rm -f 改写成截断+移走 + 路径前缀映射」。
#   - 本地(Windows/Git Bash): 脚本进程内调用 rm 会挂起(Bash 工具环境统一拦截,
#     与沙盒开关无关), 所以用 tools/mk_testenv.py 在 Python 里做(路径用 Windows 形式)。
#   - 真机(mksh): 没有 python, 走下面的纯 shell 分支(只复制 + sed 路径替换;
#     真机 rm 正常, 不需要改写)。两条分支的替换清单必须保持一致。
PYBIN="${PYBIN:-python}"
WINROOT="$(cd "$PWD" && pwd -W 2>/dev/null || echo "$PWD")"
SHROOT="$(cd "$PWD" && pwd 2>/dev/null || echo "$PWD")"
T="$SHROOT/_t_smart"

prep_shell() {
  mkdir -p "$T/lib" "$T/config/runtime" "$T/thermal" "$T/cpu/cpufreq" "$T/proc/hmbird_sched" || return 1
  local f
  for f in common.sh metrics.sh smart.sh loop.sh extreme.sh; do
    cp "$SRC/lib/$f" "$T/lib/$f" || return 1
  done
  sed "s#/sys/devices/system/cpu/cpufreq/policy[0-9]*#$T/cpufreq/policy[0-9]*#g" \
    "$T/lib/common.sh" > "$T/lib/common.sh.t" && mv "$T/lib/common.sh.t" "$T/lib/common.sh"
  sed -e "s#/sys/class/thermal#$T/thermal#g" \
      -e "s#/sys/devices/system/cpu/cpufreq#$T/cpu/cpufreq#g" \
      -e "s#/sys/kernel/fpsgo#$T/fpsgo#g" \
      -e "s#/proc/stat#$T/stat#g" \
      -e "s#/proc/pressure/cpu#$T/pressure/cpu#g" \
    "$T/lib/metrics.sh" > "$T/lib/metrics.sh.t" && mv "$T/lib/metrics.sh.t" "$T/lib/metrics.sh"
  sed -e "s#/proc/hmbird_sched#$T/proc/hmbird_sched#g" \
      -e "s#/sys/devices/system/cpu/cpufreq/policy[0-9]*#$T/cpu/cpufreq/policy[0-9]*#g" \
    "$T/lib/loop.sh" > "$T/lib/loop.sh.t" && mv "$T/lib/loop.sh.t" "$T/lib/loop.sh"
  return 0
}

if command -v "$PYBIN" >/dev/null 2>&1 && [ -f "$WINROOT/tools/mk_testenv.py" ]; then
  "$PYBIN" "$WINROOT/tools/mk_testenv.py" smart "$WINROOT/_t_smart" >/dev/null \
    || { echo "环境准备失败"; exit 1; }
else
  prep_shell || { echo "环境准备失败"; exit 1; }
fi
export PMK_CONFIG_DIR="$T/config"
export PMK_LOG_FILE="$T/log"
cd "$T" || exit 1

# ---- 温度区 ----
mkdir -p thermal/thermal_zone0 thermal/thermal_zone1
printf 'cpu-0-0\n'       > thermal/thermal_zone0/type
printf 'soc-thermal\n'   > thermal/thermal_zone1/type
printf '45000\n'         > thermal/thermal_zone0/temp
printf '44000\n'         > thermal/thermal_zone1/temp

# ---- 三簇拓扑: policy0=0-3, policy4=4-6, policy7=7 ----
mkdir -p cpu/cpufreq/policy0 cpu/cpufreq/policy4 cpu/cpufreq/policy7
printf '0 1 2 3\n' > cpu/cpufreq/policy0/affected_cpus
printf '4 5 6\n'   > cpu/cpufreq/policy4/affected_cpus
printf '7\n'       > cpu/cpufreq/policy7/affected_cpus
for i in 0 1 2 3 4 5 6 7; do mkdir -p "cpu/cpu$i"; done

# ---- 档位文件(应用策略校验要读) ----
mkdir -p config/profiles
for p in balanced performance powersave "powersave+" game_medium; do : > "config/profiles/$p.conf"; done

# ---- 可控 /proc/stat ----
# 每轮每核推进 250 tick, 各簇按设定占用率分配忙时; 累计值 = tick * 250 便于精确控制
tick=0
P0=20; P1=20; P2=20; P3=20    # policy0
P4=20; P5=20; P6=20           # policy4
P7=20                          # policy7

set_pct() {  # 小核 中核 大核
  P0=$1; P1=$1; P2=$1; P3=$1
  P4=$2; P5=$2; P6=$2
  P7=$3
}

# 累计计数器必须单调递增: 若按 tick 现算 (tick*win*(100-p)) , 把占用率调高时
# 累计 idle 会倒退, 差值算出来 >100%, 会得出"满载"的假信号。
CT0=0; CT1=0; CT2=0; CT3=0; CT4=0; CT5=0; CT6=0; CT7=0
CI0=0; CI1=0; CI2=0; CI3=0; CI4=0; CI5=0; CI6=0; CI7=0

write_stat() {
  local c p t i tot_t=0 tot_i=0 body=""
  for c in 0 1 2 3 4 5 6 7; do
    eval "p=\$P$c; t=\$CT$c; i=\$CI$c"
    t=$((t + 250))
    i=$((i + 250 * (100 - p) / 100))
    eval "CT$c=$t; CI$c=$i"
    tot_t=$((tot_t + t))
    tot_i=$((tot_i + i))
    body="$body
cpu$c $((t - i)) 0 0 $i 0 0 0 0 0 0"
  done
  printf 'cpu  %s 0 0 %s 0 0 0 0 0 0%s\nintr 1 0\nctxt 9\n' \
    "$((tot_t - tot_i))" "$tot_i" "$body" > stat
}
set_temp(){ printf '%s\n' "$1" > thermal/thermal_zone0/temp; }
# 直接 source 库函数在进程内调用: 每次起一个 sh 进程光冷启动就 1~2s,
# 二十多次决策会把测试拖到十几分钟, 也会掩盖真正的逻辑问题。
export MODDIR="$T"          # 让 lib/smart.sh 找到 $T/lib/common.sh
. "$T/lib/smart.sh" 2>/dev/null

# 采样一次基线, 再写目标占用, 再决策 -> 得到指定占用率
seed(){ set_pct 20 20 20; write_stat; met_cpu; }
busy_at(){ set_pct "$1" "$2" "$3"; write_stat; }

dec(){ smart_decide "$1" "$2" "$3" "$4" "${5:-}" "${6:-0}" >/dev/null 2>&1; }
st(){ sed -n "s/^$1=//p" config/runtime/smart.state 2>/dev/null; }
pof(){ sed -n 's/^profile=//p' config/runtime/smart.state 2>/dev/null; }

FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS $1 ($3)"; else echo "  FAIL $1: 期望 $2 实得 $3"; FAIL=$((FAIL+1)); fi; }

echo "[1] 息屏 -> 极限省电"
dec "" 0 "" 1000; ok 档位 powersave+ "$(pof)"
ok 原因 息屏 "$(st reason)"

echo "[2] 亮屏 45°C 低占用 -> balanced(初始基线)"
printf 'balanced\n' > config/runtime/profile.applied
set_temp 45000; seed; busy_at 30 30 30
dec "" 1 "" 1001; ok 档位 balanced "$(pof)"

echo "[3] 65°C -> 强制降档(不等驻留)"
printf 'performance\n' > config/runtime/profile.applied
set_temp 65000; seed; busy_at 60 60 60
dec "" 1 "" 1002; ok 档位 balanced "$(pof)"
ok 原因 "温度 65°C 强制降档" "$(st reason)"

echo "[4] 温度回落 + 高占用 -> performance"
printf 'balanced\n' > config/runtime/profile.applied
set_temp 43000; seed; busy_at 95 95 95
dec "" 1 "" 1100; ok 档位 performance "$(pof)"
ok 分数>=62 "1" "$([ "$(st score)" -ge 62 ] && echo 1 || echo 0)"

echo "[5] 应用策略直通(温度正常)"
printf 'balanced\n' > config/runtime/profile.applied
set_temp 44000; seed; busy_at 6 6 6
dec com.foo 1 powersave 1200; ok 档位 powersave "$(pof)"
ok 原因 "应用策略 com.foo" "$(st reason)"

echo "[6] 应用策略 + 56°C -> 不采用 hint, 走评分"
printf 'performance\n' > config/runtime/profile.applied
set_temp 56000; seed; busy_at 40 40 40
dec com.foo 1 performance 1300; ok 档位 balanced "$(pof)"

echo "[7] 滞回: performance 在 49°C 不掉档"
printf 'performance\n' > config/runtime/profile.applied
set_temp 49000; seed; busy_at 70 70 70
dec "" 1 "" 1400; ok 档位 performance "$(pof)"

echo "[8] 最小驻留 20s"
printf 'balanced\n' > config/runtime/profile.applied
set_temp 43000; seed; busy_at 95 95 95
printf '0 0 2000\n' > config/runtime/smart.count
dec "" 1 "" 2005; ok 5s内不换档 balanced "$(pof)"
# 两次决策之间要有新的采样窗口, 否则 dt=0 拿不到占用率(真机 5s 一轮自然推进)
busy_at 95 95 95
dec "" 1 "" 2100; ok 20s后可换档 performance "$(pof)"

echo "[9] 游戏(模块调度) -> game_medium 保底"
printf 'balanced\n' > config/runtime/profile.applied
printf '0 0 0\n' > config/runtime/smart.count
set_temp 45000; seed; busy_at 40 40 40
dec com.game.xxx 1 "" 3000 "" 1; ok 档位 game_medium "$(pof)"
ok 原因 "游戏(模块调度)" "$(st reason)"

echo "[10] 游戏 + 56°C -> 取消保底, 走评分降档"
printf 'game_medium\n' > config/runtime/profile.applied
printf '0 0 0\n' > config/runtime/smart.count
set_temp 56000; seed; busy_at 40 40 40
dec com.game.xxx 1 "" 3100 "" 1; ok 降档 balanced "$(pof)"
ok 原因 "温度偏高, 降档" "$(st reason)"

echo "[11] 应用策略档位不存在 -> 丢弃, 不写坏档位"
printf 'balanced\n' > config/runtime/profile.applied
printf '0 0 0\n' > config/runtime/smart.count
set_temp 44000; seed; busy_at 6 6 6
dec com.foo 1 nosuchprofile 3200; ok 忽略坏档位 powersave "$(pof)"
ok 未落盘坏名字 "0" "$(grep -c nosuchprofile config/runtime/smart.state 2>/dev/null)"

echo "[12] 整机占用 100% -> 升性能"
printf 'balanced\n' > config/runtime/profile.applied
printf '0 0 0\n' > config/runtime/smart.count
set_temp 44000; seed; busy_at 100 100 100
dec "" 1 "" 3400; ok 占用率 100 "$(st busy)"; ok 升档 performance "$(pof)"

echo "[13] 大核吃满但整机只有 60% -> 额外加权(只剩整机信号时不会升)"
printf 'balanced\n' > config/runtime/profile.applied
printf '0 0 0\n' > config/runtime/smart.count
set_temp 44000; seed; busy_at 55 55 95
dec "" 1 "" 3500
ok 大核占用 95 "$(st prime)"
ok 大核吃满升档 performance "$(pof)"

echo "[14] 决策遥测: 换档写 trace + 累计驻留"
printf 'balanced\n' > config/runtime/profile.applied
printf '0 0 0\n' > config/runtime/smart.count
set_temp 44000; seed; busy_at 100 100 100
dec "" 1 "" 3600 >/dev/null
ok trace有记录 "1" "$([ -s config/runtime/smart.trace ] && echo 1 || echo 0)"
ok trace含原因 "有" "$(grep -q '大核吃满, 升档' config/runtime/smart.trace 2>/dev/null && echo 有 || echo 无)"
ok stats已累计 "1" "$(grep -qc '^balanced=' config/runtime/smart.stats 2>/dev/null && echo 1 || echo 0)"
ok stats秒数 "1" "$([ "$(sed -n 's/^balanced=//p' config/runtime/smart.stats)" -gt 0 ] && echo 1 || echo 0)"

echo "[15] 分簇映射: 三簇按 affected_cpus 归并"
# 分隔符是逗号不是竖线: mksh/ksh 把 ${var%%|*} 的 | 当成模式备选分隔符,
# 竖线做分隔符会让循环切不开 -> 死循环(实机踩过, 守护进程直接卡死)。
ok 簇映射 "policy0=0 1 2 3,policy4=4 5 6,policy7=7," "$(cat config/runtime/cluster.map 2>/dev/null)"

# ---- 调度倾向(v3.0): 只给综合评分加偏置, 不锁档位 ----
# 守护每 20 秒才重读一次 system.conf(与 game_mode 同节奏), 所以测试里的 now
# 必须每次间隔 >= 20 秒, 否则读到的还是上一次的缓存值。
echo "[16] 倾向 perf: 同样负载下更容易升性能"
printf 'tendency=perf\n' > config/system.conf
printf 'balanced\n' > config/runtime/profile.applied
printf '0 0 0\n' > config/runtime/smart.count
set_temp 44000; seed; busy_at 60 60 60
dec "" 1 "" 4000
ok 倾向已生效 perf "$(st tendency)"
ok 升性能 performance "$(pof)"

echo "[17] 倾向 save: 同样负载下更容易落省电"
printf 'tendency=save\n' > config/system.conf
printf 'balanced\n' > config/runtime/profile.applied
printf '0 0 0\n' > config/runtime/smart.count
set_temp 50000; seed; busy_at 30 30 30
dec "" 1 "" 4030
ok 倾向已生效 save "$(st tendency)"
ok 落省电 powersave "$(pof)"
# 对照: 同样场景下均衡倾向不该落省电(40-12=28 > 23 阈值)
printf 'tendency=balance\n' > config/system.conf
printf 'balanced\n' > config/runtime/profile.applied
printf '0 0 0\n' > config/runtime/smart.count
set_temp 50000; seed; busy_at 30 30 30
dec "" 1 "" 4060
ok 均衡不落省电 balanced "$(pof)"

echo "[18] 倾向写坏值 -> 回退均衡"
printf 'tendency=bogus\n' > config/system.conf
printf 'balanced\n' > config/runtime/profile.applied
printf '0 0 0\n' > config/runtime/smart.count
set_temp 50000; seed; busy_at 30 30 30
dec "" 1 "" 4090
ok 坏值回退 balance "$(st tendency)"
ok 行为同均衡 balanced "$(pof)"

echo "[19] 硬规则不受倾向影响"
# 高温强制降档: 即使倾向=性能也必须降
printf 'tendency=perf\n' > config/system.conf
printf 'performance\n' > config/runtime/profile.applied
printf '0 0 0\n' > config/runtime/smart.count
set_temp 65000; seed; busy_at 60 60 60
dec "" 1 "" 4120; ok 高温仍强制降档 balanced "$(pof)"
# 息屏: 倾向=性能也必须走极限省电
dec "" 0 "" 4150; ok 息屏仍极限省电 powersave+ "$(pof)"
# 应用策略直通: 倾向=省电也不能覆盖用户指定档位
printf 'tendency=save\n' > config/system.conf
set_temp 44000; seed; busy_at 6 6 6
dec com.foo 1 performance 4180; ok 应用策略直通 performance "$(pof)"

# ---- CPU 争用(PSI v3.6): 二级判据 + 绝对需求下限 ----
# met_psi 读的是绝对路径 /proc/pressure/cpu, 测试环境没有这个节点,
# 所以这里走「本轮信号已就绪」路径直接注入: MET_DONE=1 + PMK_MET_READY=1
# 之后 smart_decide 里的 met_collect 会直接返回, 不再覆盖注入值
# (这正是守护进程主进程与 smart_decide 子进程共享同一份信号的机制)。
inject_met() {  # 温度 整机忙时 大核忙时 争用
  MET_TEMP="$1"; MET_BUSY="$2"; MET_CL0="$2"; MET_CL1="$2"; MET_CL2="$3"
  MET_NCL=3; MET_FPS=-1; MET_PSI="$4"; MET_DONE=1; PMK_MET_READY=1
}

echo "[20] CPU 争用(PSI): 有需求下限时才加分"
printf 'tendency=balance\n' > config/system.conf
printf 'balanced\n' > config/runtime/profile.applied
printf '0 0 0\n' > config/runtime/smart.count
inject_met 44000 60 50 25
dec "" 1 "" 5000
ok 争用读数 25 "$(st psi)"
ok 争用足且需求足时升性能 performance "$(pof)"
ok 原因 "CPU 争用(PSI), 升档" "$(st reason)"

echo "[21] CPU 争用(PSI): 轻载不抬频(需求下限挡住)"
printf 'balanced\n' > config/runtime/profile.applied
printf '0 0 0\n' > config/runtime/smart.count
inject_met 44000 20 20 35
dec "" 1 "" 5100
ok 争用读数 35 "$(st psi)"
ok 轻载保持 balanced balanced "$(pof)"

echo "[22] CPU 争用(PSI): 节点缺失(-1) 整个信号跳过"
printf 'balanced\n' > config/runtime/profile.applied
printf '0 0 0\n' > config/runtime/smart.count
inject_met 44000 60 50 -1
dec "" 1 "" 5200
ok 争用缺失 -1 "$(st psi)"
ok 无争用信号仍按忙时评分 balanced "$(pof)"

echo
[ "$FAIL" = 0 ] && echo "全部通过" || echo "失败 $FAIL 项"
exit "$FAIL"
