#!/system/bin/sh

module_version="$(sed -n 's/^version=//p' "$MODPATH/module.prop" | head -n 1)"
[ -n "$module_version" ] || module_version=unknown
ui_print "- Installing HyperOS 4 Launcher Scheduling v$module_version"

case "$(getprop ro.mi.os.version.name)" in
  OS4*) ;;
  *) abort "! This module requires HyperOS 4" ;;
esac

[ -d /dev/cpuset/background ] || abort "! background cpuset is unavailable"
[ -d /dev/cpuctl/background ] || abort "! background cpu controller is unavailable"

set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/thread-policy.sh" 0 0 0755
set_perm "$MODPATH/webui.sh" 0 0 0755
set_perm "$MODPATH/bin/launcher-logwatch" 0 0 0755
set_perm "$MODPATH/bin/launcher-threadctl" 0 0 0755
set_perm "$MODPATH/bin/source-affinityctl" 0 0 0755
set_perm_recursive "$MODPATH/webroot" 0 0 0755 0644

rm -f "$MODPATH/disable" "$MODPATH/remove"

ui_print "- Policy starts when Launcher takes over the remote transition"
ui_print "- Policy remains active throughout Home, Recents, and Launcher exit"
ui_print "- Source app threads are transactionally constrained to the device background CPUs"
ui_print "- Xiaomi minor-window affinity override is suspended only for the active source UID"
ui_print "- Launcher render threads use topology-derived affinity and short uclamp boosts"
ui_print "- Original wallpaper and MIMD groups are restored on exit"
ui_print "- No blur threshold, foreground polling, or broad process scan"
