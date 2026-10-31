#!/system/bin/sh
# ============================================================
# Falling-MT6991 安装脚本 v3.5.0
# 内置: CPU/GPU/温控 + Vulkan 渲染增强 + 触控采样率调度 + UIboost + 真调度层
# Magisk/KernelSU/APatch 兼容
# ============================================================
SKIPUNZIP=1

# ---- 语言(安装提示) ----
LANGiso=$(settings get system system_locales 2>/dev/null)
case "$(echo "$LANGiso" | tr '[:upper:]' '[:lower:]')" in
  zh*) UI_ZH=1 ;;
  *)   UI_ZH=0 ;;
esac
msg() { [ "$UI_ZH" = 1 ] && ui_print "-- $2" || ui_print "- $1"; }

toupper() { tr '[:lower:]' '[:upper:]'; }

# 更新 system.conf 开关
setopt() { sed -i "s/^$1=.*/$1=$2/" "$MODPATH/config/system.conf"; }

# ---- 平台校验 ----
SOC=$(getprop ro.board.platform 2>/dev/null)
ARCH_V=${ARCH:-$ABI}
verify_requires() {
  [ "$BOOTMODE" = true ] || abort "Recovery install not supported"
  case "$SOC" in mt*|MT*) : ;; *) abort "[$SOC] not MediaTek";; esac
  case "$ARCH_V" in arm*|arm64*|x86_64|x64) : ;; *) abort "arch unsupported: $ARCH_V";; esac
  # F1: 非 MT6991 强提示(频率表按天玑9400)
  case "$SOC" in
    mt6991|MT6991) : ;;
    *) ui_print "WARN: [$SOC] 非 MT6991, 频率表按天玑9400, 自测风险自负" ;;
  esac
  msg "Device: $(getprop ro.product.model) | SOC: $SOC" \
      "设备: $(getprop ro.product.model) | SOC: $SOC"
}

# ---- 音量键选择; $1=超时默认(0=选项1/要, 1=选项2/不要); 返回 0=要 1=不要 ----
select_opt() {
  local def="${1:-0}"
  msg "Press VOL+ [1] / VOL- [2], 5s default [$([ "$def" = 0 ] && echo 1 || echo 2)]" \
      "按 VOL+ [1] / VOL- [2], 5s 默认 [$([ "$def" = 0 ] && echo 1 || echo 2)]"
  local deadline=$(( $(date +%s) + 5 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    timeout 1 /system/bin/getevent -lqc 1 > "$TMPDIR/ev" 2>&1
    grep -q 'KEY_VOLUMEUP *DOWN' "$TMPDIR/ev" && return 0
    grep -q 'KEY_VOLUMEDOWN *DOWN' "$TMPDIR/ev" && return 1
  done
  return "$def"
}

# ---- 触控采样率按欧加机型写默认命令 ----
# 数据来源: Aurorack 模块设备适配表(实机: 一加 Ace5 至尊版 -> 182 节点)
touch_defaults() {
  local name
  name=$(getprop ro.vendor.oplus.market.name 2>/dev/null | tr -d ' ' | tr '[:upper:]' '[:lower:]')
  local game daily
  case "$name" in
    *一加ace2*|*一加ace3*|*一加11*|*一加12*)
      game="touchHidlTest -c wo 0 26 12c"; daily="touchHidlTest -c wo 0 26 1" ;;
    *一加ace5*|*一加13*|*一加13t*)
      game="touchHidlTest -c wo 0 182 360"; daily="touchHidlTest -c wo 0 182 1" ;;
    *真我*)
      game="touchHidlTest -c wo 0 26 c"; daily="touchHidlTest -c wo 0 26 1" ;;
    *)
      game="touchHidlTest -c wo 0 26 12c"; daily="touchHidlTest -c wo 0 26 1" ;;
  esac
  sed -i \
    -e "s|^日常=.*|日常=$daily|" \
    -e "s|^游戏=.*|游戏=$game|" \
    "$MODPATH/config/触控.md"
  msg "touch defaults: $daily / $game" "触控默认: $daily / $game"

  # F3: 无 touchHidlTest 时禁用触控并警告
  if [ ! -x /odm/bin/touchHidlTest ] && [ ! -x /vendor/bin/touchHidlTest ]; then
    sed -i 's/^touch=.*/touch=0/' "$MODPATH/config/system.conf"
    msg "WARN: touchHidlTest 缺失, 触控已禁用" "警告: touchHidlTest 缺失, 触控已禁用"
  fi
}

