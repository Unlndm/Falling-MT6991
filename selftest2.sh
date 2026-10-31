#!/system/bin/sh
# PerfMTK-MT6991 v1.1.0 集成自检
export PMK_DATA_DIR=/data/local/tmp/pmk_test
export PMK_CONFIG_DIR=/data/local/tmp/pmk_test/config
export MODDIR=/data/local/tmp/pmk_test
D=/data/local/tmp/pmk_test

echo "== [1] syntax =="
for f in $D/customize.sh $D/service.sh $D/lib/*.sh $D/bin/perfmtk $D/bin/perfmtk_daemon $D/bin/thermal_limit; do
  sh -n "$f" 2>/dev/null && echo "OK  $(basename $f)" || echo "FAIL $f"
done

echo "== [2] touch: load/apply daily =="
sh $D/lib/touch.sh load && echo "loaded: daily=[$(grep -oP '(?<=日常=).*' $D/config/触控.md)]"
sh $D/lib/touch.sh apply daily && echo "daily state: $(cat $D/config/.touch_state)"
echo "== [3] touch: apply game =="
sh $D/lib/touch.sh apply game && echo "game state: $(cat $D/config/.touch_state)"
sh $D/lib/touch.sh apply daily
logcat -d 2>/dev/null | grep -c "command wo handle OK" | awk '{print "touchHidlTest OK count:",$1}'

echo "== [4] uiboost: mode + boost =="
echo "mode: $(sh $D/lib/uiboost.sh mode)"
sh $D/lib/uiboost.sh boost && echo "boost rc=$?"
echo "== [5] uiboost: start (mode2 应一次退出) =="
echo 2 > $D/config/mode.txt
timeout 6 sh $D/lib/uiboost.sh start 2>&1 | head -3
echo "start rc=$?"
echo 1 > $D/config/mode.txt

echo "== [6] vulkan: status + toggle =="
sh $D/lib/vulkan.sh status
sh $D/lib/vulkan.sh disable && echo "--- after disable ---" && sh $D/lib/vulkan.sh status
sh $D/lib/vulkan.sh enable && echo "--- after enable ---" && sh $D/lib/vulkan.sh status
echo "system.prop head after enable:"
head -3 $D/system.prop

echo "== [7] notify: test =="
logcat -c 2>/dev/null
sh $D/lib/notify.sh test; echo "notify rc=$?"
sleep 1
logcat -d 2>/dev/null | grep -iE "NotificationService|perfmtk" | tail -3

echo "== [8] daemon integrated 15s =="
rm -f /data/local/tmp/perfmtk_mt6991.log
timeout 15 sh $D/bin/perfmtk_daemon 2>&1 &
sleep 15
echo "--- daemon log ---"
grep -E "daemon:|touch:" /data/local/tmp/perfmtk_mt6991.log | head -8

echo "== [9] cli validate =="
sh $D/bin/perfmtk --validate balanced
sh $D/bin/perfmtk --validate performance
echo "== DONE-V11 =="
