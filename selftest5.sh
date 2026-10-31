#!/system/bin/sh
# PerfMTK-MT6991 v1.3.0 自检
export PMK_DATA_DIR=/data/local/tmp/pmk_test
export PMK_CONFIG_DIR=/data/local/tmp/pmk_test/config
export MODDIR=/data/local/tmp/pmk_test
D=/data/local/tmp/pmk_test

echo "== [1] syntax =="
for f in $D/customize.sh $D/service.sh $D/lib/*.sh $D/bin/perfmtk $D/bin/perfmtk_daemon $D/bin/thermal_limit; do
  sh -n "$f" 2>/dev/null || echo "FAIL $f"
done
echo "syntax done"

echo "== [2] 专属采样率 per-app =="
echo "com.test.game=360" >> $D/config/app_touch.conf
echo "code for com.test.game: $(sh $D/lib/touch.sh load && grep -m1 '^com.test.game=' $D/config/app_touch.conf | cut -d= -f2)"
# 直接测 touch_tick 逻辑: 通过 daemon 前先单独测 apply_code
sh -c "export MODDIR=$D PMK_DATA_DIR=$D PMK_CONFIG_DIR=$D/config; . $D/lib/touch.sh; touch_load; touch_apply_code 360 com.test.game"
echo "state: $(cat $D/config/.touch_state)"
sh -c "export MODDIR=$D PMK_DATA_DIR=$D PMK_CONFIG_DIR=$D/config; . $D/lib/touch.sh; touch_load; touch_apply_code 360 com.test.game"  # 重复应跳过
sleep 1
echo "touchHidlTest 执行次数: $(logcat -d 2>/dev/null | grep -c 'command wo handle OK')"
sed -i '/^com.test.game=/d' $D/config/app_touch.conf
echo "rule removed"

echo "== [3] 应用策略 daemon 读取 =="
echo "com.tencent.mobileqq=performance" >> $D/config/app_policy.conf
rm -f /data/local/tmp/perfmtk_mt6991.log
timeout 16 sh $D/bin/perfmtk_daemon 2>&1 &
sleep 16
grep -E "daemon: profile|touch:" /data/local/tmp/perfmtk_mt6991.log | head -4
sed -i '/^com.tencent.mobileqq=/d' $D/config/app_policy.conf
echo "policy removed"

echo "== [4] 详细日志(write_file 前后值 + debug) =="
echo 1 > $D/config/debug_enabled
timeout 12 sh $D/bin/perfmtk_daemon 2>&1 &
sleep 12
grep -E "\[w\]|\[debug\] cycle" /data/local/tmp/perfmtk_mt6991.log | head -6
echo 0 > $D/config/debug_enabled

echo "== [5] 功能开关文件 =="
for f in daemon_enabled touch_enabled uiboost_enabled debug_enabled; do
  echo "$f=$(cat $D/config/$f)"
done
echo "== [6] validate =="
sh $D/bin/perfmtk --validate balanced
sh $D/bin/perfmtk --validate performance
echo "== DONE-Y =="