# ---- 功能逐项选择(写 config/system.conf) ----
# 已剔除 Vulkan 渲染增强/进程加速/核心分配/内存参数/性能追踪
feature_select() {
  msg "Feature select (VOL+ yes / VOL- no)" "功能选择 (VOL+ 要 / VOL- 不要)"

  # 1. 后台守护
  pick "后台守护(智能档位/触控采样率/息屏)" 0
  setopt daemon "$PICK"
  # AGENTS 规则: touch_defaults 已因 touchHidlTest 缺失禁用触控时, 禁止再用音量键写回 1
  if [ -x /odm/bin/touchHidlTest ] || [ -x /vendor/bin/touchHidlTest ]; then
    setopt touch "$PICK"
  else
    setopt touch 0
  fi
  setopt debug 0

  # 2. ZRAM 内存优化 (参考 Color ZRAM/toolfor, 默认不要)
  pick "ZRAM 内存优化" 1
  setopt zram "$PICK"

  # 3. 系统通知
  pick "系统通知" 0
  setopt notify "$PICK"

  msg "feature defaults written" "功能默认态已写入(可在 WebUI 随时改)"
}

# ---- 解压 + 安装 ----
# ZRAM 内存优化 —— 安装时从设备 /my_stock/etc/extension 复制系统 XML 并改写,
#       由 post-fs-data.sh bind 覆盖(设备无源文件则跳过, 不猜测)
zram_setup() {
  [ "$(grep '^zram=1' "$MODPATH/config/system.conf" 2>/dev/null)" = "zram=1" ] || return 0
  local src dst
  src=/my_stock/etc/extension
  dst="$MODPATH/my_stock/etc/extension"
  [ -d "$src" ] || { ui_print "  - ZRAM: /my_stock/etc/extension 不存在, 跳过系统 XML 修改"; return 0; }
  mkdir -p "$dst"
  if [ -f "$src/sys_memory_nirvana_config.xml" ]; then
    cp -f "$src/sys_memory_nirvana_config.xml" "$dst/" 2>/dev/null
    sed -i \
      -e 's|<item name="HighTempThreshold" type="int" value="[^"]*"/>|<item name="HighTempThreshold" type="int" value="46"/>|' \
      -e 's|<item name="ThermalEnterThres" type="int" value="[^"]*"/>|<item name="ThermalEnterThres" type="int" value="46000"/>|' \
      -e 's|<item name="ThermalExitThres" type="int" value="[^"]*"/>|<item name="ThermalExitThres" type="int" value="44000"/>|' \
      -e 's|<item name="ExpectedBgCountMap" type="string" value="[^"]*"/>|<item name="ExpectedBgCountMap" type="string" value="6-99|8-99|12-99|16-99|24-99"/>|' \
      -e 's|<item name="CamExpectedBgCount" type="string" value="[^"]*"/>|<item name="CamExpectedBgCount" type="string" value="6-99|8-99|12-99|16-99|24-99"/>|' \
      -e 's|<item name="thermal_level_42000" type="string" value="[^"]*"/>|<item name="thermal_level_42000" type="string" value="8-99|12-99|16-99|24-99"/>|' \
      -e 's|<item name="thermal_level_51000" type="string" value="[^"]*"/>|<item name="thermal_level_51000" type="string" value="8-50|12-50|16-50|24-50"/>|' \
      "$dst/sys_memory_nirvana_config.xml" 2>/dev/null
    ui_print "  - ZRAM: 已改写 sys_memory_nirvana_config.xml"
  fi
  if [ -f "$src/sys_osense_feature_common_config.xml" ]; then
    cp -f "$src/sys_osense_feature_common_config.xml" "$dst/" 2>/dev/null
    sed -i \
      -e 's|<item name="EnableIdleDynamicSwappiness" type="bool" value="[^"]*"/>|<item name="EnableIdleDynamicSwappiness" type="bool" value="true"/>|' \
      -e 's|<item name="EnableBalancedSwappiness" type="bool" value="[^"]*"/>|<item name="EnableBalancedSwappiness" type="bool" value="true"/>|' \
      -e 's|<item name="BalancedSwappiness" type="int" value="[^"]*"/>|<item name="BalancedSwappiness" type="int" value="160"/>|' \
      -e 's|<item name="HighloadSwappiness" type="int" value="[^"]*"/>|<item name="HighloadSwappiness" type="int" value="160"/>|' \
      "$dst/sys_osense_feature_common_config.xml" 2>/dev/null
    ui_print "  - ZRAM: 已改写 sys_osense_feature_common_config.xml"
  fi
}

