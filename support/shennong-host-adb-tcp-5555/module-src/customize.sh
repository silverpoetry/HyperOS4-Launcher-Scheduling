#!/system/bin/sh

ui_print "- Checking the Shennong host system"

if [ "$(getprop ro.gsid.image_running)" = "1" ]; then
  abort "! This package is for the host system, not a DSU"
fi

if [ "$(getprop ro.product.device)" != "shennong" ] && \
   [ "$(getprop ro.product.odm.device)" != "shennong" ]; then
  abort "! Expected Xiaomi 14 Pro / shennong"
fi

[ -x /data/adb/ksu/bin/resetprop ] || abort "! KernelSU resetprop is unavailable"

set_perm "$MODPATH/service.sh" 0 0 0755
rm -f "$MODPATH/disable" "$MODPATH/remove"

ui_print "- Host ADB TCP port: 5555"
ui_print "- Existing ADB authentication remains enabled"
ui_print "- No USB configuration or physical partition is changed"
