#!/system/bin/sh

# Transition state machine. Runtime side effects are delegated to the process,
# frequency and Launcher policy layers.
commit_pending_source() {
  [ -r "$PENDING_SOURCE_FILE" ] || return 0
  mv -f "$PENDING_SOURCE_FILE" "$SOURCE_FILE"
}

set_mode() {
  local next="$1" reason="$2" current resumed_pid resumed_uid resumed_name
  read_first_line "$MODE_FILE"; current="$READ_VALUE"

  case "$next" in app|home|recents) restore_source_frequency "mode-$next" ;; esac

  if [ "$current" = "$next" ]; then
    if [ "$next" = app ]; then
      place_resumed_record_top_app "$SOURCE_FILE" stable-app-reassert
      resumed_uid=""
      [ -r "$SOURCE_FILE" ] && read -r resumed_pid resumed_uid resumed_name <"$SOURCE_FILE"
      restore_source_affinity stable-app-reassert "$resumed_uid"
    else
      apply_policy
    fi
    return 0
  fi

  if [ "$current" = app ] && [ "$next" != app ]; then
    increment_file "$EPOCH_FILE" >/dev/null
  fi

  if [ "$next" = app ]; then
    increment_file "$EPOCH_FILE" >/dev/null
    rm -f "$GESTURE_FILE"
    restore_processes
    if [ -r "$PENDING_SOURCE_FILE" ]; then
      restore_resumed_target "$reason"
    else
      restore_source_for_app_completion
    fi
    commit_pending_source
    echo "$next" >"$MODE_FILE"
    place_resumed_record_top_app "$SOURCE_FILE" stable-app-commit
    resumed_uid=""
    [ -r "$SOURCE_FILE" ] && read -r resumed_pid resumed_uid resumed_name <"$SOURCE_FILE"
    restore_source_affinity stable-app-commit "$resumed_uid"
  else
    echo "$next" >"$MODE_FILE"
    apply_policy
  fi
  log_state "mode=$next reason=$reason"
}

schedule_app_fallback() {
  local serial="$1" fallback_ms
  fallback_ms="$(read_bounded_number "$APP_FALLBACK_MS_FILE" 2000 500 5000)"
  (
    sleep_milliseconds "$fallback_ms"
    read_first_line "$SERIAL_FILE"; [ "$READ_VALUE" = "$serial" ] || exit 0
    read_first_line "$MODE_FILE"; [ "$READ_VALUE" = leaving ] || exit 0
    set_mode app resume-timeout
  ) &
}