# ---- v1.2.0 迁移: 旧版 sched_daily.conf 的键名少了 HMBIRD_ 前缀 ----
# 旧包写的是 PARC_HIGH / MISFIT / C7TL / CPUCTRL_* / ISOLATE / SLIM_WALT,
# 节点表里查不到, sched.sh 一直静默跳过, 所以这一档实际只写进了 3 个键。
# 只改 sched_daily.conf(唯一写错的档), 用户其它自定义键原样保留; 改过则再次跳过。
sched_migrate_keys() {
  local f="$MODPATH/config/profiles/sched_daily.conf"
  [ -f "$f" ] || return 0
  grep -q '^PARC_HIGH=\|^MISFIT=\|^C7TL=\|^ISOLATE=' "$f" 2>/dev/null || return 0
  sed -i \
    -e 's/^PARC_HIGH=/HMBIRD_PARC_HIGH=/' \
    -e 's/^PARC_LOW=/HMBIRD_PARC_LOW=/' \
    -e 's/^MISFIT=/HMBIRD_MISFIT=/' \
    -e 's/^C7TL=/HMBIRD_C7TL=/' \
    -e 's/^CPUCTRL_HIGH=/HMBIRD_CPUCTRL_HIGH=/' \
    -e 's/^CPUCTRL_LOW=/HMBIRD_CPUCTRL_LOW=/' \
    -e 's/^ISOLATE=/HMBIRD_ISOLATE=/' \
    -e 's/^SLIM_WALT=/SLIM_WALT_CTRL=/' \
    "$f" 2>/dev/null
  msg "sched_daily.conf keys migrated to HMBIRD_*" "已迁移 sched_daily.conf 键名(HMBIRD_*)"
}

# ---- v2.0 迁移: 清掉 v1.x「手动调节」遗留 ----
# 场景(config/scenes)、配置方案(config/schemes)、帧率守护(config/fps.conf)、
# 默认档位(config/current_profile) 在 v2.0 全部取消, 改由 lib/smart.sh 自动决策。
# 「保留配置」升级时这些旧文件会被一起带进来, 必须删掉, 否则 UI/日志会读到脏数据。
legacy_cleanup() {
  local c="$MODPATH/config" k
  rm -rf "$c/scenes" "$c/schemes" 2>/dev/null
  rm -f "$c/fps.conf" "$c/current_profile" 2>/dev/null
  # 温控改为恒开(安全层); powercfg 对外接口与用户态调速器已移除
  for k in powercfg thermal_tune labs_usergov; do
    sed -i "/^$k=/d" "$c/system.conf" 2>/dev/null
  done
  rm -f "$c/runtime/scene.current" "$c/runtime/scene_force" "$c/runtime/fps.state" 2>/dev/null
  # v2.2: 温控基线从两列改三列(多了"本模块上次写入值"), 旧文件按作废处理,
  # 开机由 thermal_tune 按当前上限重新记录(不删会让基线一路雪崩的历史值被继承)
  rm -f "$c/runtime/thermal.base" 2>/dev/null
}

