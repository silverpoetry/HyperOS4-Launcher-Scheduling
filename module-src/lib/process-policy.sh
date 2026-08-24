#!/system/bin/sh

# Process discovery, source-app guard control and auxiliary process placement.
LAUNCHER_PID=""
WALLPAPER_PIDS=""
MIMD_PIDS=""
IME_PACKAGE=""
IME_PIDS=""

refresh_policy_pids() {
  local ime_setting pid
  WALLPAPER_PIDS="$(pidof com.miui.miwallpaper 2>/dev/null)"
  MIMD_PIDS="$(pidof vendor.xiaomi.hardware.mimd@2.0-service 2>/dev/null)"
  ime_setting="$(settings get secure default_input_method 2>/dev/null)"
  IME_PACKAGE=${ime_setting%%/*}
  IME_PIDS=""
  [ -n "$IME_PACKAGE" ] && [ "$IME_PACKAGE" != null ] &&
    IME_PIDS="$(pidof "$IME_PACKAGE" 2>/dev/null)"
  for pid in $WALLPAPER_PIDS; do capture_groups_once "$pid" "$WALLPAPER_GROUP_FILE"; break; done
  for pid in $MIMD_PIDS; do capture_groups_once "$pid" "$MIMD_GROUP_FILE"; break; done
}

is_protected_pid() {
  local pid="$1" protected pending_pid pending_uid pending_name
  for protected in $LAUNCHER_PID $WALLPAPER_PIDS $MIMD_PIDS $IME_PIDS; do
    [ "$pid" = "$protected" ] && return 0
  done
  if [ -r "$PENDING_SOURCE_FILE" ]; then
    read -r pending_pid pending_uid pending_name <"$PENDING_SOURCE_FILE"
    [ "$pid" = "$pending_pid" ] && return 0
  fi
  return 1
}

arm_source_record() {
  local record="$1" pid uid name
  config_enabled "$SOURCE_POLICY_FILE" || return 0
  [ -r "$record" ] || return 0
  read -r pid uid name <"$record"
  case "$pid:$uid" in *[!0-9:]*) return 0 ;; esac
  [ -d "/proc/$pid" ] || return 0
  if source_guard_command arm "$pid" "$uid"; then
    log_state "source-guard-armed pid=$pid uid=$uid name=$name"
  else
    log_state "source-guard-arm-failed pid=$pid uid=$uid name=$name"
  fi
}

activate_source_record() {
  local record="$1" reason="$2" pid uid name
  config_enabled "$SOURCE_POLICY_FILE" || return 0
  [ -r "$record" ] || return 0
  read -r pid uid name <"$record"
  case "$pid:$uid" in *[!0-9:]*) return 0 ;; esac
  [ -d "/proc/$pid" ] || return 0
  if source_guard_command activate "$pid" "$uid"; then
    log_state "source-guard-activated pid=$pid uid=$uid name=$name reason=$reason"
  else
    log_state "source-guard-activate-failed pid=$pid uid=$uid name=$name reason=$reason"
  fi
}

restore_source_record_top() {
  local record="$1" reason="$2" pid uid name
  [ -r "$record" ] || return 0
  read -r pid uid name <"$record"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  source_guard_command restore-top "$pid" >/dev/null 2>&1 || true
  log_state "source-guard-restored pid=$pid name=$name reason=$reason"
}

cache_pid_record() {
  local pid="$1" destination="$2" identity="$3" uid name key first rest record role
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ -r "/proc/$pid/status" ] || return 0
  uid=""; name=""
  while read -r key first rest; do
    [ "$key" = Uid: ] && uid="$first"
    [ "$key" = Name: ] && name="$first"
  done <"/proc/$pid/status"
  case "$uid" in ''|*[!0-9]*) return 0 ;; esac
  [ "$uid" -ge 1000 ] || return 0
  [ -n "$identity" ] && name="$identity"
  record="$pid $uid $name"
  read_first_line "$destination"
  if [ "$READ_VALUE" = "$record" ]; then
    [ "$destination" != "$SOURCE_FILE" ] || arm_source_record "$destination"
    return 0
  fi
  printf '%s\n' "$record" >"$destination.tmp"
  mv -f "$destination.tmp" "$destination"
  role=source
  [ "$destination" = "$PENDING_SOURCE_FILE" ] && role=pending-source
  log_state "app-cached role=$role pid=$pid uid=$uid name=$name"
  [ "$destination" != "$SOURCE_FILE" ] || arm_source_record "$destination"
}

cache_resume_package() {
  local package="$1" destination="$2" pid
  case "$package" in com.miui.home|com.android.systemui|com.miui.miwallpaper) return 0 ;; esac
  pid="$(pidof "$package" 2>/dev/null)"; pid=${pid%% *}
  cache_pid_record "$pid" "$destination" "$package"
}

cache_current_activity() {
  local resumed pid
  resumed="$(dumpsys activity activities 2>/dev/null |
    sed -n 's/.*ResumedActivity:.* u[0-9][0-9]* \([^/ ]*\).*/\1/p' |
    head -n 1)"
  if [ "$resumed" = com.miui.home ]; then set_mode home initial-resumed-activity; return 0; fi
  [ -n "$resumed" ] || return 0
  pid="$(pidof "$resumed" 2>/dev/null)"; pid=${pid%% *}
  cache_pid_record "$pid" "$SOURCE_FILE" "$resumed"
  write_controller_group "$pid" /dev/cpuset /top-app
  write_controller_group "$pid" /dev/cpuctl /top-app
  set_mode app initial-resumed-activity
}

suppress_source() {
  local pid uid name
  config_enabled "$SOURCE_POLICY_FILE" || return 0
  [ -r "$SOURCE_FILE" ] || return 0
  read -r pid uid name <"$SOURCE_FILE"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ -d "/proc/$pid" ] || return 0
  is_protected_pid "$pid" && return 0
  activate_source_record "$SOURCE_FILE" source-yield
}

restore_source_after_cancel() {
  increment_file "$EPOCH_FILE" >/dev/null
  restore_source_record_top "$SOURCE_FILE" enter-canceled
}

restore_resumed_target() {
  restore_source_record_top "$PENDING_SOURCE_FILE" "${1:-launcher-animation-complete}"
}

hold_resumed_target_for_animation() {
  activate_source_record "$PENDING_SOURCE_FILE" launcher-exit-animation
}

restore_source_for_app_completion() {
  restore_source_record_top "$SOURCE_FILE" app-completion
}

apply_policy() {
  local pid
  suppress_source
  config_enabled "$AUX_POLICY_FILE" || return 0
  refresh_policy_pids
  for pid in $WALLPAPER_PIDS $MIMD_PIDS; do move_pid_to_background "$pid"; done
}

restore_processes() {
  local pid cpuset cpu
  refresh_policy_pids
  cpuset=/foreground; cpu=/foreground
  [ -r "$WALLPAPER_GROUP_FILE" ] && read -r cpuset cpu <"$WALLPAPER_GROUP_FILE"
  for pid in $WALLPAPER_PIDS; do
    write_controller_group "$pid" /dev/cpuset "$cpuset"
    write_controller_group "$pid" /dev/cpuctl "$cpu"
  done
  cpuset=/system-background; cpu=/
  [ -r "$MIMD_GROUP_FILE" ] && read -r cpuset cpu <"$MIMD_GROUP_FILE"
  for pid in $MIMD_PIDS; do
    write_controller_group "$pid" /dev/cpuset "$cpuset"
    write_controller_group "$pid" /dev/cpuctl "$cpu"
  done
}
