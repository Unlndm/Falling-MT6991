#!/system/bin/sh
# PerfMTK-MT6991 实机自检驱动 (su -c 运行)
export PMK_DATA_DIR=/data/local/tmp/pmk_test
export PMK_CONFIG_DIR=/data/local/tmp/pmk_test/config
export MODDIR=/data/local/tmp/pmk_test
export PATH=/system/bin:/vendor/bin:$PATH

D=/data/local/tmp/pmk_test
echo "== [1] detect =="
sh $D/lib/detect.sh gen && head -5 $D/config/device.conf
echo "== [2] validate all =="
for p in balanced performance powersave powersave+; do
  sh $D/bin/perfmtk --validate $p 2>&1 | tail -1
done
echo "== [3] status before =="
sh $D/bin/perfmtk --status 2>&1 | grep -E "policy|gpu gov|ged|cm_perf_mode|current_profile" | head -8
echo "== [4] apply performance =="
sh $D/bin/perfmtk performance && echo "rc=$?"
echo "--- readback ---"
for p in /sys/devices/system/cpu/cpufreq/policy0 /sys/devices/system/cpu/cpufreq/policy4 /sys/devices/system/cpu/cpufreq/policy7; do
  echo "$(basename $p): gov=$(cat $p/scaling_governor) max=$(cat $p/scaling_max_freq)"
done
echo "gpu gov=$(cat /sys/class/devfreq/48000000.mali/governor) boost_en=$(cat /sys/module/ged/parameters/boost_gpu_enable) upbound=$(cat /sys/module/ged/parameters/gpu_cust_upbound_freq)"
grep -E "cm_perf_mode_enable|cm_mgr_dram_opp_ceiling" /sys/kernel/cm_mgr/dbg_cm_mgr
echo "== [5] apply powersave =="
sh $D/bin/perfmtk powersave && echo "rc=$?"
echo "--- readback ---"
for p in /sys/devices/system/cpu/cpufreq/policy0 /sys/devices/system/cpu/cpufreq/policy4 /sys/devices/system/cpu/cpufreq/policy7; do
  echo "$(basename $p): gov=$(cat $p/scaling_governor) max=$(cat $p/scaling_max_freq)"
done
echo "gpu gov=$(cat /sys/class/devfreq/48000000.mali/governor) upbound=$(cat /sys/module/ged/parameters/gpu_cust_upbound_freq)"
grep -E "cm_perf_mode_enable|cm_mgr_dram_opp_ceiling" /sys/kernel/cm_mgr/dbg_cm_mgr
echo "== [6] restore balanced =="
sh $D/bin/perfmtk balanced && echo "rc=$?"
for p in /sys/devices/system/cpu/cpufreq/policy0 /sys/devices/system/cpu/cpufreq/policy4 /sys/devices/system/cpu/cpufreq/policy7; do
  echo "$(basename $p): gov=$(cat $p/scaling_governor) max=$(cat $p/scaling_max_freq)"
done
echo "gpu gov=$(cat /sys/class/devfreq/48000000.mali/governor)"
echo "== [7] thermal disable/enable =="
sh $D/bin/thermal_limit disable && echo "z14 mode: $(cat /sys/class/thermal/thermal_zone14/mode)"
sh $D/bin/thermal_limit enable && echo "z14 mode: $(cat /sys/class/thermal/thermal_zone14/mode)"
echo "== [8] log tail =="
tail -12 /data/local/tmp/perfmtk_mt6991.log 2>/dev/null
echo "== DONE-TEST =="
