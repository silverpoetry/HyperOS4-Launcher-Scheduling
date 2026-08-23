#!/system/bin/sh

MODDIR=${0%/*}

. "$MODDIR/thread-policy.sh"

kill_tree() {
  local target="$1"
  local child
  [ -d "/proc/$target" ] || return 0
  for child in $(cat "/proc/$target/task/$target/children" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -9 "$target" 2>/dev/null
}

daemon_pid="$(cat "$MODDIR/daemon.pid" 2>/dev/null)"
[ -n "$daemon_pid" ] && kill_tree "$daemon_pid"
if [ -r "$MODDIR/frequency-limit.active" ]; then
  while read -r policy original applied; do
    [ -r "$policy/scaling_max_freq" ] || continue
    IFS= read -r current <"$policy/scaling_max_freq"
    [ "$current" = "$applied" ] && [ -w "$policy/scaling_max_freq" ] &&
      echo "$original" >"$policy/scaling_max_freq" 2>/dev/null
  done <"$MODDIR/frequency-limit.active"
fi
[ -x "$MODDIR/bin/source-affinityctl" ] && [ -r "$MODDIR/source-affinity.state" ] &&
  "$MODDIR/bin/source-affinityctl" restore "$MODDIR/source-affinity.state" >/dev/null 2>&1
restore_launcher_threads

write_controller_group() {
  local pid="$1"
  local root="$2"
  local group="$3"
  local relative target
  [ -d "/proc/$pid" ] || return 0
  relative=${group#/}
  if [ -n "$relative" ]; then
    target="$root/$relative/cgroup.procs"
  else
    target="$root/cgroup.procs"
  fi
  [ -w "$target" ] && echo "$pid" >"$target" 2>/dev/null
}

MIMD_CPUSET_ORIGINAL=/system-background
MIMD_CPU_ORIGINAL=/
WALLPAPER_CPUSET_ORIGINAL=/foreground
WALLPAPER_CPU_ORIGINAL=/foreground
[ -r "$MODDIR/mimd-groups" ] &&
  read -r MIMD_CPUSET_ORIGINAL MIMD_CPU_ORIGINAL <"$MODDIR/mimd-groups"
[ -r "$MODDIR/wallpaper-groups" ] &&
  read -r WALLPAPER_CPUSET_ORIGINAL WALLPAPER_CPU_ORIGINAL <"$MODDIR/wallpaper-groups"

if [ -r "$MODDIR/source-app" ] && [ -r "$MODDIR/active-source-groups" ]; then
  read -r SOURCE_PID SOURCE_UID SOURCE_NAME <"$MODDIR/source-app"
  read -r SOURCE_CPUSET_ORIGINAL SOURCE_CPU_ORIGINAL <"$MODDIR/active-source-groups"
  write_controller_group "$SOURCE_PID" /dev/cpuset "$SOURCE_CPUSET_ORIGINAL"
  write_controller_group "$SOURCE_PID" /dev/cpuctl "$SOURCE_CPU_ORIGINAL"
fi

for mimd in $(pidof vendor.xiaomi.hardware.mimd@2.0-service 2>/dev/null); do
  [ -d "/proc/$mimd" ] || continue
  write_controller_group "$mimd" /dev/cpuset "$MIMD_CPUSET_ORIGINAL"
  write_controller_group "$mimd" /dev/cpuctl "$MIMD_CPU_ORIGINAL"
done

for wallpaper in $(pidof com.miui.miwallpaper 2>/dev/null); do
  [ -d "/proc/$wallpaper" ] || continue
  write_controller_group "$wallpaper" /dev/cpuset "$WALLPAPER_CPUSET_ORIGINAL"
  write_controller_group "$wallpaper" /dev/cpuctl "$WALLPAPER_CPU_ORIGINAL"
done

rm -f /data/local/tmp/hyperos4-launcher-scheduling.log
rm -f /data/local/tmp/hyperos4-recents-source-app-yield.log
rm -f "$MODDIR/launcher-mode" "$MODDIR/transition.serial" "$MODDIR/policy.epoch"
rm -f "$MODDIR/source-app" "$MODDIR/source-app.tmp"
rm -f "$MODDIR/pending-source-app" "$MODDIR/pending-source-app.tmp"
rm -f "$MODDIR/active-source-groups"
rm -f "$MODDIR/gesture.active"
rm -f "$MODDIR/thread-policy.state"
rm -f "$MODDIR/source-affinity.state" "$MODDIR/source-affinity.state.tmp"
rm -f "$MODDIR/frequency-limit.active" "$MODDIR/frequency-limit.active.tmp"
rm -f "$MODDIR/frequency-info" "$MODDIR/frequency-info.tmp" "$MODDIR/frequency.serial"
