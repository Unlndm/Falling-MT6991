#!/system/bin/sh
# ============================================================
# Falling-MT6991 全局通知
# 由 WebUI config/notify_enabled 控制 (1=开 0=关)
# 通过 su 2000 cmd notification 发系统通知(实机验证 aurorack 同法)
# ============================================================
# shellcheck disable=SC1091
MODDIR="${MODDIR:-$(dirname "$(dirname "$0")")}"
[ -f "$MODDIR/lib/common.sh" ] && . "$MODDIR/lib/common.sh"

notify_enabled() {
  [ "$(sys_opt notify)" = "1" ]
}

# send_notification <tag> <标题> <内容>
send_notification() {
  local tag="$1" title="$2" text="$3"
  notify_enabled || return 0
  # 引号转义, 经 su 2000 发通知(与 aurorack 二进制同通道)
  title=$(printf '%s' "$title" | sed 's/"/\\"/g')
  text=$(printf '%s' "$text" | sed 's/"/\\"/g')
  tag=$(printf '%s' "$tag" | tr -cd 'A-Za-z0-9._-')
  su 2000 -c "cmd notification post -t \"$title\" \"$tag\" \"$text\"" 2>/dev/null \
    && log_info "notify: $title - $text"
}

# 测试通知
notify_test() {
  send_notification "falling-test" "Falling-MT6991" "通知通道正常"
}

# source 守卫: 仅直接执行时进入命令分发
[ "$(basename "$0" 2>/dev/null)" = "notify.sh" ] || return 0 2>/dev/null
case "$1" in
  test) notify_test ;;
  post) shift; send_notification "$1" "$2" "$3" ;;
esac
