#!/system/bin/sh
export PMK_DATA_DIR=/data/local/tmp/pmk_test
export PMK_CONFIG_DIR=/data/local/tmp/pmk_test/config
export MODDIR=/data/local/tmp/pmk_test
D=/data/local/tmp/pmk_test
echo "== [1] 游戏调度=关 -> daemon 恢复官方风驰 =="
echo 0 > $D/config/game_sched_enabled
pm disable com.oplus.cosa/com.oplus.cosa.gamemanagersdk.HyperBoostService >/dev/null 2>&1
rm -f /data/local/tmp/perfmtk_mt6991.log
timeout 12 sh $D/bin/perfmtk_daemon >/dev/null 2>&1 &
sleep 12
echo "HyperBoost 禁用数: $(pm list packages -d 2>/dev/null | grep -c cosa) (应 0)"
grep "风驰" /data/local/tmp/perfmtk_mt6991.log | tail -1
echo "== [2] fps.conf 面板字段可解析 =="
printf '# test\nENABLE=1\nLOW_PCT=60\nCHECK_CYCLES=3\nRECOVER_PCT=85\nRECOVER_CYCLES=5\nBOOST_PROFILE=powersave+\nMIN_TARGET=45\n' > $D/config/fps.conf
sh -c "export MODDIR=$D PMK_DATA_DIR=$D PMK_CONFIG_DIR=$D/config; . $D/lib/fps.sh; fps_load; echo 解析: ENABLE=$FPS_EN LOW=$FPS_LOW_PCT CHECK=$FPS_CHECK REC=$FPS_RECOVER_PCT RC=$FPS_RECOVER BOOST=$FPS_BOOST MIN=$FPS_MIN_TARGET"
echo "== [3] syntax =="
for f in $D/bin/perfmtk_daemon $D/lib/fps.sh $D/lib/touch.sh; do sh -n $f 2>/dev/null || echo "FAIL $f"; done
echo "== DONE-F2 =="
