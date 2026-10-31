#!/system/bin/sh
export MODDIR=/data/local/tmp/pmk_test
export PMK_DATA_DIR=/data/local/tmp/pmk_test
export PMK_CONFIG_DIR=/data/local/tmp/pmk_test/config
D=/data/local/tmp/pmk_test
printf '# test\nENABLE=1\nLOW_PCT=60\nCHECK_CYCLES=3\nRECOVER_PCT=85\nRECOVER_CYCLES=5\nBOOST_PROFILE=powersave+\nMIN_TARGET=45\n' > $D/config/fps.conf
. $D/lib/fps.sh
fps_load
echo "解析: ENABLE=$FPS_EN LOW=$FPS_LOW_PCT CHECK=$FPS_CHECK REC=$FPS_RECOVER_PCT RC=$FPS_RECOVER BOOST=$FPS_BOOST MIN=$FPS_MIN_TARGET"
echo "ratio: $(fps_lowest_ratio)"
echo "tick: [$(fps_tick)]"
echo "== DONE-F4 =="
