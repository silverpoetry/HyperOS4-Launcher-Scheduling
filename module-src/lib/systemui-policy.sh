#!/system/bin/sh

# SystemUI policy is scoped to Launcher transitions. Critical rendering work
# keeps a migration-capable high-performance set; ART maintenance work uses a
# separate performance tier so it cannot monopolize prime beside Raster.
systemui_policy_enabled() {
  config_enabled "$SYSTEMUI_POLICY_STATE_FILE"
}

read_systemui_placement() {
  local file="$1" default="$2"
  read_thread_file "$file"
  case "$THREAD_FILE_VALUE" in 1|2|3|4|5|6) ;; *) THREAD_FILE_VALUE="$default" ;; esac
}

increment_systemui_serial() {
  local value
  read_thread_file "$SYSTEMUI_SERIAL_FILE"; value="$THREAD_FILE_VALUE"
  case "$value" in ''|*[!0-9]*) value=0 ;; esac
  value=$((value + 1))
  printf '%s\n' "$value" >"$SYSTEMUI_SERIAL_FILE"
  printf '%s' "$value"
}

restore_systemui_threads() {
  local reason="${1:-restore}"
  if [ -x "$SYSTEMUI_THREADCTL" ] && [ -r "$SYSTEMUI_STATE_FILE" ]; then
    "$SYSTEMUI_THREADCTL" restore "$SYSTEMUI_STATE_FILE" >/dev/null 2>&1 ||
      thread_log "systemui-restore-failed reason=$reason"
  fi
  rm -f "$SYSTEMUI_STATE_FILE" "$SYSTEMUI_STATE_FILE.lock" \
    "$SYSTEMUI_PID_FILE" "$SYSTEMUI_SERIAL_FILE"
}

apply_systemui_transition_policy() {
  local reason="$1" systemui_pid previous_pid critical maintenance serial timeout
  if ! systemui_policy_enabled || [ ! -x "$SYSTEMUI_THREADCTL" ]; then
    restore_systemui_threads policy-disabled
    return 0
  fi
  systemui_pid="$(pidof com.android.systemui 2>/dev/null)"
  systemui_pid=${systemui_pid%% *}
  [ -n "$systemui_pid" ] && [ -d "/proc/$systemui_pid/task" ] || return 0
  read_thread_file "$SYSTEMUI_PID_FILE"; previous_pid="$THREAD_FILE_VALUE"
  [ -z "$previous_pid" ] || [ "$previous_pid" = "$systemui_pid" ] ||
    restore_systemui_threads systemui-restarted

  derive_launcher_masks
  read_systemui_placement "$SYSTEMUI_CRITICAL_PLACEMENT_FILE" 2
  critical="$THREAD_FILE_VALUE"
  read_systemui_placement "$SYSTEMUI_MAINTENANCE_PLACEMENT_FILE" 6
  maintenance="$THREAD_FILE_VALUE"
  if "$SYSTEMUI_THREADCTL" apply "$systemui_pid" "$SYSTEMUI_STATE_FILE" \
      "$THREAD_PERF_MASK" "$THREAD_MID_MASK" "$THREAD_LITTLE_MASK" \
      "$THREAD_RENDER_MASK" "$THREAD_PRIME_MASK" "$THREAD_SECONDARY_MASK" \
      "$critical" "$maintenance" >/dev/null 2>&1; then
    printf '%s\n' "$systemui_pid" >"$SYSTEMUI_PID_FILE"
    serial="$(increment_systemui_serial)"
    thread_log "systemui-policy serial=$serial reason=$reason critical=$critical maintenance=$maintenance"
  else
    thread_log "systemui-policy-failed pid=$systemui_pid reason=$reason"
    return 0
  fi

  timeout="$(read_bounded_number "$SYSTEMUI_TIMEOUT_FILE" 2000 300 5000)"
  (
    sleep_milliseconds "$timeout"
    read_thread_file "$SYSTEMUI_SERIAL_FILE"
    [ "$THREAD_FILE_VALUE" = "$serial" ] || exit 0
    restore_systemui_threads timeout
    thread_log "systemui-policy-restored serial=$serial reason=timeout"
  ) &
}

trigger_transition_thread_policies() {
  local launcher_pid="$1" reason="$2"
  trigger_launcher_thread_boost "$launcher_pid" "$reason"
  apply_systemui_transition_policy "$reason"
}
