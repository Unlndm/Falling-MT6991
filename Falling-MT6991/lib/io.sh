#!/system/bin/sh
# ============================================================
# Falling-MT6991 IO 调度优化 (对齐 Uperf/Neon)
# 游戏: IO 调度器切 deadline 系 + read_ahead 提到 512
# 日常: 还原备份值
# 备份: config/io_backup (首次应用记录, 每行 "盘 调度器 read_ahead")
#
# v2.2 修错:
#   旧备份用 `cat scheduler | tr -d '[]'` 取值, 节点内容形如
#   "mq-deadline [kyber] bfq none", 去掉方括号后整串列表都被当成"原值"存了下来。
#   回日常时把这串写回 scheduler 节点, 内核只认单个名字 -> 写入失败,
#   于是"还原"从来没真正生效过。现在只取 [] 里那个当前生效的名字。
#   老备份(字段数 != 3)按作废处理: 归档成 io_backup.old 后按当前值重新记录,
#   避免把错误基线继续传下去。
# ============================================================
# shellcheck disable=SC1091
MODDIR="${MODDIR:-$(dirname "$(dirname "$0")")}"
[ -f "$MODDIR/lib/common.sh" ] && . "$MODDIR/lib/common.sh"

IO_BACKUP="$PMK_CONFIG_DIR/io_backup"
IO_ACT=""    # 当前生效调度器

# "mq-deadline [kyber] bfq none" -> IO_ACT=kyber; 无 [] 标记时取第一个词
io_active_of() {
  local raw="$1"
  IO_ACT=""
  case "$raw" in
    *"["*"]"*)
      IO_ACT="${raw#*[}"
      IO_ACT="${IO_ACT%%]*}"
      ;;
    *) IO_ACT="${raw%% *}" ;;
  esac
  [ -n "$IO_ACT" ]
}

# 可用调度器列表(去掉方括号标记)
io_avail_of() {
  local raw="$1" a
  IO_AVAIL=""
  for a in $raw; do
    a="${a#\[}"
    a="${a%\]}"
    [ -n "$a" ] && IO_AVAIL="$IO_AVAIL $a"
  done
}

# 可用调度器中选首选(deadline 系优先) -> IO_PICK
io_pick_sched() {
  local avail="$1" p a
  IO_PICK=""
  for p in mq-deadline deadline none noop; do
    for a in $avail; do
      [ "$p" = "$a" ] && { IO_PICK="$p"; return 0; }
    done
  done
  return 1
}

io_backup() {
  [ -f "$IO_BACKUP" ] || : > "$IO_BACKUP" 2>/dev/null
  # 老备份(字段数不是 3)作废重建, 否则会把"整串调度器列表"这种错值继续传下去
  local legacy=0
  if [ -s "$IO_BACKUP" ]; then
    while read -r l1 l2 l3 l4; do
      [ -z "$l1" ] && continue
      if [ -z "$l2" ] || { [ -n "$l3" ] && [ -n "$l4" ]; }; then legacy=1; break; fi
    done < "$IO_BACKUP"
    if [ "$legacy" = 1 ]; then
      mv -f "$IO_BACKUP" "$IO_BACKUP.old" 2>/dev/null
      : > "$IO_BACKUP" 2>/dev/null
      log_info "io: 旧备份格式作废(io_backup.old), 按当前值重新记录"
    fi
  fi
  [ -s "$IO_BACKUP" ] && return 0

  local d b raw r
  for d in /sys/block/*; do
    [ -d "$d" ] || continue
    b=$(basename "$d")
    # 只处理物理盘, 跳过 loop/dm/ram/zram 等虚拟设备
    case "$b" in loop*|dm-*|ram*|zram*|fd*|sr*) continue ;; esac
    raw=""; read -r raw < "$d/queue/scheduler" 2>/dev/null
    io_active_of "$raw" || continue
    r=""; read -r r < "$d/queue/read_ahead_kb" 2>/dev/null
    echo "$b $IO_ACT $r" >> "$IO_BACKUP" 2>/dev/null
  done
  return 0
}

# apply <game|daily>
io_apply() {
  local mode="${1:-daily}"
  io_backup
  local d b raw r bk p s0 r0
  for d in /sys/block/*; do
    [ -d "$d" ] || continue
    b=$(basename "$d")
    case "$b" in loop*|dm-*|ram*|zram*|fd*|sr*) continue ;; esac
    [ -f "$d/queue/scheduler" ] || continue

    raw=""; read -r raw < "$d/queue/scheduler" 2>/dev/null
    [ -n "$raw" ] || continue

    if [ "$mode" = game ]; then
      io_avail_of "$raw"
      if io_pick_sched "$IO_AVAIL"; then
        [ "$IO_ACT" = "$IO_PICK" ] || write_file "$d/queue/scheduler" "$IO_PICK"
      fi
      r=""; read -r r < "$d/queue/read_ahead_kb" 2>/dev/null
      case "$r" in ''|*[!0-9]*) ;; *) [ "$r" -lt 512 ] && write_file "$d/queue/read_ahead_kb" 512 ;; esac
    else
      # 日常: 还原备份(只取本盘那行, 内建解析不 fork)
      s0=""; r0=""
      while read -r p s r; do
        [ "$p" = "$b" ] && { s0="$s"; r0="$r"; break; }
      done < "$IO_BACKUP" 2>/dev/null
      [ -n "$s0" ] || continue
      io_active_of "$raw"
      [ "$IO_ACT" = "$s0" ] || write_file "$d/queue/scheduler" "$s0"
      if [ -n "$r0" ]; then
        r=""; read -r r < "$d/queue/read_ahead_kb" 2>/dev/null
        [ "$r" = "$r0" ] || write_file "$d/queue/read_ahead_kb" "$r0"
      fi
    fi
  done
  log_info "io: $mode"
}

# source 守卫
[ "$(basename "$0" 2>/dev/null)" = "io.sh" ] || return 0 2>/dev/null
case "$1" in
  apply) shift; io_apply "$1" ;;
esac
