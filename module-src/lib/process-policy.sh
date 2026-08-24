#!/system/bin/sh

# Process discovery, source-app affinity transactions and auxiliary cgroup
# placement. State-machine transitions call this layer; it does not parse logs.
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

  for pid in $WALLPAPER_PIDS; do
    capture_groups_once "$pid" "$WALLPAPER_GROUP_FILE"
    break
  done
  for pid in $MIMD_PIDS; do
    capture_groups_once "$pid" "$MIMD_GROUP_FILE"
    break
  done
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

cache_pid_record() {
  local pid="$1" destination="$2" identity="$3" uid name key first rest record role
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ -r "/proc/$pid/status" ] || return 0
  uid=""
  name=""
  while read -r key first rest; do
    [ "$key" = Uid: ] && uid="$first"
    [ "$key" = Name: ] && name="$first"
  done <"/proc/$pid/status"
  case "$uid" in ''|*[!0-9]*) return 0 ;; esac
  [ "$uid" -ge 1000 ] || return 0
  [ -n "$identity" ] && name="$identity"
  record="$pid $uid $name"
  read_first_line "$destination"
  [ "$READ_VALUE" = "$record" ] && return 0
  printf '%s\n' "$record" >"$destination.tmp"
  mv -f "$destination.tmp" "$destination"
  role=source
  [ "$destination" = "$PENDING_SOURCE_FILE" ] && role=pending-source
  log_state "app-cached role=$role pid=$pid uid=$uid name=$name"
}

cache_resume_package() {
  local package="$1" destination="$2" pid
  case "$package" in
    com.miui.home|com.android.systemui|com.miui.miwallpaper) return 0 ;;
  esac
  pid="$(pidof "$package" 2>/dev/null)"
  pid=${pid%% *}
  cache_pid_record "$pid" "$destination" "$package"
}

cache_current_activity() {
  local resumed pid
  resumed="$(dumpsys activity activities 2>/dev/null |
    sed -n 's/.*ResumedActivity:.* u[0-9][0-9]* \([^/ ]*\).*/\1/p' |
    head -n 1)"
  if [ "$resumed" = com.miui.home ]; then
    set_mode home initial-resumed-activity
    return 0
  fi
  [ -n "$resumed" ] || return 0
  pid="$(pidof "$resumed" 2>/dev/null)"
  pid=${pid%% *}
  cache_pid_record "$pid" "$SOURCE_FILE" "$resumed"
  place_resumed_record_top_app "$SOURCE_FILE" initial-resumed-activity
  set_mode app initial-resumed-activity
}

apply_source_affinity() {
  local pid="$1" uid="$2" reason="$3" operation="${4:-apply}"
  [ -x "$SOURCE_AFFINITYCTL" ] || return 0
  if "$SOURCE_AFFINITYCTL" "$operation" "$pid" "$uid" "$SOURCE_AFFINITY_STATE"; then
    log_state "source-affinity-applied pid=$pid uid=$uid reason=$reason operation=$operation"
    return 0
  else
    log_state "source-affinity-apply-failed pid=$pid uid=$uid reason=$reason"
    return 1
  fi
}

source_yield_active() {
  local pid="$1" uid="$2" active_pid active_uid cpuset cpu
  [ -r "$SOURCE_AFFINITY_ACTIVE" ] && [ -r "$SOURCE_AFFINITY_STATE" ] || return 1
  read -r active_pid active_uid <"$SOURCE_AFFINITY_ACTIVE"
  [ "$active_pid" = "$pid" ] && [ "$active_uid" = "$uid" ] || return 1
  read_controller_group "$pid" cpuset; cpuset="$CGROUP_RESULT"
  read_controller_group "$pid" cpu; cpu="$CGROUP_RESULT"
  [ "$cpuset" = /background ] && [ "$cpu" = /background ]
}

suppress_source() {
  local pid uid name
  config_enabled "$SOURCE_POLICY_FILE" || return 0
  [ -r "$SOURCE_FILE" ] || return 0
  read -r pid uid name <"$SOURCE_FILE"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ -d "/proc/$pid" ] || return 0
  is_protected_pid "$pid" && return 0
  source_yield_active "$pid" "$uid" && return 0
  if apply_source_affinity "$pid" "$uid" source-yield yield; then
    log_state "source-yield pid=$pid uid=$uid name=$name"
  fi
}

restore_source_affinity() {
  local reason="$1" resumed_uid="$2"
  local magic active_pid active_uid original_minor target count operation
  [ -r "$SOURCE_AFFINITY_ACTIVE" ] || return 0
  if [ ! -x "$SOURCE_AFFINITYCTL" ] || [ ! -r "$SOURCE_AFFINITY_STATE" ]; then
    rm -f "$SOURCE_AFFINITY_ACTIVE"
    return 0
  fi
  operation=restore
  if [ -n "$resumed_uid" ]; then
    read -r magic active_pid active_uid original_minor target count <"$SOURCE_AFFINITY_STATE"
    case "$magic" in SAF1|SAF2|SAF3|SAF4) ;; *) active_uid= ;; esac
    [ "$active_uid" = "$resumed_uid" ] || operation=restore-no-minor
  fi
  if "$SOURCE_AFFINITYCTL" "$operation" "$SOURCE_AFFINITY_STATE"; then
    rm -f "$SOURCE_AFFINITY_ACTIVE"
    log_state "source-affinity-restored reason=$reason operation=$operation resumed_uid=$resumed_uid"
  else
    log_state "source-affinity-restore-failed reason=$reason"
  fi
}

