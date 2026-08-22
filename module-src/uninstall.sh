#!/system/bin/sh

MODDIR=${0%/*}

kill_tree() {
  local target="$1"
  local child
  [ -d "/proc/$target" ] || return 0
  for child in $(cat "/proc/$target/task/$target/children" 2>/dev/null); do
    kill_tree "$child"
  done
  kill "$target" 2>/dev/null
}

daemon_pid="$(cat "$MODDIR/daemon.pid" 2>/dev/null)"
[ -n "$daemon_pid" ] && kill_tree "$daemon_pid"

for mimd in $(pidof vendor.xiaomi.hardware.mimd@2.0-service 2>/dev/null); do
  [ -d "/proc/$mimd" ] || continue
  echo "$mimd" >/dev/cpuset/system-background/cgroup.procs 2>/dev/null
  echo "$mimd" >/dev/cpuctl/cgroup.procs 2>/dev/null
done

for wallpaper in $(pidof com.miui.miwallpaper 2>/dev/null); do
  [ -d "/proc/$wallpaper" ] || continue
  echo "$wallpaper" >/dev/cpuset/foreground/cgroup.procs 2>/dev/null
  echo "$wallpaper" >/dev/cpuctl/foreground/cgroup.procs 2>/dev/null
done

rm -f /data/local/tmp/sheng-recents-cpu-boost-v1.log
