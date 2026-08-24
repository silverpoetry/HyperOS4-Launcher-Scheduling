#!/system/bin/sh

# Daemon entrypoint. Policy implementation lives in lib/ and is sourced once;
# the split adds no resident process and no polling loop.
MODDIR=${0%/*}

. "$MODDIR/lib/config.sh"
. "$MODDIR/lib/runtime.sh"
. "$MODDIR/lib/topology.sh"
. "$MODDIR/lib/source-guard.sh"
. "$MODDIR/lib/launcher-policy.sh"
. "$MODDIR/lib/systemui-policy.sh"
. "$MODDIR/lib/frequency-policy.sh"
. "$MODDIR/lib/process-policy.sh"
. "$MODDIR/lib/state-machine.sh"
. "$MODDIR/lib/events.sh"

promote_controller_process
initialize_configuration || exit 1
claim_service_instance || exit 0
trap 'stop_source_guard; release_service_instance' EXIT HUP INT TERM
cleanup_stale_daemons
rm -rf "$SOURCE_RUNTIME_DIR"
mkdir -p "$SOURCE_RUNTIME_DIR" || exit 1
chmod 0700 "$SOURCE_RUNTIME_DIR" 2>/dev/null
echo $$ >"$PID_FILE"
acknowledge_reload
restore_frequency_state_quiet
restore_launcher_threads
restore_systemui_threads startup

: >"$LOG_FILE"
chmod 0644 "$LOG_FILE" 2>/dev/null
exec >>"$LOG_FILE" 2>&1

MODULE_VERSION="$(sed -n 's/^version=//p' "$MODDIR/module.prop" | head -n 1)"
echo "=== HyperOS 4 Launcher Scheduling v${MODULE_VERSION:-unknown} ==="
date 2>/dev/null || true
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
  remove_source_groups
  configure_source_groups || { log_state "source-groups-failed"; return 1; }
  start_source_guard || { log_state "source-guard-start-failed"; return 1; }

  while true; do
    acknowledge_reload
    refresh_source_guard_configuration || { log_state "source-groups-refresh-failed"; return 1; }
    read_first_line "$ENABLE_FILE"
    if [ "$READ_VALUE" != enabled ]; then
      set_mode app module-disabled
      restore_launcher_threads
      restore_systemui_threads module-disabled
      source_guard_command disable >/dev/null 2>&1 || true
      sleep 2
      continue
    fi

    launcher_pid="$(pidof com.miui.home 2>/dev/null)"
    launcher_pid=${launcher_pid%% *}
    if [ -z "$launcher_pid" ]; then
      set_mode app launcher-not-running
      restore_systemui_threads launcher-not-running
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
