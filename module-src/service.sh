#!/system/bin/sh

# Daemon entrypoint. Policy implementation lives in lib/ and is sourced once;
# the split adds no resident process and no polling loop.
MODDIR=${0%/*}

. "$MODDIR/lib/config.sh"
. "$MODDIR/lib/runtime.sh"
. "$MODDIR/lib/topology.sh"
. "$MODDIR/lib/launcher-policy.sh"
. "$MODDIR/lib/frequency-policy.sh"
. "$MODDIR/lib/process-policy.sh"
. "$MODDIR/lib/state-machine.sh"
. "$MODDIR/lib/events.sh"

initialize_configuration
cleanup_stale_daemons
restore_frequency_state_quiet
[ -x "$SOURCE_AFFINITYCTL" ] && [ -r "$SOURCE_AFFINITY_STATE" ] &&
  "$SOURCE_AFFINITYCTL" restore "$SOURCE_AFFINITY_STATE" >/dev/null 2>&1
restore_launcher_threads

: >"$LOG_FILE"
chmod 0644 "$LOG_FILE" 2>/dev/null
exec >>"$LOG_FILE" 2>&1

MODULE_VERSION="$(sed -n 's/^version=//p' "$MODDIR/module.prop" | head -n 1)"
echo "=== HyperOS 4 Launcher Scheduling v${MODULE_VERSION:-unknown} ==="
date 2>/dev/null || true
echo $$ >"$PID_FILE"
echo booting >"$MODE_FILE"
echo 0 >"$SERIAL_FILE"
echo 0 >"$EPOCH_FILE"
echo 0 >"$FREQ_SERIAL_FILE"
rm -f "$SOURCE_FILE" "$SOURCE_FILE.tmp" "$PENDING_SOURCE_FILE" "$PENDING_SOURCE_FILE.tmp"
rm -f "$GESTURE_FILE"

case "$(getprop ro.mi.os.version.name)" in
  OS4*) ;;
  *) echo "SKIP: HyperOS 4 is required"; exit 0 ;;
esac

# Keep the blocking controller responsive under source-app load. The native
# watcher remains blocked in logd while idle; this does not create CPU work.
echo $$ >/dev/cpuset/foreground/cgroup.procs 2>/dev/null
echo $$ >/dev/cpuctl/foreground/cgroup.procs 2>/dev/null

wait_for_boot() {
  local attempt=0
  while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$attempt" -lt 180 ]; do
    sleep 1
    attempt=$((attempt + 1))
  done
}

wait_for_final_topology() {
  local attempt=0
  # Xiaomi may publish the final background cpuset after boot_completed.
  while [ "$attempt" -lt 20 ]; do
    derive_launcher_masks
    [ "$THREAD_PERF_MASK" != "$THREAD_ALL_MASK" ] && return 0
    sleep 0.25
    attempt=$((attempt + 1))
  done
}

run_daemon() {
  local launcher_pid
  wait_for_boot
  wait_for_final_topology
  refresh_frequency_info

  while true; do
    read_first_line "$ENABLE_FILE"
    if [ "$READ_VALUE" != enabled ]; then
      set_mode app module-disabled
      restore_launcher_threads
      sleep 2
      continue
    fi

    launcher_pid="$(pidof com.miui.home 2>/dev/null)"
    launcher_pid=${launcher_pid%% *}
    if [ -z "$launcher_pid" ]; then
      set_mode app launcher-not-running
      sleep 1
      continue
    fi

    LAUNCHER_PID="$launcher_pid"
    cache_current_activity
    monitor_launcher "$launcher_pid"
    sleep 1
  done
}

run_daemon
