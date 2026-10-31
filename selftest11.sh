#!/system/bin/sh
export PMK_DATA_DIR=/data/local/tmp/pmk_test
export PMK_CONFIG_DIR=/data/local/tmp/pmk_test/config
D=/data/local/tmp/pmk_test
echo "== [1] 默认模式跟随性能档位 =="
echo "current_profile=performance"
echo performance > $D/config/current_profile
rm -f /data/local/tmp/perfmtk_mt6991.log
timeout 12 sh $D/bin/perfmtk_daemon >/dev/null 2>&1 &
sleep 12
echo "daemon 应用: $(grep 'daemon: profile' /data/local/tmp/perfmtk_mt6991.log | head -1 | sed 's/.*profile //;s/ (.*//') (应 performance)"
echo "== [2] 切回 balanced =="
echo balanced > $D/config/current_profile
rm -f /data/local/tmp/perfmtk_mt6991.log
timeout 12 sh $D/bin/perfmtk_daemon >/dev/null 2>&1 &
sleep 12
echo "daemon 应用: $(grep 'daemon: profile' /data/local/tmp/perfmtk_mt6991.log | head -1 | sed 's/.*profile //;s/ (.*//') (应 balanced)"
echo "== [3] 应用策略仍优先 =="
printf '%s\n' "$(dumpsys activity activities 2>/dev/null | grep -m1 topResumedActivity | sed 's/.*u0 \([^/ ]*\).*/\1/')=powersave" >> $D/config/app_policy.conf
rm -f /data/local/tmp/perfmtk_mt6991.log
timeout 12 sh $D/bin/perfmtk_daemon >/dev/null 2>&1 &
sleep 12
echo "daemon 应用: $(grep 'daemon: profile' /data/local/tmp/perfmtk_mt6991.log | head -1 | sed 's/.*profile //;s/ (.*//') (应 powersave, 策略优先)"
sed -i '/^com\./=d' $D/config/app_policy.conf
echo "== [4] syntax =="
sh -n $D/bin/perfmtk_daemon && echo daemon OK
echo "== DONE-S2 =="
