#!/system/bin/sh

handle_launcher_event() {
  local line="$1" package serial
  case "$line" in
    *"|NativeSourceSpawn|"*)
      log_state "native-source-spawn event=$line"
      ;;
    *"activityResumed pkg="*)
      package=${line##*activityResumed pkg=}
      package=${package%%,*}
      package=${package%% *}
      if [ "$package" = com.miui.home ]; then
        rm -f "$PENDING_SOURCE_FILE" "$PENDING_SOURCE_FILE.tmp"
        increment_file "$SERIAL_FILE" >/dev/null
        trigger_transition_thread_policies "$LAUNCHER_PID" launcher-resumed
        set_mode home launcher-resumed
        return 0
      fi
      read_first_line "$MODE_FILE"
      case "$READ_VALUE" in
        entering|home|recents|leaving)
          increment_file "$EPOCH_FILE" >/dev/null
          cache_resume_package "$package" "$PENDING_SOURCE_FILE"
          hold_resumed_target_for_animation
          serial="$(increment_file "$SERIAL_FILE")"
          apply_source_frequency app-resumed
          trigger_transition_thread_policies "$LAUNCHER_PID" app-resumed
          set_mode leaving app-resumed
          schedule_app_fallback "$serial"
          ;;
        *) cache_resume_package "$package" "$SOURCE_FILE" ;;
      esac
      ;;
    *"onOverviewToggle is_home_and_overview_same=true"*|*"on_animation_start called type: CloseApp"*)
      increment_file "$SERIAL_FILE" >/dev/null
      apply_source_frequency launcher-transition-start
      trigger_transition_thread_policies "$LAUNCHER_PID" overview-toggle
      set_mode entering launcher-transition-start
      ;;
    *SceneTransitionDetectorService*SceneAnimationSignalType.gestureStart*)
      # Native logwatch has already moved the whole process group before
      # emitting this event. The shell only completes state bookkeeping.
      apply_source_frequency launcher-transition-start
      case "$line" in
        *nativeAffinityStatus=0*nativeYieldCpuset=1*nativeYieldCpuctl=1*)
          # The two process-level cgroup writes succeeded. Do not scan TIDs.
          log_state "native-yield ${line##* nativeYieldPid=}"
          ;;
        *)
          # Repair a missing or partially failed native transaction.
          suppress_source
          ;;
      esac
      : >"$GESTURE_FILE"
      increment_file "$SERIAL_FILE" >/dev/null
      trigger_transition_thread_policies "$LAUNCHER_PID" gesture-start
      set_mode entering launcher-transition-start
      ;;
    *SceneTransitionDetectorService*SceneAnimationSignalType.gestureToHome*)
      rm -f "$GESTURE_FILE"
      increment_file "$SERIAL_FILE" >/dev/null
      trigger_transition_thread_policies "$LAUNCHER_PID" gesture-to-home
      set_mode home gesture-committed-home
      ;;
    *SceneTransitionDetectorService*enterOverviewState*)
      rm -f "$GESTURE_FILE"
      increment_file "$SERIAL_FILE" >/dev/null
      trigger_transition_thread_policies "$LAUNCHER_PID" overview-entered
      set_mode recents overview-entered
      ;;
    *SceneTransitionDetectorService*exitOverviewState*|*SceneAnimationSignalType.openingRemoteAnimationOpen*)
      serial="$(increment_file "$SERIAL_FILE")"
      apply_source_frequency launcher-exit-start
      trigger_transition_thread_policies "$LAUNCHER_PID" launcher-exit-start
      set_mode leaving launcher-exit-start
      [ -r "$PENDING_SOURCE_FILE" ] && schedule_app_fallback "$serial"
      ;;
    *SceneAnimationSignalType.openingRemoteAnimationClose*|*"finish_remote_transition to_home = false"*)
      increment_file "$SERIAL_FILE" >/dev/null
      set_mode app launcher-exit-complete
      ;;
    *SceneTransitionDetectorService*SceneAnimationSignalType.gestureToApp*)
      [ -f "$GESTURE_FILE" ] || return 0
      rm -f "$GESTURE_FILE"
      increment_file "$SERIAL_FILE" >/dev/null
      restore_source_after_cancel
      trigger_launcher_thread_boost "$LAUNCHER_PID" gesture-canceled
      set_mode app launcher-transition-canceled
      ;;
    *IRecentsAnimationRunnerImplForRemoteBack*on_animation_canceled*)
      rm -f "$GESTURE_FILE"
      increment_file "$SERIAL_FILE" >/dev/null
      restore_source_after_cancel
      trigger_launcher_thread_boost "$LAUNCHER_PID" remote-back-canceled
      set_mode app launcher-transition-canceled
      ;;
  esac
}

monitor_launcher() {
  local line
  LAUNCHER_PID="$1"
  refresh_policy_pids
  apply_launcher_base_affinity "$LAUNCHER_PID"
  prepare_systemui_thread_cache
  log_state "monitor launcher_pid=$LAUNCHER_PID"

  "$MODDIR/bin/launcher-logwatch" 2>/dev/null |
  while IFS= read -r line; do
    read_first_line "$ENABLE_FILE"
    [ "$READ_VALUE" = enabled ] || continue
    handle_launcher_event "$line"
  done

  set_mode app launcher-monitor-ended
}
