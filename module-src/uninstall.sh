#!/system/bin/sh

MODDIR=${0%/*}

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

rm -f /data/local/tmp/hyperos4-recents-source-app-yield.log
