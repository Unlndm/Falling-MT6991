#!/system/bin/sh
export PMK_DATA_DIR=/data/local/tmp/pmk_test
export PMK_CONFIG_DIR=/data/local/tmp/pmk_test/config
D=/data/local/tmp/pmk_test
echo "== [1] apply performance 持久化 =="
echo balanced > $D/config/current_profile
sh $D/lib/governor.sh apply performance
echo "档位文件: $(cat $D/config/current_profile) (应 performance)"
echo "rollback 文件: $(cat $D/config/.rollback 2>/dev/null || echo 无)"
echo "== [2] daemon 运行不覆盖 =="
timeout 10 sh $D/bin/perfmtk_daemon >/dev/null 2>&1 &
sleep 10
echo "daemon 后档位文件: $(cat $D/config/current_profile) (应仍 performance)"
echo "== [3] 恢复 balanced =="
sh $D/lib/governor.sh apply balanced
echo "档位文件: $(cat $D/config/current_profile) (应 balanced)"
echo "== DONE-P2 =="
