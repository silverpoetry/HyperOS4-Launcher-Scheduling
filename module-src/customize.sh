#!/system/bin/sh

ui_print "- Installing HyperOS 4 Recents Source-App Yield v1.0"

case "$(getprop ro.mi.os.version.name)" in
  OS4*) ;;
  *) abort "! This module requires HyperOS 4" ;;
esac

[ -x /system/bin/logcat ] || abort "! logcat is unavailable"
[ -d /dev/cpuset/background ] || abort "! background cpuset is unavailable"
[ -d /dev/cpuctl/background ] || abort "! background cpu controller is unavailable"

set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755

rm -f "$MODPATH/disable" "$MODPATH/remove"

ui_print "- Launcher thread placement and frequency policy are untouched"
ui_print "- The latest resumed source app yields at the earliest Overview toggle"
ui_print "- Launcher, SystemUI, IME and display services are protected"
ui_print "- Device-defined cgroups are used; no CPU number is hard-coded"
ui_print "- Wallpaper and Xiaomi MIMD are restored after 1000 ms when present"
ui_print "- Event listener only caches the source PID; there is no broad process scan"
