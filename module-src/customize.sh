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
[ -w /dev/cpuctl/background/cpu.shares ] || abort "! cpu shares controller is unavailable"
[ -r /sys/kernel/tracing/events/cgroup/cgroup_attach_task/id ] ||
  abort "! cgroup_attach_task tracepoint is unavailable"
[ -r /sys/kernel/tracing/events/cgroup/cgroup_attach_task/format ] ||
  abort "! cgroup_attach_task trace format is unavailable"

set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/webui.sh" 0 0 0755
set_perm "$MODPATH/bin/launcher-logwatch" 0 0 0755
set_perm "$MODPATH/bin/source-guard" 0 0 0755
set_perm_recursive "$MODPATH/lib" 0 0 0755 0644
set_perm_recursive "$MODPATH/webroot" 0 0 0755 0644

rm -f "$MODPATH/disable" "$MODPATH/remove"

ui_print "- Source-app cgroup guard: enabled"
ui_print "- Wallpaper and MIMD placement: enabled"
ui_print "- Launcher thread policy: enabled"
ui_print "- SystemUI and system_server transition policy: enabled"
ui_print "- Transition efficiency-core limit: available, disabled by default"
ui_print "- Parameters are available in the KernelSU WebUI"
