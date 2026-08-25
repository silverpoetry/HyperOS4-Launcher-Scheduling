#!/system/bin/sh

configuration_state() {
  config_enabled "$1" && printf '1' || printf '0'
}

configuration_number() {
  read_bounded_number "$1" "$2" "$3" "$4"
}

write_coordinator_configuration() {
  local temporary="$COORDINATOR_CONFIG.tmp" source_pid source_uid source_package
  local current_focus initial_phase
  derive_launcher_masks
  source_pid=""; source_uid=""; source_package=""
  [ -r "$SOURCE_FILE" ] && read -r source_pid source_uid source_package <"$SOURCE_FILE"
  current_focus="$(dumpsys window 2>/dev/null |
    sed -n 's/.*mCurrentFocus=.* u[0-9][0-9]* \([^/ }]*\).*/\1/p' |
    head -n 1)"
  initial_phase=app
  if [ "$current_focus" = com.miui.home ]; then
    if [ -n "$source_package" ]; then initial_phase=recents; else initial_phase=home; fi
  fi
  {
    printf 'source_enabled=%s\n' "$(configuration_state "$SOURCE_POLICY_FILE")"
    printf 'initial_source=%s\n' "$source_package"
    printf 'initial_phase=%s\n' "$initial_phase"
    printf 'launcher_enabled=%s\n' "$(configuration_state "$THREAD_POLICY_STATE_FILE")"
    printf 'systemui_enabled=%s\n' "$(configuration_state "$SYSTEMUI_POLICY_STATE_FILE")"
    printf 'system_server_enabled=%s\n' "$(configuration_state "$SYSTEM_SERVER_POLICY_STATE_FILE")"
    printf 'auxiliary_enabled=%s\n' "$(configuration_state "$AUX_POLICY_FILE")"
    printf 'frequency_enabled=%s\n' "$(configuration_state "$FREQ_POLICY_FILE")"
    printf 'visual_quiet_ms=%s\n' "$(configuration_number "$VISUAL_QUIET_TIMEOUT_FILE" 450 200 1000)"
    printf 'fallback_ms=%s\n' "$(configuration_number "$APP_COMPLETION_TIMEOUT_FILE" 2000 500 5000)"
    printf 'reassert_ms=%s\n' "$(configuration_number "$POLICY_REASSERT_INTERVAL_FILE" 20 10 100)"
    printf 'frequency_percent=%s\n' "$(configuration_number "$FREQ_PERCENT_FILE" 78 40 100)"
    printf 'mask_1=%s\n' "$THREAD_PERF_MASK"
    printf 'mask_2=%s\n' "$THREAD_MID_MASK"
    printf 'mask_3=%s\n' "$THREAD_RENDER_MASK"
    printf 'mask_4=%s\n' "$THREAD_PRIME_MASK"
    printf 'mask_5=%s\n' "$THREAD_LITTLE_MASK"
    printf 'mask_6=%s\n' "$THREAD_SECONDARY_MASK"
    printf 'mask_7=%s\n' "$THREAD_BACKGROUND_MASK"
    printf 'mask_8=%s\n' "$THREAD_LITTLE_SPARE_MASK"
    printf 'launcher_placement=%s\n' "$(configuration_number "$THREAD_PLACEMENT_FILE" 2 1 8)"
    printf 'raster_placement=%s\n' "$(configuration_number "$THREAD_RASTER_PLACEMENT_FILE" 4 1 8)"
    printf 'resmgr_placement=%s\n' "$(configuration_number "$THREAD_RESMGR_PLACEMENT_FILE" 2 1 8)"
    printf 'fence_placement=%s\n' "$(configuration_number "$THREAD_FENCE_PLACEMENT_FILE" 2 1 8)"
    printf 'systemui_critical_placement=%s\n' "$(configuration_number "$SYSTEMUI_CRITICAL_PLACEMENT_FILE" 2 1 8)"
    printf 'systemui_maintenance_placement=%s\n' "$(configuration_number "$SYSTEMUI_MAINTENANCE_PLACEMENT_FILE" 6 1 8)"
    printf 'system_server_critical_placement=%s\n' "$(configuration_number "$SYSTEM_SERVER_CRITICAL_PLACEMENT_FILE" 2 1 8)"
    printf 'system_server_snapshot_placement=%s\n' "$(configuration_number "$SYSTEM_SERVER_SNAPSHOT_PLACEMENT_FILE" 6 1 8)"
    printf 'uclamp_raster=%s\n' "$(configuration_number "$THREAD_RASTER_UCLAMP_FILE" 928 0 1024)"
    printf 'uclamp_ui=%s\n' "$(configuration_number "$THREAD_UI_UCLAMP_FILE" 768 0 1024)"
    printf 'uclamp_rust=%s\n' "$(configuration_number "$THREAD_RUST_UCLAMP_FILE" 512 0 1024)"
    printf 'uclamp_resmgr=%s\n' "$(configuration_number "$THREAD_RESMGR_UCLAMP_FILE" 384 0 1024)"
    printf 'status_path=%s\n' "$COORDINATOR_STATUS"
    printf 'mode_path=%s\n' "$MODE_FILE"
    printf 'serial_path=%s\n' "$SERIAL_FILE"
  } >"$temporary" || return 1
  mv -f "$temporary" "$COORDINATOR_CONFIG"
}

run_transition_coordinator() {
  write_coordinator_configuration || return 1
  "$COORDINATOR" "$COORDINATOR_CONFIG"
}
