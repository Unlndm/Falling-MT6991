#!/system/bin/sh
# ============================================================
# Falling-MT6991 触控采样率调度(自研, 替代闭源 aurorack)
# 配置: config/触控.md (日常/游戏/游戏包名)
# 依赖: /odm/bin/touchHidlTest (厂商官方工具, 实机验证可用)
# 由 falling_daemon 每 5s 轮询前台应用驱动; 配置改动无需重启
# ============================================================
# shellcheck disable=SC1091
MODDIR="${MODDIR:-$(dirname "$(dirname "$0")")}"
[ -f "$MODDIR/lib/common.sh" ] && . "$MODDIR/lib/common.sh"
[ -f "$MODDIR/lib/notify.sh" ] && . "$MODDIR/lib/notify.sh"

PMK_TOUCH_CONF="$PMK_CONFIG_DIR/触控.md"
# 专属采样率并入 apps.conf (格式: 包名@touch=采样率码)
PMK_APP_CONF="$PMK_CONFIG_DIR/apps.conf"

# 触控状态(上次应用的档位), 供 daemon 判定变更; 运行时状态放 runtime/
PMK_TOUCH_STATE_FILE="$PMK_RUNTIME_DIR/touch.state"

touch_enabled() { cfg_get touch; [ "$_CFG_VAL" = "1" ]; }

# Magisk/KSU 的 PATH 通常不含 /odm/bin, 把相对命令换成绝对路径
touch_bin() {
  if [ -x /odm/bin/touchHidlTest ]; then
    echo /odm/bin/touchHidlTest
  elif [ -x /vendor/bin/touchHidlTest ]; then
    echo /vendor/bin/touchHidlTest
  else
    echo touchHidlTest
  fi
}
touch_abs_cmd() {
  local cmd="$1" bin
  bin=$(touch_bin)
  case "$cmd" in
    touchHidlTest\ *|/odm/bin/touchHidlTest\ *|/vendor/bin/touchHidlTest\ *)
      echo "$bin ${cmd#* }" ;;
    *) echo "$cmd" ;;
  esac
}

touch_conf_loaded=0
touch_daily_cmd=""
touch_game_cmd=""
touch_pkgs=""
touch_conf_raw=""   # 上次加载时的原文, 用于零 fork 变更检测
TPC_CODE=""         # touch_policy_code 的输出(避免命令替换 fork)

# 加载触控配置; 返回 0=配置有效
touch_load() {
  touch_conf_loaded=0
  touch_daily_cmd=""
  touch_game_cmd=""
  touch_pkgs=""
  [ -f "$PMK_TOUCH_CONF" ] || return 1
  local line k v
  while IFS= read -r line; do
    line="${line%%#*}"
    # 装载只在配置变化时发生, 这里保留 sed/tr(可读性优先, 不在热路径)
    line="$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    k="${line%%=*}"
    v="${line#*=}"
    case "$k" in
      日常)    touch_daily_cmd="$v" ;;
      游戏)    touch_game_cmd="$v" ;;
      游戏包名) touch_pkgs="$v" ;;
    esac
  done < "$PMK_TOUCH_CONF"
  [ -n "$touch_daily_cmd" ] || return 1
  touch_conf_loaded=1
  file_slurp "$PMK_TOUCH_CONF" && touch_conf_raw="$_FILE_BUF"
  return 0
}

# 配置是否变化: 内建 read 读全文比对(旧版 md5sum|cut 每轮 3 次 fork)
touch_config_changed() {
  runtime_dir
  file_slurp "$PMK_TOUCH_CONF" || return 0
  [ "$_FILE_BUF" != "$touch_conf_raw" ]
}


# 包名是否在游戏列表(零 fork: IFS 分词, 不再 echo|tr)
# 注意: 不能用管道子 shell(exit 只退子 shell, 返回恒 1)
touch_is_game() {
  [ -z "$touch_pkgs" ] && return 1
  local pkg="$1" p oldifs
  oldifs="$IFS"
  IFS=,
  for p in $touch_pkgs; do
    if [ "$p" = "$pkg" ]; then IFS="$oldifs"; return 0; fi
  done
  IFS="$oldifs"
  return 1
}

