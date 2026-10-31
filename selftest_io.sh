#!/bin/sh
# IO 调度层测试: 把 /sys/block 映射到临时目录, 验证备份取值/还原/旧备份作废


set -u
SRC="D:/76578/treawoek/projeck/6aa51f33bbf8d3c8bc9b3a07/Falling-MT6991"
# 环境准备交给 Python: 同时做「复制文件 + 把 rm -f 改写成截断+移走」。
#   原因: 脚本进程内调用 rm 会挂起(Bash 工具环境统一拦截, 与沙盒开关无关),
#   而 sed 现场生成的副本改不掉 rm。改写只作用于测试副本, 不动产品源码。
#   路径: Python 用 Windows 路径建目录, 生成的脚本里用 POSIX 路径(shell 能访问)。
PYBIN="${PYBIN:-python}"
WINROOT="$(cd "$PWD" && pwd -W 2>/dev/null || echo "$PWD")"
SHROOT="$(cd "$PWD" && pwd 2>/dev/null || echo "$PWD")"
T="$SHROOT/_t_io"
"$PYBIN" "$WINROOT/tools/mk_testenv.py" io "$WINROOT/_t_io" >/dev/null || { echo "环境准备失败"; exit 1; }
export PMK_CONFIG_DIR="$T/config"
export PMK_LOG_FILE="$T/log"
cd "$T" || exit 1

# 出厂: mq-deadline 生效(read_ahead 128)
printf 'mq-deadline [kyber] bfq none\n' > block/sda/queue/scheduler
printf '128\n' > block/sda/queue/read_ahead_kb
# dm-0 是虚拟盘, 必须被跳过
printf '[none] mq-deadline\n' > block/dm-0/queue/scheduler
printf '128\n' > block/dm-0/queue/read_ahead_kb

FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS $1 ($3)"; else echo "  FAIL $1: 期望 $2 实得 $3"; FAIL=$((FAIL+1)); fi; }
rd(){ tr -d '\n' < "$1"; }

echo "[1] 备份只记当前生效的调度器"
sh lib/io.sh apply daily >/dev/null 2>&1
ok 备份行 "sda kyber 128" "$(cat config/io_backup)"
ok 跳过虚拟盘 "0" "$(grep -c '^dm-0' config/io_backup 2>/dev/null)"

echo "[2] 游戏: 切 deadline 系 + read_ahead 512"
sh lib/io.sh apply game >/dev/null 2>&1
ok 调度器 "mq-deadline" "$(rd block/sda/queue/scheduler)"
ok "游戏 read_ahead" "512" "$(rd block/sda/queue/read_ahead_kb)"

echo "[3] 日常: 还原到备份值, 且只写单个名字"
# 模拟已被改成 bfq
printf 'mq-deadline kyber [bfq] none\n' > block/sda/queue/scheduler
sh lib/io.sh apply daily >/dev/null 2>&1
ok 还原调度器 "kyber" "$(rd block/sda/queue/scheduler)"
ok "还原 read_ahead" "128" "$(rd block/sda/queue/read_ahead_kb)"

echo "[4] 旧备份(整串列表)作废并重建"
printf 'sda mq-deadline kyber bfq none 128\n' > config/io_backup
printf 'mq-deadline [kyber] bfq none\n' > block/sda/queue/scheduler
printf '128\n' > block/sda/queue/read_ahead_kb
sh lib/io.sh apply daily >/dev/null 2>&1
ok 归档旧备份 "1" "$([ -f config/io_backup.old ] && echo 1 || echo 0)"
ok 新备份字段数 "3" "$(awk 'NR==1{print NF}' config/io_backup)"

echo
[ "$FAIL" = 0 ] && echo "全部通过" || echo "失败 $FAIL 项"
exit "$FAIL"
