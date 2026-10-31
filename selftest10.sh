#!/system/bin/sh
export PMK_DATA_DIR=/data/local/tmp/pmk_test
export PMK_CONFIG_DIR=/data/local/tmp/pmk_test/config
D=/data/local/tmp/pmk_test
C=$D/config/app_policy.conf

echo "== [1] pm 列表解析 (WebUI 同款命令) =="
echo "用户应用: $(pm list packages -3 2>/dev/null | sed 's/^package://' | wc -l)"
echo "系统应用: $(pm list packages -s 2>/dev/null | sed 's/^package://' | wc -l)"
echo "搜索 tencent: $(pm list packages -3 2>/dev/null | sed 's/^package://' | grep -c tencent)"

echo "== [2] 全局默认 sed =="
sed -i "s/^DEFAULT_PROFILE=.*/DEFAULT_PROFILE=performance/; s/^SCREEN_OFF_PROFILE=.*/SCREEN_OFF_PROFILE=powersave/" $C
grep -E "DEFAULT_PROFILE|SCREEN_OFF_PROFILE" $C
sed -i "s/^DEFAULT_PROFILE=.*/DEFAULT_PROFILE=balanced/" $C

echo "== [3] 分配应用 (sed 删 + printf 追加) =="
PKG=$(pm list packages -3 2>/dev/null | sed 's/^package://' | grep tencent | head -1)
echo "目标包: $PKG"
sed -i "/^$PKG=/d" $C
printf '%s\n' "$PKG=performance" >> $C
grep "^$PKG=" $C
sed -i "/^$PKG=/d" $C
echo "取消后: $(grep -c "^$PKG=" $C) 条"

echo "== [4] daemon 读取新策略 =="
sed -i "/^com.tencent.mobileqq=/d" $C
printf '%s\n' "com.tencent.mobileqq=performance" >> $C
rm -f /data/local/tmp/perfmtk_mt6991.log
timeout 12 sh $D/bin/perfmtk_daemon >/dev/null 2>&1 &
sleep 12
grep -E "daemon: profile" /data/local/tmp/perfmtk_mt6991.log | head -2
sed -i "/^com.tencent.mobileqq=/d" $C
echo "== DONE-R =="
