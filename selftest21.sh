#!/system/bin/sh
export PMK_DATA_DIR=/data/local/tmp/pmk_test
export PMK_CONFIG_DIR=/data/local/tmp/pmk_test/config
export MODDIR=/data/local/tmp/pmk_test
D=/data/local/tmp/pmk_test
echo "== [1] apply performance -> fps.conf 套用性能默认 =="
echo 0 > $D/config/fps.conf; echo "ENABLE=0" >> $D/config/fps.conf
sh $D/lib/governor.sh apply performance
echo "--- fps.conf ---"; grep -E "ENABLE|LOW|CHECK|RECOVER|BOOST|MIN" $D/config/fps.conf
echo "== [2] apply powersave -> 省电默认, ENABLE 保留 =="
sh $D/lib/governor.sh apply powersave
echo "--- fps.conf ---"; grep -E "ENABLE|LOW|CHECK|RECOVER|BOOST|MIN" $D/config/fps.conf
echo "== [3] apply balanced -> 均衡默认 =="
sh $D/lib/governor.sh apply balanced
grep -E "LOW_PCT|BOOST_PROFILE" $D/config/fps.conf
echo "== [4] syntax =="
sh -n $D/lib/governor.sh && sh -n $D/lib/common.sh && echo OK
echo "== DONE-F5 =="