prepare_source_affinity_cache() {
  local pid uid name magic cached_pid cached_uid minor target count
  config_enabled "$SOURCE_POLICY_FILE" || return 0
  [ -x "$SOURCE_AFFINITYCTL" ] && [ -r "$SOURCE_FILE" ] || return 0
  read -r pid uid name <"$SOURCE_FILE"
  case "$pid:$uid" in *[!0-9:]*) return 0 ;; esac
  [ -d "/proc/$pid/task" ] || return 0
  if [ -r "$SOURCE_AFFINITY_STATE" ]; then
    read -r magic cached_pid cached_uid minor target count <"$SOURCE_AFFINITY_STATE"
    [ "$magic" = SAF4 ] && [ "$cached_pid" = "$pid" ] &&
      [ "$cached_uid" = "$uid" ] && return 0
  fi
  if "$SOURCE_AFFINITYCTL" prepare "$pid" "$uid" "$SOURCE_AFFINITY_STATE" \
      >/dev/null 2>&1; then
    log_state "source-affinity-prepared pid=$pid uid=$uid name=$name"
  else
    log_state "source-affinity-prepare-failed pid=$pid uid=$uid name=$name"
  fi
}

reassert_active_source() {
  local reason="$1" pid uid
  config_enabled "$SOURCE_POLICY_FILE" || return 0
  [ -x "$SOURCE_AFFINITYCTL" ] && [ -r "$SOURCE_AFFINITY_ACTIVE" ] &&
    [ -r "$SOURCE_AFFINITY_STATE" ] || return 0
  read -r pid uid <"$SOURCE_AFFINITY_ACTIVE"
  case "$pid:$uid" in *[!0-9:]*) return 0 ;; esac
  [ -d "/proc/$pid/task" ] || return 0
  apply_source_affinity "$pid" "$uid" "$reason" reassert
}

restore_source_after_cancel() {
  local pid uid name
  increment_file "$EPOCH_FILE" >/dev/null
  [ -r "$SOURCE_FILE" ] || return 0
  read -r pid uid name <"$SOURCE_FILE"
  write_controller_group "$pid" /dev/cpuset /top-app
  write_controller_group "$pid" /dev/cpuctl /top-app
  restore_source_affinity enter-canceled "$uid"
  log_state "source-restored pid=$pid reason=enter-canceled"
}

place_resumed_record_top_app() {
  local record="$1" reason="$2" pid uid name cpuset cpu
  [ -r "$record" ] || return 0
  read -r pid uid name <"$record"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ -d "/proc/$pid" ] || return 0
  read_controller_group "$pid" cpuset; cpuset="$CGROUP_RESULT"
  read_controller_group "$pid" cpu; cpu="$CGROUP_RESULT"
  if [ "$cpuset" != /top-app ] || [ "$cpu" != /top-app ]; then
    write_controller_group "$pid" /dev/cpuset /top-app
    write_controller_group "$pid" /dev/cpuctl /top-app
    log_state "target-top-app pid=$pid reason=$reason from_cpuset=$cpuset from_cpuctl=$cpu"
  fi
}

restore_resumed_target() {
  local reason="${1:-launcher-animation-complete}"
  [ -r "$PENDING_SOURCE_FILE" ] || return 0
  place_resumed_record_top_app "$PENDING_SOURCE_FILE" "$reason"
}

hold_resumed_target_for_animation() {
  local pid uid name
  config_enabled "$SOURCE_POLICY_FILE" || return 0
  [ -r "$PENDING_SOURCE_FILE" ] || return 0
  read -r pid uid name <"$PENDING_SOURCE_FILE"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ -d "/proc/$pid" ] || return 0
  apply_source_affinity "$pid" "$uid" launcher-exit-animation replace-yield
  log_state "target-yield pid=$pid uid=$uid name=$name reason=launcher-exit-animation"
}

restore_source_for_app_completion() {
  [ -r "$SOURCE_FILE" ] || return 0
  place_resumed_record_top_app "$SOURCE_FILE" app-completion
}

apply_policy() {
  local pid
  # Source affinity state is prepared while the app is stable. The transition
  # path only applies the cached mask and moves the process cgroups.
  suppress_source
  config_enabled "$AUX_POLICY_FILE" || return 0
  refresh_policy_pids
  for pid in $WALLPAPER_PIDS $MIMD_PIDS; do
    move_pid_to_background "$pid"
  done
}

restore_processes() {
  local pid cpuset cpu
  refresh_policy_pids
  cpuset=/foreground
  cpu=/foreground
  [ -r "$WALLPAPER_GROUP_FILE" ] && read -r cpuset cpu <"$WALLPAPER_GROUP_FILE"
  for pid in $WALLPAPER_PIDS; do
    write_controller_group "$pid" /dev/cpuset "$cpuset"
    write_controller_group "$pid" /dev/cpuctl "$cpu"
  done

  cpuset=/system-background
  cpu=/
  [ -r "$MIMD_GROUP_FILE" ] && read -r cpuset cpu <"$MIMD_GROUP_FILE"
  for pid in $MIMD_PIDS; do
    write_controller_group "$pid" /dev/cpuset "$cpuset"
    write_controller_group "$pid" /dev/cpuctl "$cpu"
  done
}
