#!/system/bin/sh
echo "== 模拟升级: 旧配置 -> 新 MODPATH =="
OLD=/data/local/tmp/old_cfg
NEW=/data/local/tmp/new_mod
rm -rf $OLD $NEW
mkdir -p $OLD $NEW
# 旧配置含用户自定义
printf 'com.tencent.tmgp.sgame=performance\ncom.tencent.mm=balanced\n' > $OLD/app_policy.conf
echo "powersave" > $OLD/current_profile
echo "1" > $OLD/daemon_enabled
echo "0" > $OLD/vulkan_enabled
echo "用户自定规则: $(cat $OLD/app_policy.conf | tr '\n' ' ')"

echo "== [A] 保留配置分支 =="
cp -af $OLD/. $NEW/ 2>/dev/null
echo "拷贝后 NEW/app_policy: $(cat $NEW/app_policy.conf | tr '\n' ' ')"
echo "拷贝后 NEW/current_profile: $(cat $NEW/current_profile)"
echo "隐藏文件也拷贝: $([ -f $NEW/.touch_state ] || echo '(无 .touch_state, 正常)')"
# vulkan 对齐: vulkan_enabled=0 -> system.prop 全注释
printf 'ro.hwui.use_vulkan=true\ndebug.hwui.renderer=skiavk\n' > $NEW/system.prop
if [ "$(cat $NEW/vulkan_enabled)" = 1 ]; then sed -i 's/^# *//' $NEW/system.prop; else sed -i 's/^/# /' $NEW/system.prop; fi
echo "vulkan_enabled=0 -> system.prop: $(head -1 $NEW/system.prop)"

echo "== [B] 覆盖分支(默认) =="
rm -rf $NEW; mkdir -p $NEW
echo "平衡" > $NEW/current_profile
echo "全新默认配置, 旧配置未拷贝: $([ -f $NEW/app_policy.conf ] && echo 存在 || echo 不存在)"
echo "== [C] 语法 =="
sh -n /data/local/tmp/pmk_test/customize.sh && echo "customize.sh OK"
echo "== DONE-U3 =="