# ---- v2.1 迁移: 老配置里没有 game_mode, 补一行默认值 ----
# 缺这个键时守护进程按 official 处理(等价默认), 但 UI 会显示未设置;
# 补上后「保留配置」升级的用户也能正常在调度页切换游戏调度。
game_mode_migrate() {
  local f="$MODPATH/config/system.conf"
  [ -f "$f" ] || return 0
  grep -q '^game_mode=' "$f" 2>/dev/null && return 0
  printf 'game_mode=official\n' >> "$f"
  msg "system.conf: game_mode added" "已补 game_mode=official (游戏默认交官方)"
}

# ---- v3.5.0 迁移: 均衡档改成「日常省电档」 ----
# 「保留配置」升级会把旧的 balanced.conf 带进来, 那样升完还是接近满频
# (2.4/3.3/3.6 GHz), 用户的「不够省电」不会有任何改善。
# 只在文件仍是旧版原样(签名完全一致)时替换成新默认; 用户自己改过的不动。
# 同时补齐老配置里没有的 stock.conf(卸载时的出厂还原档)。
balanced_migrate_v35() {
  local f="$MODPATH/config/profiles/balanced.conf"
  local d="$MODPATH/config/defaults/profiles/balanced.conf"
  if [ -f "$f" ] && [ -f "$d" ]; then
    if grep -q '^MAXFREQ=2400000 3300000 3600000$' "$f" 2>/dev/null || \
       grep -q '^MAXFREQ=2400000 3300000 3730000$' "$f" 2>/dev/null; then
      cp -f "$d" "$f" 2>/dev/null
      msg "balanced profile -> daily power-saving" "均衡档已更新为日常省电档"
      # 旧配置的默认倾向是 balance, 与旧均衡档一起升级时同步成 save;
      # 用户手动选过 perf 的不动
      local sc="$MODPATH/config/system.conf"
      [ -f "$sc" ] && sed -i 's/^tendency=balance$/tendency=save/' "$sc" 2>/dev/null
    fi
  fi
  # 老配置没有 stock.conf, 卸载时 apply stock 会失败 -> 补上
  [ -f "$MODPATH/config/profiles/stock.conf" ] || \
    cp -f "$MODPATH/config/defaults/profiles/stock.conf" \
          "$MODPATH/config/profiles/stock.conf" 2>/dev/null
  return 0
}

