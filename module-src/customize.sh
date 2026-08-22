#!/system/bin/sh

ui_print "- Installing Sheng Recents Source-App Yield v1.0"

DEVICE="$(getprop ro.product.device)"
ODM_DEVICE="$(getprop ro.product.odm.device)"
if [ "$DEVICE" != "sheng" ] && [ "$ODM_DEVICE" != "sheng" ]; then
  abort "! Expected Xiaomi Pad 6S Pro / sheng"
fi

[ -x /system/bin/logcat ] || abort "! logcat is unavailable"

set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755

rm -f "$MODPATH/disable" "$MODPATH/remove"

ui_print "- Launcher thread placement and frequency policy are untouched"
ui_print "- The latest resumed source app yields at the earliest Overview toggle"
ui_print "- Launcher, SystemUI, IME and display services are protected"
ui_print "- Wallpaper and Xiaomi MIMD are restored after 1000 ms"
ui_print "- Event listener only caches the source PID; there is no broad process scan"
