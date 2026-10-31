#!/system/bin/sh
# ============================================================
# Falling-MT6991 彻底卸载: 删除全部文件 + 还原被改的系统状态
# 覆盖: 守护/UIboost 进程 | CPU/GPU/cm_mgr | Vulkan prop |
#       cpufreq/thermal 节点权限 | cpuset | 温控 | VM | cosa/oiface | powercfg | 日志
# ============================================================
MODDIR=${0%/*}
# shellcheck disable=SC1091
[ -f "$MODDIR/lib/common.sh" ] && . "$MODDIR/lib/common.sh"

# 0) 停本模块后台进程
pkill -f falling_daemon 2>/dev/null
# 0.1) 前台/屏态事件监视 logcat(守护进程 TERM 已自行清理, 此处兜底防强杀残留)
pkill -f 'logcat -b events -s wm_set_resumed_activity' 2>/dev/null

# 0.5) 还原调度策略(真调度层: PELT/uclamp/触控 boost 出厂值)
if [ -f "$MODDIR/lib/sched.sh" ]; then
  MODDIR="$MODDIR" PMK_DATA_DIR="$MODDIR" PMK_CONFIG_DIR="$MODDIR/config" \
    sh "$MODDIR/lib/sched.sh" disable 2>/dev/null
fi

# 0.6) 触控采样率还原(切回日常档, 低采样率)
if [ -f "$MODDIR/lib/touch.sh" ]; then
  MODDIR="$MODDIR" PMK_DATA_DIR="$MODDIR" PMK_CONFIG_DIR="$MODDIR/config" \
    sh "$MODDIR/lib/touch.sh" apply daily 2>/dev/null
fi

# 0.65) IO 调度还原(备份值)
if [ -f "$MODDIR/lib/io.sh" ]; then
  MODDIR="$MODDIR" PMK_DATA_DIR="$MODDIR" PMK_CONFIG_DIR="$MODDIR/config" \
    sh "$MODDIR/lib/io.sh" apply daily 2>/dev/null
fi

# 1) 还原 CPU/GPU/cm_mgr 到出厂档(用 stock.conf, 不触发回滚持久化)
#    v3.5.0 起 balanced 是「日常省电档」(GPU 上限/ cm_mgr 都压低了),
#    卸载不能拿它还原, 否则卸载到重启这段窗口会残留低功耗值。
if [ -f "$MODDIR/lib/governor.sh" ]; then
  MODDIR="$MODDIR" PMK_DATA_DIR="$MODDIR" PMK_CONFIG_DIR="$MODDIR/config" \
    sh "$MODDIR/lib/governor.sh" apply stock 2>/dev/null
fi

# 1.5) 解除模块自己写的频率上限(scaling_max_freq -> cpuinfo_max_freq)
#      守护进程已停, 没有人会再写这个节点; 不释放的话低上限会一直留到重启。
if [ -f "$MODDIR/lib/loop.sh" ]; then
  MODDIR="$MODDIR" PMK_DATA_DIR="$MODDIR" PMK_CONFIG_DIR="$MODDIR/config" \
    sh "$MODDIR/lib/loop.sh" release 2>/dev/null
fi

# 2) 还原温控(thermal zones 恢复 enabled)
if [ -f "$MODDIR/lib/governor.sh" ]; then
  MODDIR="$MODDIR" PMK_DATA_DIR="$MODDIR" PMK_CONFIG_DIR="$MODDIR/config" \
    sh "$MODDIR/lib/governor.sh" thermal enable 2>/dev/null
fi

# 3) v2.3 起不再覆盖 powerhal XML; 老版本残留的挂载点在这里兜底卸掉
umount /system/vendor/etc/powerscntbl.xml 2>/dev/null
umount /system/vendor/etc/power_app_cfg.xml 2>/dev/null

# 3.5) 卸载 ZRAM 覆盖(oplus_mm_config.xml + my_stock 系统 XML)
umount /odm/etc/oplus_mm_config.xml 2>/dev/null
for f in "$MODDIR"/my_stock/etc/extension/*.xml; do
  [ -f "$f" ] || continue
  umount "/my_stock/etc/extension/$(basename "$f")" 2>/dev/null
done

# 4) 还原 cpufreq 节点原属主与权限(首次解锁时已备份)
cpufreq_perm_restore 2>/dev/null

# 5) 删除外部调度接口文件(仅本模块生成的, 大小写不敏感匹配)
[ -f /data/powercfg.sh ] && grep -qi falling-mt6991 /data/powercfg.sh 2>/dev/null && rm -f /data/powercfg.sh
[ -f /data/powercfg.json ] && grep -qi falling-mt6991 /data/powercfg.json 2>/dev/null && rm -f /data/powercfg.json

# 6) 清理运行期文件(日志/备份)
rm -f /data/local/tmp/falling_mt6991.log 2>/dev/null
rm -rf /data/local/tmp/falling_mt6991_backup_* 2>/dev/null

exit 0
