#!/system/bin/sh
echo "== [1] WebUI 温度读取 (loadStatus 同款) =="
for z in /sys/class/thermal/thermal_zone*; do
  t=$(cat $z/type 2>/dev/null); [ -n "$t" ] || continue
  case "$t" in cpu-*|soc-*|gpu*|apu*) echo "$t $(cat $z/temp 2>/dev/null)";; esac
done | sort | head -8
echo "== [2] WebUI 帧率读取 (awk 同款) =="
awk 'NR>1 && $5>=30 && $4>0 { r=$4/$5; if (low=="" || r<low) low=r } END { if (low=="") print "-1"; else printf "%.0f", low*100 }' /sys/kernel/fpsgo/fstb/fpsgo_status
echo "== [3] zip 解压 + webroot =="
adb_exit=0
echo "== DONE-V6 =="
