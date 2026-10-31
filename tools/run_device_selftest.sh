#!/bin/sh
# ============================================================
# Falling-MT6991 真机自检(用设备自己的 shell 跑)
#
# 为什么必须用设备 shell:
#   Android 的 /system/bin/sh 是 mksh/ksh 系, 不是 bash。mksh 把
#   ${var%%|*} 里的 | 当成"模式备选分隔符" —— 于是 ${m%%|*} 返回空、
#   ${m#*|} 原样不动, 用竖线做分隔符的解析循环会既不推进也不退出,
#   守护进程直接死循环卡死。bash 下完全正常, 所以本地测试永远测不出来。
#   本脚本把整套测试搬到设备上跑, 用真机的 shell 验真。
#
# 用法:
#   sh tools/run_device_selftest.sh            # 自动选第一台真机
#   sh tools/run_device_selftest.sh <序列号>    # 指定设备
#
# 只读: 不写任何系统节点, 只在 /data/local/tmp 下建临时目录。
# ============================================================
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SRC="$ROOT/Falling-MT6991"

# Git Bash/MSYS 会把 /data/... 这种远程路径当成 Windows 路径转换掉, adb 直接报错。
# 办法: 禁用转换(MSYS_NO_PATHCONV), 同时把本地源路径先转成 Windows 形式,
# 否则本地那半边反而会坏。非 Git Bash 环境(纯 Linux)没有 cygpath, 不用管。
if command -v cygpath >/dev/null 2>&1; then
  export MSYS_NO_PATHCONV=1
  ROOT=$(cygpath -w "$ROOT")
  SRC="$ROOT\\Falling-MT6991"
fi

SER=${1:-}
if [ -z "$SER" ]; then
  # 跳过 emulator: 挑第一台非 emulator 的设备
  SER=$(adb devices | awk 'NR>1 && $2=="device" && $1 !~ /^emulator-/ {print $1; exit}')
fi
if [ -z "$SER" ]; then
  echo "找不到已连接的设备(adb devices 里没有非 emulator 的 device)"
  exit 1
fi
echo "设备: $SER"

WORK=/data/local/tmp/pmk_selftest
RUN="sh $WORK/selftest_smart.sh"

cleanup() {
  adb -s "$SER" shell "su -c 'rm -rf $WORK'" >/dev/null 2>&1
}
trap cleanup EXIT

echo "== 准备 =="
# 注意: su 建的目录归 root, adb push 是 shell 身份, 直接推进去会 Permission denied。
# 所以一律先推到 /data/local/tmp/ 根下(shell 可写), 再用 su 搬进工作目录。
STAGE=/data/local/tmp
adb -s "$SER" shell "su -c 'rm -rf $WORK; mkdir -p $WORK/Falling-MT6991/lib'" >/dev/null 2>&1
for f in common.sh metrics.sh smart.sh loop.sh extreme.sh; do
  adb -s "$SER" push "$SRC/lib/$f" "$STAGE/pmk_$f" >/dev/null 2>&1 || {
    echo "推送 lib/$f 失败"; exit 1; }
  adb -s "$SER" shell "su -c 'mv $STAGE/pmk_$f $WORK/Falling-MT6991/lib/$f'" >/dev/null 2>&1
done
adb -s "$SER" push "$ROOT/selftest_smart.sh" "$STAGE/pmk_st.sh" >/dev/null 2>&1 || {
  echo "推送 selftest_smart.sh 失败"; exit 1; }
adb -s "$SER" shell "su -c 'mv $STAGE/pmk_st.sh $WORK/selftest_smart.sh; chmod 755 $WORK/selftest_smart.sh $WORK/Falling-MT6991/lib/*.sh'" >/dev/null 2>&1

echo "== 设备 shell 身份 =="
adb -s "$SER" shell "ls -l /system/bin/sh" 2>&1
echo

echo "== 跑测试(设备端 sh, 不是 bash) =="
OUT=$(adb -s "$SER" shell "su -c 'cd $WORK && timeout 180 sh ./selftest_smart.sh 2>&1'" 2>&1)
echo "$OUT"
echo

# 结果判定: 脚本最后会打印"全部通过"或"失败 N 项"
if echo "$OUT" | grep -q "全部通过"; then
  echo "结果: 真机自检通过"
  exit 0
fi
echo "结果: 真机自检未通过(详见上方)"
exit 1
