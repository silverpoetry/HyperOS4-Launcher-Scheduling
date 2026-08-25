#!/system/bin/sh

MODDIR=${0%/*}

. "$MODDIR/lib/config.sh"
. "$MODDIR/lib/runtime.sh"
. "$MODDIR/lib/topology.sh"
. "$MODDIR/lib/source-guard.sh"
. "$MODDIR/lib/process-policy.sh"
. "$MODDIR/lib/coordinator.sh"

promote_controller_process
initialize_configuration || exit 1
claim_service_instance || exit 0
trap 'stop_source_guard; release_service_instance' EXIT HUP INT TERM
cleanup_stale_daemons
rm -rf "$SOURCE_RUNTIME_DIR"
mkdir -p "$SOURCE_RUNTIME_DIR" || exit 1
chmod 0700 "$SOURCE_RUNTIME_DIR" 2>/dev/null
printf '%s\n' $$ >"$PID_FILE"
acknowledge_reload

: >"$LOG_FILE"
chmod 0644 "$LOG_FILE" 2>/dev/null
exec >>"$LOG_FILE" 2>&1

MODULE_VERSION="$(sed -n 's/^version=//p' "$MODDIR/module.prop" | head -n 1)"
echo "=== HyperOS 4 Launcher Scheduling v${MODULE_VERSION:-unknown} ==="
date 2>/dev/null || true
printf '0\n' >"$SERIAL_FILE"
if [ -r "$RESTART_PHASE_CONTEXT_FILE" ] &&
   [ -r "$RESTART_SOURCE_CONTEXT_FILE" ] &&
   [ "$(sed -n '1p' "$RESTART_PHASE_CONTEXT_FILE")" = recents ]; then
  cp "$RESTART_SOURCE_CONTEXT_FILE" "$SOURCE_FILE"
  printf 'recents\n' >"$MODE_FILE"
else
  printf 'booting\n' >"$MODE_FILE"
  rm -f "$SOURCE_FILE" "$SOURCE_FILE.tmp"
fi
rm -f "$RESTART_PHASE_CONTEXT_FILE" "$RESTART_SOURCE_CONTEXT_FILE" \
  "$COORDINATOR_STATUS"

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
  while [ "$attempt" -lt 20 ]; do
    derive_launcher_masks
    [ "$THREAD_PERF_MASK" != "$THREAD_ALL_MASK" ] && return 0
    sleep 0.25
    attempt=$((attempt + 1))
  done
}

run_daemon() {
  local launcher_pid coordinator_result
  wait_for_boot
  wait_for_final_topology
  remove_source_groups
  configure_source_groups || { log_state "source-groups-failed"; return 1; }
  start_source_guard || { log_state "source-guard-start-failed"; return 1; }

  while true; do
    acknowledge_reload
    refresh_source_guard_configuration || return 1
    read_first_line "$ENABLE_FILE"
    if [ "$READ_VALUE" != enabled ]; then
      source_guard_command disable >/dev/null 2>&1 || true
      printf 'app\n' >"$MODE_FILE"
      rm -f "$COORDINATOR_STATUS"
      sleep 2
      continue
    fi

    launcher_pid="$(pidof com.miui.home 2>/dev/null)"
    launcher_pid=${launcher_pid%% *}
    if [ -z "$launcher_pid" ]; then
      printf 'app\n' >"$MODE_FILE"
      sleep 1
      continue
    fi

    source_guard_command reset-top >/dev/null 2>&1 || true
    bootstrap_current_source || true
    log_state "coordinator-start launcher_pid=$launcher_pid"
    coordinator_result=0
    run_transition_coordinator || coordinator_result=$?
    snapshot_source_guard || true
    source_guard_command reset-top >/dev/null 2>&1 || true
    rm -f "$COORDINATOR_STATUS"
    if [ "$coordinator_result" -eq 0 ]; then sleep 0.10; else sleep 1; fi
  done
}

run_daemon