install_module() {  msg "Extracting..." "解压中..."
  unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2 || abort "unzip failed"
  rm -rf "$MODPATH/META-INF" 2>/dev/null

  # 守护进程安装到 systemless bin(无 CLI, 控制全走 WebUI/库函数)
  local SB="$MODPATH/system/bin"
  mkdir -p "$SB"
  cp -f "$MODPATH/bin/falling_daemon" "$SB/falling_daemon"

  # ---- 升级检测: 询问 保留/覆盖 现有配置 ----
  pick() { # $1=项目名 $2=默认(0要/1不要) -> PICK=1要/0不要
    msg "Select: $1 (default $([ "$2" = 0 ] && echo yes || echo no))" \
        "选择: $1 (5s 默认 $([ "$2" = 0 ] && echo 要 || echo 不要))"
    select_opt "$2"; PICK=$((1 - $?))
  }
  local KEEP_CFG=0
  # 仅当存在"真安装"标记(已生成 device.conf)才询问升级保留/覆盖;
  # 残留空目录/坏包不触发, 一律走全新安装功能选择
  if [ -s /data/adb/modules/falling-mt6991/config/device.conf ]; then
    pick "升级: 保留现有配置?" 0
    KEEP_CFG=$PICK
  fi

  if [ "$KEEP_CFG" = 1 ]; then
    # 保留: 拷贝旧配置(用户数据: 应用策略/触控命令/档位参数/阈值),
    # 但功能开关仍逐项重新选择; 排除运行时状态与已迁移旧文件
    msg "保留现有配置, 重选功能" "保留现有配置, 重选功能"
    # config/defaults 必须始终用新包的: 旧包的 defaults 会盖掉新默认,
    # 之后 WebUI「恢复默认」就会退回旧行为(例如旧的均衡档)。
    # 先备份新 defaults, 拷完旧配置再放回。
    local NEWDEF="${TMPDIR:-/data/local/tmp}/pmk_new_defaults"
    rm -rf "$NEWDEF" 2>/dev/null
    cp -af "$MODPATH/config/defaults" "$NEWDEF" 2>/dev/null
    cp -af /data/adb/modules/falling-mt6991/config/. "$MODPATH/config/" 2>/dev/null
    rm -rf "$MODPATH/config/runtime" 2>/dev/null
    rm -f "$MODPATH/config/"*.migrated 2>/dev/null
    if [ -d "$NEWDEF" ]; then
      rm -rf "$MODPATH/config/defaults" 2>/dev/null
      cp -af "$NEWDEF" "$MODPATH/config/defaults" 2>/dev/null
      rm -rf "$NEWDEF" 2>/dev/null
    fi
    feature_select
  else
    # 覆盖: 全新默认(触控机型命令 + 实机检测 + 功能逐项选择)
    msg "覆盖为新配置" "覆盖为新配置"

    # 触控默认命令按机型
    touch_defaults

    # 实机检测 -> device.conf
    MODDIR="$MODPATH" PMK_CONFIG_DIR="$MODPATH/config" \
      sh "$MODPATH/lib/detect.sh" gen
    if [ -s "$MODPATH/config/device.conf" ]; then
      msg "device.conf generated" "已生成 device.conf"
    else
      msg "WARN: device.conf empty" "警告: device.conf 为空"
    fi

    feature_select
  fi

  # v2.0: 清掉场景/方案/帧率守护/默认档位等手动调节遗留
  legacy_cleanup

  # v1.2.0: 迁移旧档位键名(保留配置升级时旧文件会盖掉新默认)
  sched_migrate_keys

  # v2.1: 老配置补 game_mode 键
  game_mode_migrate

  # v3.5.0: 旧均衡档 -> 日常省电档(仅旧版原样时), 并补 stock.conf
  balanced_migrate_v35

  # 权限(注意: webroot 权限/SELinux 由 KernelSU 自动设置, 官方警告勿手动改)
  set_perm_recursive "$MODPATH" 0 0 0755 0644
  set_perm_recursive "$SB"     0 2000 0755 0755
  set_perm_recursive "$MODPATH/config" 0 0 0755 0644
  [ -f "$SB/falling_daemon" ] && set_perm "$SB/falling_daemon" 0 0 0755

  # ZRAM 内存优化: 安装时改写系统 XML(仅 zram=1)
  zram_setup

  # 自检默认档(经库函数, 无 CLI)
  local v
  v=$(PMK_DATA_DIR="$MODPATH" PMK_CONFIG_DIR="$MODPATH/config" sh "$MODPATH/lib/governor.sh" validate balanced 2>&1)
  msg "self-check balanced: $v" "自检 balanced: $v"
  # v1.2.0: 调度档键名/值域自检(未知键或值越界会打出 FAIL)
  v=$(PMK_CONFIG_DIR="$MODPATH/config" sh "$MODPATH/lib/sched.sh" check 2>&1 | tail -1)
  msg "self-check sched: $v" "自检 sched 档位: $v"
}

print_banner() {
  ui_print ""
  ui_print "  Falling-MT6991 v3.2.0"
  ui_print "  Dimensity 9400 调度模块"
  ui_print "  全智能调度(分簇感知) | 真调度层 | 智能温控 | 触控采样率 | 决策历史 | WebUI"
  ui_print "  ZRAM | 游戏 CPU 交官方调度"
  ui_print ""
}

# ---- main ----
print_banner
verify_requires
sleep 0.3
install_module
msg "Done! Reboot to apply." "安装完成! 重启生效。"
