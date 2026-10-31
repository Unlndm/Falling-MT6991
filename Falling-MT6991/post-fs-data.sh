#!/system/bin/sh
# ============================================================
# Falling-MT6991 post-fs-data.sh
# 尽早解锁 cpufreq 写入权限(G1: root 属主 644, 不开放给所有进程)
# ============================================================
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$p" ] || continue
  chown root:root "$p/scaling_governor" "$p/scaling_min_freq" "$p/scaling_max_freq" 2>/dev/null
  chmod 644 "$p/scaling_governor" "$p/scaling_min_freq" "$p/scaling_max_freq" 2>/dev/null
done

# ---- ZRAM 内存优化: bind 覆盖系统 XML(仅 zram=1, 目标文件存在才挂) ----
# 数据来源: Color ZRAM 模块(toolfor) + 安装时从设备 /my_stock/etc/extension 复制的改写版
if [ "$(grep '^zram=1' /data/adb/modules/falling-mt6991/config/system.conf 2>/dev/null)" = "zram=1" ]; then
  MODDIR=${0%/*}
  ZRAM_SRC="$MODDIR/odm/etc"
  if [ -d "$ZRAM_SRC" ]; then
    [ -f /odm/etc/oplus_mm_config.xml ] && mount --bind "$ZRAM_SRC/oplus_mm_config.xml" /odm/etc/oplus_mm_config.xml 2>/dev/null
  fi
  # 安装时改写的系统 XML(设备源文件存在才会生成, 目标存在才挂)
  for f in "$MODDIR"/my_stock/etc/extension/*.xml; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    [ -f "/my_stock/etc/extension/$b" ] && mount --bind "$f" "/my_stock/etc/extension/$b" 2>/dev/null
  done
fi
exit 0
