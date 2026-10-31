#!/system/bin/sh
export PMK_DATA_DIR=/data/local/tmp/pmk_test
export PMK_CONFIG_DIR=/data/local/tmp/pmk_test/config
export MODDIR=/data/local/tmp/pmk_test
D=/data/local/tmp/pmk_test

echo "== [1] zip 解压验证(模拟安装器) =="
which unzip >/dev/null 2>&1 && { rm -rf /data/local/tmp/zip_test; mkdir -p /data/local/tmp/zip_test; unzip -o /data/local/tmp/PerfMTK-MT6991-v1.4.1.zip -d /data/local/tmp/zip_test >/dev/null 2>&1 && echo "unzip OK: $(find /data/local/tmp/zip_test -maxdepth 2 -type f | wc -l) files" || echo "unzip FAIL"; ls /data/local/tmp/zip_test 2>/dev/null; } || echo "device no unzip"

echo "== [2] 卸载残留测试 =="
# 造环境: 本模块 powercfg + 日志 + 备份 + 去负优化痕迹
printf '#!/system/bin/sh\n# PerfMTK-MT6991 powercfg\ncase "$1" in *) :;; esac\n' > /data/powercfg.sh
echo '{"name":"PerfMTK-MT6991"}' > /data/powercfg.json
touch /data/local/tmp/perfmtk_mt6991.log
mkdir -p /data/local/tmp/perfmtk_mt6991_backup_test
echo 1 > $D/config/cleanup_enabled
echo 2 > $D/config/orig_oiface
echo "48 100 0 100" > $D/config/vm_backup
# 先改系统状态: 禁服务/改 oiface/vm
pm disable com.oplus.cosa/com.oplus.cosa.gamemanagersdk.CosaHyperBoostService >/dev/null 2>&1
setprop persist.sys.oiface.enable 1
echo 110 > /proc/sys/vm/watermark_scale_factor
echo 110 > /proc/sys/vm/vfs_cache_pressure

sh $D/uninstall.sh
echo "--- 验证 ---"
echo "powercfg.sh: $([ -f /data/powercfg.sh ] && echo 残留! || echo 已删)"
echo "powercfg.json: $([ -f /data/powercfg.json ] && echo 残留! || echo 已删)"
echo "log: $([ -f /data/local/tmp/perfmtk_mt6991.log ] && echo 残留! || echo 已删)"
echo "backup dir: $([ -d /data/local/tmp/perfmtk_mt6991_backup_test ] && echo 残留! || echo 已删)"
echo "cosa service: $(pm list packages -d 2>/dev/null | grep -c cosa) (0=已还原)"
echo "oiface: $(getprop persist.sys.oiface.enable) (应 2)"
echo "vm: $(cat /proc/sys/vm/watermark_scale_factor)/$(cat /proc/sys/vm/vfs_cache_pressure) (应 48/100)"
echo "== [3] syntax =="
for f in $D/uninstall.sh $D/customize.sh $D/service.sh $D/lib/*.sh $D/bin/perfmtk_daemon; do
  sh -n "$f" 2>/dev/null || echo "FAIL $f"
done
echo "== DONE-U2 =="
