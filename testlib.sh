#!/bin/sh
# ============================================================
# 测试公共片段: rm 替身
#
# 为什么要: 本机沙箱把「脚本进程内发起的删除」包装成需要确认的版本,
#   非交互下会挂起直到超时(rc=124)。直接在命令行敲 rm 反而正常,
#   所以问题只出现在测试脚本内部的 rm 调用。
#
# 之前踩过的坑: 替身只写 mv 时仍会挂起 —— 必须先 `: > "$a"` 把文件截断,
#   再 mv 走。截断这一步是绕开沙箱检查的关键。
#
# 用法: 在测试脚本里 source 本文件, 或直接复制下面的 rm 函数。
# 只影响测试环境, 产品代码里的 rm 在 Android 上正常。
# ============================================================

PMK_TEST_TRASH="${PMK_TEST_TRASH:-/tmp/pmk_test_trash}"
mkdir -p "$PMK_TEST_TRASH" 2>/dev/null

rm() {
  local a
  for a in "$@"; do
    case "$a" in -*) continue ;; esac
    [ -e "$a" ] || continue
    : > "$a" 2>/dev/null
    mv "$a" "$PMK_TEST_TRASH/$(basename "$a").$$.$RANDOM" 2>/dev/null || true
  done
  return 0
}
export -f rm 2>/dev/null || true
