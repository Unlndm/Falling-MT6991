#!/system/bin/sh
# 迁移逻辑独立测试(不跑整个 service.sh, 免等 boot_completed)
export MODDIR=/data/local/tmp/pmk_test
export PMK_DATA_DIR=/data/local/tmp/pmk_test
export PMK_CONFIG_DIR=/data/local/tmp/pmk_test/config
D=/data/local/tmp/pmk_test
echo "== 构造旧版 app_profiles.conf =="
cat > $D/config/app_profiles.conf <<'EOF'
DEFAULT_PROFILE=balanced
SCREEN_OFF_PROFILE=powersave
com.tencent.tmgp.sgame=performance
com.miHoYo.Yuanshen=performance
EOF
echo "app_policy.conf 现有规则: $(grep -vcE '^(#|SCREEN_OFF_PROFILE)' $D/config/app_policy.conf)"
echo "== 执行迁移块 =="
LEGACY="$MODDIR/config/app_profiles.conf"
grep -E '^[^#].*=' "$LEGACY" 2>/dev/null | grep -vE '^(DEFAULT_PROFILE|SCREEN_OFF_PROFILE)=' > "$MODDIR/config/.legacy_rules" 2>/dev/null
if [ -s "$MODDIR/config/.legacy_rules" ]; then
  while IFS= read -r line; do
    grep -qxF "$line" "$MODDIR/config/app_policy.conf" 2>/dev/null || echo "$line" >> "$MODDIR/config/app_policy.conf"
  done < "$MODDIR/config/.legacy_rules"
fi
rm -f "$MODDIR/config/.legacy_rules" 2>/dev/null
mv "$LEGACY" "$LEGACY.migrated" 2>/dev/null
echo "== 验证 =="
echo "旧文件: $([ -f $D/config/app_profiles.conf ] && echo 残留 || echo 已改名)"
echo "迁移后规则: $(grep -E '^com\.' $D/config/app_policy.conf | tr '\n' ' ')"
echo "== 再跑一次(幂等) =="
[ -f "$D/config/app_profiles.conf" ] || echo "无旧文件, 跳过"
echo "== DONE-T2 =="
