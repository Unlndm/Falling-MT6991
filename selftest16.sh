#!/system/bin/sh
export PMK_DATA_DIR=/data/local/tmp/pmk_test
export PMK_CONFIG_DIR=/data/local/tmp/pmk_test/config
export MODDIR=/data/local/tmp/pmk_test
D=/data/local/tmp/pmk_test

FG=$(dumpsys activity activities 2>/dev/null | grep -m1 topResumedActivity | sed 's/.*u0 \([^/ ]*\).*/\1/')
echo "当前前台: $FG"
sed -i "s|^游戏包名=.*|游戏包名=$FG|" $D/config/触控.md

echo "== [1] 游戏调度=关 -> 游戏包应走日常档 =="
echo 0 > $D/config/game_sched_enabled
rm -f $D/config/.touch_state /data/local/tmp/perfmtk_mt6991.log
timeout 12 sh $D/bin/perfmtk_daemon >/dev/null 2>&1 &
sleep 12
echo "触控状态: $(cat $D/config/.touch_state 2>/dev/null) (应 daily)"
grep "touch:" /data/local/tmp/perfmtk_mt6991.log | tail -1

echo "== [2] 游戏调度=开 -> 游戏包走游戏档 =="
echo 1 > $D/config/game_sched_enabled
rm -f $D/config/.touch_state /data/local/tmp/perfmtk_mt6991.log
timeout 12 sh $D/bin/perfmtk_daemon >/dev/null 2>&1 &
sleep 12
echo "触控状态: $(cat $D/config/.touch_state 2>/dev/null) (应 game)"
grep "touch:" /data/local/tmp/perfmtk_mt6991.log | tail -1

echo "== [3] fps_tick 门控 =="
echo 0 > $D/config/game_sched_enabled
sh -c "export MODDIR=$D PMK_DATA_DIR=$D PMK_CONFIG_DIR=$D/config; . $D/lib/fps.sh; fps_load; echo 关时 fps_tick=[\$(fps_tick)] (应空)"
echo 1 > $D/config/game_sched_enabled
sh -c "export MODDIR=$D PMK_DATA_DIR=$D PMK_CONFIG_DIR=$D/config; . $D/lib/fps.sh; fps_load; echo 开时 fps_tick=[\$(fps_tick)]"
echo "== DONE-G2 =="
