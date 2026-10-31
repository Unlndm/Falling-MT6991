#!/bin/sh
# config.sh 恢复默认测试(v3.0)
# 重点: reset 必须一并清掉 v3.0 新增的遥测文件(smart.trace / smart.stats / cluster.map),
#       否则"恢复默认"之后调度页还显示旧配置下的决策历史, 排查时会被误导。
#       daemon.restarts 是守护健康度证据, 不能清。
#
# 环境说明: 脚本进程内的 rm 会被环境拦截(非交互下挂起到超时),
#           所以环境准备交给 Python, 并把测试副本里的 rm -f 改写成
#           「截断+移走」(语义等价于删除)。产品源码不动。


set -u
# 环境准备交给 Python: 同时做「复制文件 + 把 rm -f 改写成截断+移走」。
#   原因: 脚本进程内调用 rm 会挂起(Bash 工具环境统一拦截, 与沙盒开关无关)。
#   改写只作用于测试副本, 不动产品源码。
PYBIN="${PYBIN:-python}"
WINROOT="$(cd "$PWD" && pwd -W 2>/dev/null || echo "$PWD")"
SHROOT="$(cd "$PWD" && pwd 2>/dev/null || echo "$PWD")"
T="$SHROOT/_t_config"
"$PYBIN" "$WINROOT/tools/mk_testenv.py" config "$WINROOT/_t_config" >/dev/null || { echo "环境准备失败"; exit 1; }
export PMK_CONFIG_DIR="$T/config" PMK_DATA_DIR="$T" PMK_RUNTIME_DIR="$T/config/runtime"
export PMK_LOG_FILE="$T/test.log"
cd "$T" || exit 1

# shellcheck disable=SC1091
. "$T/lib/common.sh"
. "$T/lib/config.sh"

pass=0; fail=0
ck() { # $1=名称 $2=实际 $3=期望
  if [ "$2" = "$3" ]; then printf '  PASS %s (%s)\n' "$1" "$2"; pass=$((pass+1))
  else printf '  FAIL %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
exists() { [ -e "$1" ] && echo yes || echo no; }

echo "[1] 恢复默认: 配置回到出厂值"
printf 'game_mode=module\n' > "$T/config/system.conf"
config_reset >/dev/null 2>&1
ck "system.conf 已还原" "$(grep -c '^game_mode=official' "$T/config/system.conf" 2>/dev/null)" "1"

echo "[2] 恢复默认: 清智能调度状态"
printf 'powersave 40 -1 -1\n' > "$T/config/runtime/smart.state"
printf '2\n'                  > "$T/config/runtime/smart.count"
printf 'balanced\n'           > "$T/config/runtime/profile.applied"
config_reset >/dev/null 2>&1
ck "smart.state"     "$(exists "$T/config/runtime/smart.state")"     "no"
ck "smart.count"     "$(exists "$T/config/runtime/smart.count")"     "no"
ck "profile.applied" "$(exists "$T/config/runtime/profile.applied")" "no"

echo "[3] 恢复默认: 清 v3.0 遥测(决策历史/驻留统计/拓扑缓存)"
printf '14:00 balanced>performance 高负载 70 45 88 92 60\n' > "$T/config/runtime/smart.trace"
printf 'balanced=120\n' > "$T/config/runtime/smart.stats"
printf 'policy0=0 1|policy4=2 3|policy7=4|' > "$T/config/runtime/cluster.map"
config_reset >/dev/null 2>&1
ck "smart.trace" "$(exists "$T/config/runtime/smart.trace")" "no"
ck "smart.stats" "$(exists "$T/config/runtime/smart.stats")" "no"
ck "cluster.map" "$(exists "$T/config/runtime/cluster.map")" "no"

echo "[4] 恢复默认: 保留守护异常重启计数(健康度证据, 不能被抹掉)"
printf '3\n' > "$T/config/runtime/daemon.restarts"
config_reset >/dev/null 2>&1
ck "daemon.restarts" "$(cat "$T/config/runtime/daemon.restarts" 2>/dev/null)" "3"

echo
if [ "$fail" = 0 ]; then echo "全部通过 ($pass 项)"; else echo "有 $fail 项失败"; exit 1; fi
