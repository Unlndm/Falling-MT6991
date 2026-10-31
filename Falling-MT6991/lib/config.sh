#!/system/bin/sh
# ============================================================
# Falling-MT6991 配置管理
# 导出/导入/恢复默认。配置 = config/ 下全部设置(排除运行时/实机检测文件)
# 默认配置: config/defaults/ (随包分发, 恢复默认时复制覆盖)
# ============================================================
# shellcheck disable=SC1091
MODDIR="${MODDIR:-$(dirname "$(dirname "$0")")}"
[ -f "$MODDIR/lib/common.sh" ] && . "$MODDIR/lib/common.sh"

CFG_BACKUP="/sdcard/Download/falling_config_backup.tar.gz"

# 运行时/实机检测文件, 不参与备份
cfg_skip() {
  case "$(basename "$1")" in
    runtime|device.conf|defaults|*.backup|orig_*|cpufreq_perm_backup|thermal_backup|sched_backup|io_backup|io_backup.old|.rollback|.runtime*|*.migrated) return 0 ;;
    *) return 1 ;;
  esac
}

# 导出全部配置 -> tar.gz
config_export() {
  local dst="${1:-$CFG_BACKUP}"
  local tmp
  tmp=$(mktemp -d /data/local/tmp/pmkcfg.XXXXXX 2>/dev/null) || { log_err "config export: mktemp fail"; return 1; }
  local f b
  for f in "$PMK_CONFIG_DIR"/* "$PMK_CONFIG_DIR"/.[!.]*; do
    [ -e "$f" ] || continue
    cfg_skip "$f" && continue
    b=$(basename "$f")
    [ -d "$f" ] && cp -r "$f" "$tmp/$b" 2>/dev/null || cp "$f" "$tmp/$b" 2>/dev/null
  done
  tar -czf "$dst" -C "$tmp" . 2>/dev/null
  local rc=$?
  rm -rf "$tmp" 2>/dev/null
  [ $rc = 0 ] && [ -s "$dst" ] && { log_info "config export -> $dst"; return 0; }
  log_err "config export failed"
  return 1
}

# 导入配置(覆盖当前设置, 保留 device.conf/运行时)
config_import() {
  local src="${1:-$CFG_BACKUP}"
  [ -f "$src" ] || { log_err "config import: $src 不存在"; return 1; }
  local tmp
  tmp=$(mktemp -d /data/local/tmp/pmkcfg.XXXXXX 2>/dev/null) || return 1
  tar -xzf "$src" -C "$tmp" 2>/dev/null || { rm -rf "$tmp" 2>/dev/null; log_err "config import: 解包失败"; return 1; }
  local f b
  for f in "$tmp"/* "$tmp"/.[!.]*; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    rm -rf "$PMK_CONFIG_DIR/$b" 2>/dev/null
    [ -d "$f" ] && cp -r "$f" "$PMK_CONFIG_DIR/" 2>/dev/null || cp "$f" "$PMK_CONFIG_DIR/" 2>/dev/null
  done
  rm -rf "$tmp" 2>/dev/null
  log_info "config imported from $src"
  return 0
}

# 恢复默认配置(config/defaults -> config/)
config_reset() {
  local d="$PMK_CONFIG_DIR/defaults"
  [ -d "$d" ] || { log_err "config reset: 默认配置缺失"; return 1; }
  local f b
  for f in "$d"/* "$d"/.[!.]*; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    rm -rf "$PMK_CONFIG_DIR/$b" 2>/dev/null
    [ -d "$f" ] && cp -r "$f" "$PMK_CONFIG_DIR/" 2>/dev/null || cp "$f" "$PMK_CONFIG_DIR/" 2>/dev/null
  done
  # 清智能调度状态(下次守护按现场温度/负载重新评分)
  rm -f "$PMK_RUNTIME_DIR/smart.state" "$PMK_RUNTIME_DIR/smart.count" \
        "$PMK_RUNTIME_DIR/profile.applied" 2>/dev/null
  # v3.0 遥测: 决策历史与驻留统计是"旧配置下"的记录, 配置已重置就必须一起清,
  # 否则调度页显示的还是改配置前的换档原因, 反而误导排查。
  # cluster.map 是 CPU 拓扑缓存, 一并清掉让下轮重新探测。
  # daemon.restarts 故意不清 —— 那是守护健康度证据, 不该被"恢复默认"抹掉。
  rm -f "$PMK_RUNTIME_DIR/smart.trace" "$PMK_RUNTIME_DIR/smart.stats" \
        "$PMK_RUNTIME_DIR/cluster.map" 2>/dev/null
  log_info "config reset to defaults"
  return 0
}

# source 守卫: 仅直接执行时进入命令分发
[ "$(basename "$0" 2>/dev/null)" = "config.sh" ] || return 0 2>/dev/null
case "$1" in
  export) shift; config_export "$1" ;;
  import) shift; config_import "$1" ;;
  reset)  config_reset ;;
esac
