#!/system/bin/sh
export PMK_DATA_DIR=/data/local/tmp/pmk_test
export PMK_CONFIG_DIR=/data/local/tmp/pmk_test/config
D=/data/local/tmp/pmk_test
echo "== fps.conf 内容 =="
cat -A $D/config/fps.conf | head -8
echo "== 手动解析测试 =="
PMK_FPS_CONF="$PMK_CONFIG_DIR/fps.conf"
. $D/lib/fps.sh 2>&1 | head -3
echo "PMK_FPS_CONF=$PMK_FPS_CONF"
[ -f "$PMK_FPS_CONF" ] && echo "文件存在" || echo "文件缺失!"
fps_load; echo "load rc=$?"
echo "ENABLE=[$FPS_EN] LOW=[$FPS_LOW_PCT]"
echo "== DONE-F3 =="
