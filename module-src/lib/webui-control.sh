#!/system/bin/sh

valid_state() {
  case "$1" in enabled|disabled) return 0 ;; *) return 1 ;; esac
}

valid_number() {
  local value="$1" minimum="$2" maximum="$3"
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  [ "$value" -ge "$minimum" ] && [ "$value" -le "$maximum" ]
}

write_atomic() {
  local file="$1" value="$2" temporary="$1.new.$$"
  printf '%s\n' "$value" >"$temporary" || return 1
  mv -f "$temporary" "$file"
}

load_configuration_values() {
  CFG_MASTER="$(state_value "$ENABLE_FILE")"
  CFG_SOURCE="$(state_value "$SOURCE_POLICY_FILE")"
  CFG_SOURCE_PLACEMENT="$(number_value "$SOURCE_PLACEMENT_FILE" 7)"
  CFG_SOURCE_NICE_SUPPRESSION="$(number_value "$SOURCE_NICE_SUPPRESSION_FILE" 40)"
  CFG_AUXILIARY="$(state_value "$AUX_POLICY_FILE")"
  CFG_LAUNCHER="$(state_value "$THREAD_POLICY_STATE_FILE")"
  CFG_SYSTEMUI="$(state_value "$SYSTEMUI_POLICY_STATE_FILE")"
  CFG_FREQUENCY="$(state_value "$FREQ_POLICY_FILE" disabled)"
  CFG_FREQUENCY_PERCENT="$(number_value "$FREQ_PERCENT_FILE" 78)"
  CFG_FREQUENCY_TIMEOUT="$(number_value "$FREQ_TIMEOUT_FILE" 1500)"
  CFG_APP_COMPLETION_TIMEOUT="$(number_value "$APP_COMPLETION_TIMEOUT_FILE" 2000)"
  CFG_LAUNCHER_PLACEMENT="$(number_value "$THREAD_PLACEMENT_FILE" 2)"
  CFG_RASTER_PLACEMENT="$(number_value "$THREAD_RASTER_PLACEMENT_FILE" 4)"
  CFG_RESMGR_PLACEMENT="$(number_value "$THREAD_RESMGR_PLACEMENT_FILE" 2)"
  CFG_FENCE_PLACEMENT="$(number_value "$THREAD_FENCE_PLACEMENT_FILE" 2)"
  CFG_SYSTEMUI_CRITICAL_PLACEMENT="$(number_value "$SYSTEMUI_CRITICAL_PLACEMENT_FILE" 2)"
  CFG_SYSTEMUI_MAINTENANCE_PLACEMENT="$(number_value "$SYSTEMUI_MAINTENANCE_PLACEMENT_FILE" 6)"
  CFG_SYSTEMUI_TIMEOUT="$(number_value "$SYSTEMUI_TIMEOUT_FILE" 2000)"
  CFG_BOOST_DURATION="$(number_value "$THREAD_BOOST_MS_FILE" 1)"
  CFG_UCLAMP_RASTER="$(number_value "$THREAD_RASTER_UCLAMP_FILE" 928)"
  CFG_UCLAMP_UI="$(number_value "$THREAD_UI_UCLAMP_FILE" 768)"
  CFG_UCLAMP_RUST="$(number_value "$THREAD_RUST_UCLAMP_FILE" 512)"
  CFG_UCLAMP_RESMGR="$(number_value "$THREAD_RESMGR_UCLAMP_FILE" 384)"
}

