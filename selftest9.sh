#!/system/bin/sh
export PMK_DATA_DIR=/data/local/tmp/pmk_test
export PMK_CONFIG_DIR=/data/local/tmp/pmk_test/config
export MODDIR=/data/local/tmp/pmk_test
D=/data/local/tmp/pmk_test

echo "== [1] is_game 单元测试 =="
FG=$(dumpsys activity activities 2>/dev/null | grep -m1 topResumedActivity | sed 's/.*u0 \([^/ ]*\).*/\1/')
echo "当前前台: $FG"
echo "$FG" > $D/config/.fg_test
sh -c "export MODDIR=$D PMK_DATA_DIR=$D PMK_CONFIG_DIR=$D/config; . $D/lib/touch.sh; touch_load; touch_is_game $FG && echo '正向: 命中游戏' || echo '正向: 未命中(错)'; touch_is_game com.not.in.list && echo '反向: 误命中(错)' || echo '反向: 正确未命中'"

echo "== [2] daemon 游戏档全链路 =="
sed -i "s|^游戏包名=.*|游戏包名=$FG|" $D/config/触控.md
rm -f $D/config/.touch_state /data/local/tmp/perfmtk_mt6991.log
logcat -c 2>/dev/null
timeout 14 sh $D/bin/perfmtk_daemon >/dev/null 2>&1 &
sleep 14
echo "触控状态: $(cat $D/config/.touch_state 2>/dev/null) (应 game)"
grep -E "touch:" /data/local/tmp/perfmtk_mt6991.log | head -2
logcat -d 2>/dev/null | grep -c "command wo handle OK" | awk '{print "touchHidlTest 执行次数:",$1}'

echo "== [3] 非游戏包回日常 =="
sed -i "s|^游戏包名=.*|游戏包名=com.not.in.list|" $D/config/触控.md
rm -f $D/config/.touch_state
timeout 12 sh $D/bin/perfmtk_daemon >/dev/null 2>&1 &
sleep 12
echo "触控状态: $(cat $D/config/.touch_state 2>/dev/null) (应 daily)"
grep "touch:" /data/local/tmp/perfmtk_mt6991.log | tail -1
echo "== DONE-Q2 =="
