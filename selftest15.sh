#!/system/bin/sh
echo "== 升级判定 gate 测试 =="
rm -rf /data/adb/modules/perfmtk-mt6991 2>/dev/null
mkdir -p /data/adb/modules/perfmtk-mt6991/config
echo "A) 空 config 目录(残留壳): $(test -s /data/adb/modules/perfmtk-mt6991/config/device.conf && echo 弹升级 || echo 不弹,走功能选择) (应不弹)"
echo "B) 有 device.conf(真安装): "
echo "DEVICE=OP60EDL1" > /data/adb/modules/perfmtk-mt6991/config/device.conf
echo "   $(test -s /data/adb/modules/perfmtk-mt6991/config/device.conf && echo 弹升级 || echo 不弹) (应弹)"
rm -rf /data/adb/modules/perfmtk-mt6991
echo "== 弹窗 hidden 覆盖检查 =="
grep -n "modal-back\[hidden\]" /data/local/tmp/pmk_test/webroot/glass.css 2>/dev/null || echo "(需先推送模块)"
echo "== DONE-W2 =="
