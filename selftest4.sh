#!/system/bin/sh
# PerfMTK-MT6991 v1.2.0 自检
export PMK_DATA_DIR=/data/local/tmp/pmk_test
export PMK_CONFIG_DIR=/data/local/tmp/pmk_test/config
export MODDIR=/data/local/tmp/pmk_test
D=/data/local/tmp/pmk_test

echo "== [1] syntax =="
for f in $D/customize.sh $D/service.sh $D/lib/*.sh $D/bin/perfmtk $D/bin/perfmtk_daemon $D/bin/thermal_limit; do
  sh -n "$f" 2>/dev/null || echo "FAIL $f"
done
echo "syntax done"

echo "== [2] cpuset apply =="
echo "before: sf=$(cat /dev/cpuset/sf/cpus) bg=$(cat /dev/cpuset/background/cpus) oiface_bg=$(cat /dev/cpuset/oiface_bg/cpus 2>/dev/null)"
sh $D/lib/cpuset.sh apply
echo "after:  sf=$(cat /dev/cpuset/sf/cpus) bg=$(cat /dev/cpuset/background/cpus) display=$(cat /dev/cpuset/display/cpus) oiface_bg=$(cat /dev/cpuset/oiface_bg/cpus 2>/dev/null)"
sh $D/lib/cpuset.sh disable
echo "restored: sf=$(cat /dev/cpuset/sf/cpus) bg=$(cat /dev/cpuset/background/cpus)"

echo "== [3] vm apply =="
echo "before: $(cat /proc/sys/vm/watermark_scale_factor)/$(cat /proc/sys/vm/vfs_cache_pressure)/$(cat /proc/sys/vm/watermark_boost_factor)/$(cat /proc/sys/vm/swappiness)"
sh $D/lib/vm.sh apply 110 400 15000 80
echo "after:  $(cat /proc/sys/vm/watermark_scale_factor)/$(cat /proc/sys/vm/vfs_cache_pressure)/$(cat /proc/sys/vm/watermark_boost_factor)/$(cat /proc/sys/vm/swappiness)"
sh $D/lib/vm.sh apply 48 100 0 100

echo "== [4] fps tick =="
sh $D/lib/fps.sh load
echo "ratio: $(sh $D/lib/fps.sh ratio)"
for i in 1 2 3 4; do echo "tick$i: [$(sh $D/lib/fps.sh tick)]"; done

echo "== [5] cleanup apply (将验证后还原) =="
sh $D/lib/cleanup.sh apply
echo "oiface=$(getprop persist.sys.oiface.enable) gameopt_limit=$(cat /proc/game_opt/disable_cpufreq_limit)"
echo "deadline=$(cat /proc/sys/kernel/sched_deadline_period_min_us)/$(cat /proc/sys/kernel/sched_deadline_period_max_us) mlock=$(cat /proc/sys/kernel/perf_event_mlock_kb)"
echo "== 还原 cleanup 测试副作用 =="
setprop persist.sys.oiface.enable 2
echo 0 > /proc/game_opt/disable_cpufreq_limit
echo 100 > /proc/sys/kernel/sched_deadline_period_min_us
echo 4194304 > /proc/sys/kernel/sched_deadline_period_max_us
pm enable com.oplus.cosa/com.oplus.cosa.gamemanagersdk.CosaHyperBoostService >/dev/null 2>&1
pm enable com.oplus.cosa/com.oplus.cosa.gamemanagersdk.HyperBoostService >/dev/null 2>&1
pm enable com.oplus.cosa/com.oplus.cosa.gpalibrary.service.GPAService >/dev/null 2>&1
echo "还原完成"

echo "== [6] powercfg gen =="
sh $D/lib/powercfg.sh gen
echo "sh: $(head -3 /data/powercfg.sh 2>/dev/null | tr '\n' ' ')"
echo "json: $(cat /data/powercfg.json 2>/dev/null | tr -d '\n ' | cut -c1-60)"
rm -f /data/powercfg.sh /data/powercfg.json
echo "test artifacts removed"

echo "== [7] daemon 18s (fps+cleanup集成) =="
rm -f /data/local/tmp/perfmtk_mt6991.log
echo 0 > $D/config/cleanup_enabled
timeout 18 sh $D/bin/perfmtk_daemon 2>&1 &
sleep 18
grep -E "daemon:|touch:|FPS" /data/local/tmp/perfmtk_mt6991.log | head -8
echo 1 > $D/config/cleanup_enabled

echo "== [8] validate =="
sh $D/bin/perfmtk --validate balanced
sh $D/bin/perfmtk --validate performance
echo "== DONE-X =="