# 专属采样率: 包名在 apps.conf 中 @touch= 采样率码; 无则空
# 结果显示在 TPC_CODE(避免 $(...) 子进程); 老调用点仍可 echo 取值
touch_policy_code() {
  local pkg="$1" line
  TPC_CODE=""
  [ -n "$pkg" ] && [ -f "$PMK_APP_CONF" ] || { printf '%s' ""; return 0; }
  while IFS= read -r line; do
    case "$line" in
      "$pkg@touch="*) TPC_CODE="${line#*=}"; break ;;
    esac
  done < "$PMK_APP_CONF" 2>/dev/null
  printf '%s' "$TPC_CODE"
}

# 应用档位: game|daily; 仅在变化时执行
touch_apply() {
  [ "$touch_conf_loaded" = 1 ] || touch_load   # CLI 独立调用时自动装载
  [ "$touch_conf_loaded" = 1 ] || return 1
  local want="$1" cmd=""
  case "$want" in
    game)  cmd="$touch_game_cmd" ;;
    daily) cmd="$touch_daily_cmd" ;;
    *) return 1 ;;
  esac
  [ -n "$cmd" ] || return 1

  local last=""
  read -r last < "$PMK_TOUCH_STATE_FILE" 2>/dev/null
  [ "$last" = "$want" ] && return 0

  # 配置存完整命令; Magisk/KSU PATH 通常不含 /odm/bin, 换成绝对路径
  cmd=$(touch_abs_cmd "$cmd")
  # shellcheck disable=SC2086
  $cmd 2>/dev/null
  local rc=$?
  [ $rc = 0 ] || { log_err "touch apply $want failed (rc=$rc): $cmd"; return 1; }

  runtime_dir
  echo "$want" > "$PMK_TOUCH_STATE_FILE" 2>/dev/null
  log_info "touch: $want applied ($cmd)"
  send_notification "falling-touch" "触控采样率" \
    "$([ "$want" = game ] && echo 游戏档 || echo 日常档)"
  return 0
}

# 专属采样率码应用(覆盖全局档); 命令 = 日常命令前缀 + 采样率码
touch_apply_code() {
  [ "$touch_conf_loaded" = 1 ] || touch_load
  [ "$touch_conf_loaded" = 1 ] || return 1
  local code="$1" pkg="$2" key="code:$code" last="" cmd
  [ -n "$code" ] || return 1
  read -r last < "$PMK_TOUCH_STATE_FILE" 2>/dev/null
  [ "$last" = "$key" ] && return 0

  # 前缀 = 日常命令去掉最后一个 token (touchHidlTest -c wo 0 182 1 -> touchHidlTest -c wo 0 182)
  cmd=$(touch_abs_cmd "${touch_daily_cmd% *} $code")
  # shellcheck disable=SC2086
  $cmd 2>/dev/null
  local rc=$?
  [ $rc = 0 ] || { log_err "touch code $code failed (rc=$rc): $cmd"; return 1; }

  runtime_dir
  echo "$key" > "$PMK_TOUCH_STATE_FILE" 2>/dev/null
  log_info "touch: 专属采样率 $code applied ($cmd)"
  send_notification "falling-touch" "触控采样率" "专属 $code (${pkg:-?})"
  return 0
}

# daemon 每轮调用: 返回 0=已应用/无需动, 1=失败
touch_tick() {
  touch_enabled || return 1
  # 配置变更则重载
  if touch_config_changed; then
    touch_load
    touch_config_save_md5
  fi
  [ "$touch_conf_loaded" = 1 ] || return 1

  local pkg="$1" code want
  # 专属采样率优先(T PC_CODE 由函数直接写变量, 不走命令替换)
  touch_policy_code "$pkg" >/dev/null
  code="$TPC_CODE"
  if [ -n "$code" ]; then
    touch_apply_code "$code" "$pkg"
    return $?
  fi
  if touch_is_game "$pkg"; then
    want=game
  else
    want=daily
  fi
  touch_apply "$want"
}

# source 守卫: 仅直接执行时进入命令分发
[ "$(basename "$0" 2>/dev/null)" = "touch.sh" ] || return 0 2>/dev/null
case "$1" in
  load) touch_load ;;
  apply) shift; touch_apply "$1" ;;
  isgame) shift; touch_is_game "$1" && echo yes || echo no ;;
esac