assign_configuration_value() {
  local assignment="$1" key value
  key=${assignment%%=*}; value=${assignment#*=}
  [ "$key" != "$assignment" ] || return 2
  case "$key" in
    master) valid_state "$value" && CFG_MASTER="$value" ;;
    source) valid_state "$value" && CFG_SOURCE="$value" ;;
    source_placement) case "$value" in 5|7) CFG_SOURCE_PLACEMENT="$value" ;; *) return 2 ;; esac ;;
    source_nice_suppression) valid_number "$value" 0 40 && CFG_SOURCE_NICE_SUPPRESSION="$value" ;;
    auxiliary) valid_state "$value" && CFG_AUXILIARY="$value" ;;
    launcher) valid_state "$value" && CFG_LAUNCHER="$value" ;;
    systemui) valid_state "$value" && CFG_SYSTEMUI="$value" ;;
    frequency) valid_state "$value" && CFG_FREQUENCY="$value" ;;
    frequency_percent) valid_number "$value" 40 100 && CFG_FREQUENCY_PERCENT="$value" ;;
    frequency_timeout_ms) valid_number "$value" 300 5000 && CFG_FREQUENCY_TIMEOUT="$value" ;;
    app_completion_timeout_ms) valid_number "$value" 500 5000 && CFG_APP_COMPLETION_TIMEOUT="$value" ;;
    launcher_placement) valid_number "$value" 1 7 && CFG_LAUNCHER_PLACEMENT="$value" ;;
    raster_placement) valid_number "$value" 1 7 && CFG_RASTER_PLACEMENT="$value" ;;
    resmgr_placement) valid_number "$value" 1 7 && CFG_RESMGR_PLACEMENT="$value" ;;
    fence_placement) valid_number "$value" 1 7 && CFG_FENCE_PLACEMENT="$value" ;;
    systemui_critical_placement) valid_number "$value" 1 7 && CFG_SYSTEMUI_CRITICAL_PLACEMENT="$value" ;;
    systemui_maintenance_placement) valid_number "$value" 1 7 && CFG_SYSTEMUI_MAINTENANCE_PLACEMENT="$value" ;;
    systemui_timeout_ms) valid_number "$value" 300 5000 && CFG_SYSTEMUI_TIMEOUT="$value" ;;
    boost_duration_ms) valid_number "$value" 1 1000 && CFG_BOOST_DURATION="$value" ;;
    uclamp_raster) valid_number "$value" 0 1024 && CFG_UCLAMP_RASTER="$value" ;;
    uclamp_ui) valid_number "$value" 0 1024 && CFG_UCLAMP_UI="$value" ;;
    uclamp_rust) valid_number "$value" 0 1024 && CFG_UCLAMP_RUST="$value" ;;
    uclamp_resmgr) valid_number "$value" 0 1024 && CFG_UCLAMP_RESMGR="$value" ;;
    *) return 2 ;;
  esac
}

save_configuration() {
  local assignment
  load_configuration_values
  shift
  [ "$#" -gt 0 ] || return 2
  for assignment in "$@"; do
    assign_configuration_value "$assignment" || return 2
  done
  write_atomic "$ENABLE_FILE" "$CFG_MASTER" &&
  write_atomic "$SOURCE_POLICY_FILE" "$CFG_SOURCE" &&
  write_atomic "$SOURCE_PLACEMENT_FILE" "$CFG_SOURCE_PLACEMENT" &&
  write_atomic "$SOURCE_NICE_SUPPRESSION_FILE" "$CFG_SOURCE_NICE_SUPPRESSION" &&
  write_atomic "$AUX_POLICY_FILE" "$CFG_AUXILIARY" &&
  write_atomic "$THREAD_POLICY_STATE_FILE" "$CFG_LAUNCHER" &&
  write_atomic "$SYSTEMUI_POLICY_STATE_FILE" "$CFG_SYSTEMUI" &&
  write_atomic "$FREQ_POLICY_FILE" "$CFG_FREQUENCY" &&
  write_atomic "$FREQ_PERCENT_FILE" "$CFG_FREQUENCY_PERCENT" &&
  write_atomic "$FREQ_TIMEOUT_FILE" "$CFG_FREQUENCY_TIMEOUT" &&
  write_atomic "$APP_COMPLETION_TIMEOUT_FILE" "$CFG_APP_COMPLETION_TIMEOUT" &&
  write_atomic "$THREAD_PLACEMENT_FILE" "$CFG_LAUNCHER_PLACEMENT" &&
  write_atomic "$THREAD_RASTER_PLACEMENT_FILE" "$CFG_RASTER_PLACEMENT" &&
  write_atomic "$THREAD_RESMGR_PLACEMENT_FILE" "$CFG_RESMGR_PLACEMENT" &&
  write_atomic "$THREAD_FENCE_PLACEMENT_FILE" "$CFG_FENCE_PLACEMENT" &&
  write_atomic "$SYSTEMUI_CRITICAL_PLACEMENT_FILE" "$CFG_SYSTEMUI_CRITICAL_PLACEMENT" &&
  write_atomic "$SYSTEMUI_MAINTENANCE_PLACEMENT_FILE" "$CFG_SYSTEMUI_MAINTENANCE_PLACEMENT" &&
  write_atomic "$SYSTEMUI_TIMEOUT_FILE" "$CFG_SYSTEMUI_TIMEOUT" &&
  write_atomic "$THREAD_BOOST_MS_FILE" "$CFG_BOOST_DURATION" &&
  write_atomic "$THREAD_RASTER_UCLAMP_FILE" "$CFG_UCLAMP_RASTER" &&
  write_atomic "$THREAD_UI_UCLAMP_FILE" "$CFG_UCLAMP_UI" &&
  write_atomic "$THREAD_RUST_UCLAMP_FILE" "$CFG_UCLAMP_RUST" &&
  write_atomic "$THREAD_RESMGR_UCLAMP_FILE" "$CFG_UCLAMP_RESMGR" || return 1
  restart_daemon || return 1
  emit ok 1
}
