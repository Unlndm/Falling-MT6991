#!/system/bin/sh
export PMK_DATA_DIR=/data/local/tmp/pmk_test
export PMK_CONFIG_DIR=/data/local/tmp/pmk_test/config
export MODDIR=/data/local/tmp/pmk_test
D=/data/local/tmp/pmk_test

FG=$(dumpsys activity activities 2>/dev/null | grep -m1 topResumedActivity | sed 's/.*u0 \([^/ ]*\).*/\1/')
echo "前台: $FG"
sed -i "s|^游戏包名=.*|游戏包名=$FG|" $D/config/触控.md

echo "== [1] 游戏调度=关: 调度不干预(交回风驰), 但触控仍切游戏档 =="
echo 0 > $D/config/game_sched_enabled
rm -f $D/config/.touch_state /data/local/tmp/perfmtk_mt6991.log
timeout 14 sh $D/bin/perfmtk_daemon >/dev/null 2>&1 &
sleep 14
echo "触控状态: $(cat $D/config/.touch_state 2>/dev/null) (应 game, 采样率独立)"
echo "档位应用日志: $(grep -c 'daemon: profile' /data/local/tmp/perfmtk_mt6991.log) 条 (应 0, 调度已交回)"
grep -E "交回官方|touch:" /data/local/tmp/perfmtk_mt6991.log | tail -2

echo "== [2] 游戏调度=开: 正常调度 + 游戏触控档 =="
echo 1 > $D/config/game_sched_enabled
rm -f $D/config/.touch_state /data/local/tmp/perfmtk_mt6991.log
timeout 14 sh $D/bin/perfmtk_daemon >/dev/null 2>&1 &
sleep 14
echo "触控状态: $(cat $D/config/.touch_state 2>/dev/null) (应 game)"
echo "档位应用日志: $(grep -c 'daemon: profile' /data/local/tmp/perfmtk_mt6991.log) 条 (应 ≥1)"
echo "== DONE-G4 =="
