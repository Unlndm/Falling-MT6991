#!/system/bin/sh
export PMK_DATA_DIR=/data/local/tmp/pmk_test
export PMK_CONFIG_DIR=/data/local/tmp/pmk_test/config
echo 0 > /data/local/tmp/pmk_test/config/game_sched_enabled
echo "关: [$(sh /data/local/tmp/pmk_test/lib/fps.sh tick)] (应空)"
echo 1 > /data/local/tmp/pmk_test/config/game_sched_enabled
echo "开: [$(sh /data/local/tmp/pmk_test/lib/fps.sh tick)]"
echo "== DONE-G3 =="
