#!/system/bin/sh
# PerfMTK-MT6991 v1.4.0 自检 (无 CLI)
export PMK_DATA_DIR=/data/local/tmp/pmk_test
export PMK_CONFIG_DIR=/data/local/tmp/pmk_test/config
D=/data/local/tmp/pmk_test

echo "== [1] syntax =="
for f in $D/customize.sh $D/service.sh $D/lib/*.sh $D/bin/perfmtk_daemon; do
  sh -n "$f" 2>/dev/null || echo "FAIL $f"
done
echo "done; bin 目录: $(ls $D/bin)"

echo "== [2] 库函数独立调用 (无 MODDIR, 回退测试) =="
echo "-- apply balanced --"
sh $D/lib/governor.sh apply balanced && echo "apply rc=$?"
echo "-- validate --"
sh $D/lib/governor.sh validate balanced
sh $D/lib/governor.sh validate performance
echo "-- backup --"
sh $D/lib/governor.sh backup
echo "-- thermal --"
sh $D/lib/governor.sh thermal disable
echo "z14: $(cat /sys/class/thermal/thermal_zone14/mode)"
sh $D/lib/governor.sh thermal enable
echo "z14: $(cat /sys/class/thermal/thermal_zone14/mode)"

echo "== [3] daemon (经库函数) 14s =="
rm -f /data/local/tmp/perfmtk_mt6991.log
timeout 14 sh $D/bin/perfmtk_daemon 2>&1 &
sleep 14
grep -E "daemon:|touch:" /data/local/tmp/perfmtk_mt6991.log | head -4

echo "== [4] powercfg 生成内容走库函数 =="
sh $D/lib/powercfg.sh gen
grep "governor.sh" /data/powercfg.sh | head -2
rm -f /data/powercfg.sh /data/powercfg.json

echo "== [5] 日志前后值 =="
grep "\[w\]" /data/local/tmp/perfmtk_mt6991.log | head -2
echo "== DONE-Z =="
