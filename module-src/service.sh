#!/system/bin/sh

MODDIR=${0%/*}
LOG_FILE=/data/local/tmp/hyperos4-launcher-scheduling.log
PID_FILE="$MODDIR/daemon.pid"
ENABLE_FILE="$MODDIR/state"
MODE_FILE="$MODDIR/launcher-mode"
SERIAL_FILE="$MODDIR/transition.serial"
EPOCH_FILE="$MODDIR/policy.epoch"
SOURCE_FILE="$MODDIR/source-app"
PENDING_SOURCE_FILE="$MODDIR/pending-source-app"
GESTURE_FILE="$MODDIR/gesture.active"
WALLPAPER_GROUP_FILE="$MODDIR/wallpaper-groups"
MIMD_GROUP_FILE="$MODDIR/mimd-groups"
SOURCE_AFFINITYCTL="$MODDIR/bin/source-affinityctl"
SOURCE_AFFINITY_STATE="$MODDIR/source-affinity.state"
SOURCE_POLICY_FILE="$MODDIR/source-policy.state"
AUX_POLICY_FILE="$MODDIR/aux-policy.state"
FREQ_POLICY_FILE="$MODDIR/frequency-policy.state"
FREQ_PERCENT_FILE="$MODDIR/frequency-limit-percent"
FREQ_TIMEOUT_FILE="$MODDIR/frequency-timeout-ms"
FREQ_STATE_FILE="$MODDIR/frequency-limit.active"
FREQ_INFO_FILE="$MODDIR/frequency-info"
FREQ_SERIAL_FILE="$MODDIR/frequency.serial"
APP_FALLBACK_MS_FILE="$MODDIR/app-fallback-ms"

. "$MODDIR/thread-policy.sh"

write_default() {
  [ -f "$1" ] || printf '%s\n' "$2" >"$1"
}

restore_frequency_state_quiet() {
  local policy original applied current
  [ -r "$FREQ_STATE_FILE" ] || return 0
  while read -r policy original applied; do
    [ -r "$policy/scaling_max_freq" ] || continue
    IFS= read -r current <"$policy/scaling_max_freq"
    [ "$current" = "$applied" ] && [ -w "$policy/scaling_max_freq" ] &&
      echo "$original" >"$policy/scaling_max_freq" 2>/dev/null
  done <"$FREQ_STATE_FILE"
  rm -f "$FREQ_STATE_FILE" "$FREQ_STATE_FILE.tmp"
}

write_default "$SOURCE_POLICY_FILE" enabled
write_default "$AUX_POLICY_FILE" enabled
write_default "$FREQ_POLICY_FILE" disabled
write_default "$FREQ_PERCENT_FILE" 78
write_default "$FREQ_TIMEOUT_FILE" 1500
write_default "$APP_FALLBACK_MS_FILE" 2000
write_default "$THREAD_PLACEMENT_FILE" 2
write_default "$THREAD_FENCE_PLACEMENT_FILE" 2
write_default "$THREAD_BOOST_MS_FILE" 1
write_default "$THREAD_RASTER_UCLAMP_FILE" 928
write_default "$THREAD_UI_UCLAMP_FILE" 768
write_default "$THREAD_RUST_UCLAMP_FILE" 512
write_default "$THREAD_RESMGR_UCLAMP_FILE" 384

restore_frequency_state_quiet

cleanup_stale_processes() {
  local pid args list
  list="$MODDIR/processes.$$"
  ps -A -o PID,ARGS >"$list" 2>/dev/null
  while read -r pid args; do
    [ "$pid" = "$$" ] && continue
    case "$args" in
      *"$MODDIR/service.sh"*|*launcher-logwatch*)
        kill -9 "$pid" 2>/dev/null
        ;;
    esac
  done <"$list"
  rm -f "$list"
}

cleanup_stale_processes
if [ -x "$SOURCE_AFFINITYCTL" ] && [ -r "$SOURCE_AFFINITY_STATE" ]; then
  "$SOURCE_AFFINITYCTL" restore "$SOURCE_AFFINITY_STATE" >/dev/null 2>&1
fi
restore_launcher_threads
: >"$LOG_FILE"
chmod 0644 "$LOG_FILE" 2>/dev/null
exec >>"$LOG_FILE" 2>&1

MODULE_VERSION="$(sed -n 's/^version=//p' "$MODDIR/module.prop" | head -n 1)"
echo "=== HyperOS 4 Launcher Scheduling v${MODULE_VERSION:-unknown} ==="
date 2>/dev/null || true
echo $$ >"$PID_FILE"
[ -f "$ENABLE_FILE" ] || echo enabled >"$ENABLE_FILE"
[ -f "$THREAD_POLICY_STATE_FILE" ] || echo enabled >"$THREAD_POLICY_STATE_FILE"
echo booting >"$MODE_FILE"
echo 0 >"$SERIAL_FILE"
echo 0 >"$EPOCH_FILE"
echo 0 >"$FREQ_SERIAL_FILE"
rm -f "$SOURCE_FILE" "$SOURCE_FILE.tmp" "$PENDING_SOURCE_FILE" "$PENDING_SOURCE_FILE.tmp"
rm -f "$MODDIR/active-source-groups" "$GESTURE_FILE"

case "$(getprop ro.mi.os.version.name)" in
  OS4*) ;;
  *) echo "SKIP: HyperOS 4 is required"; exit 0 ;;
esac

# The shell controller blocks on the native log reader while idle. Foreground
# placement prevents high-load apps from delaying transition completion and
# the two-second safety restore without creating any polling work.
echo $$ >/dev/cpuset/foreground/cgroup.procs 2>/dev/null
echo $$ >/dev/cpuctl/foreground/cgroup.procs 2>/dev/null

LAUNCHER_PID=""
WALLPAPER_PIDS=""
MIMD_PIDS=""
IME_PACKAGE=""
IME_PIDS=""
CGROUP_RESULT=""

log_state() {
  local monotonic rest
  read -r monotonic rest </proc/uptime
  echo "$(date '+%F %T' 2>/dev/null) mono=$monotonic $*"
}

config_enabled() {
  local value=""
  [ -r "$1" ] && IFS= read -r value <"$1"
  [ "$value" != disabled ]
}

read_bounded_number() {
  local file="$1" default="$2" minimum="$3" maximum="$4" value
  value=""
  [ -r "$file" ] && IFS= read -r value <"$file"
  case "$value" in ''|*[!0-9]*) value="$default" ;; esac
  [ "$value" -ge "$minimum" ] || value="$minimum"
  [ "$value" -le "$maximum" ] || value="$maximum"
  printf '%s' "$value"
}

sleep_milliseconds() {
  local value="$1" seconds millis
  seconds=$((value / 1000))
  millis=$((value % 1000))
  sleep "$(printf '%d.%03d' "$seconds" "$millis")"
}

next_frequency_serial() {
  local value
  value=""
  [ -r "$FREQ_SERIAL_FILE" ] && IFS= read -r value <"$FREQ_SERIAL_FILE"
  case "$value" in ''|*[!0-9]*) value=0 ;; esac
  value=$((value + 1))
  echo "$value" >"$FREQ_SERIAL_FILE"
  printf '%s' "$value"
}

restore_source_frequency() {
  local reason="$1" policy original applied current restored skipped
  next_frequency_serial >/dev/null
  [ -r "$FREQ_STATE_FILE" ] || return 0
  restored=0
  skipped=0
  while read -r policy original applied; do
    [ -r "$policy/scaling_max_freq" ] || continue
    IFS= read -r current <"$policy/scaling_max_freq"
    if [ "$current" = "$applied" ] && [ -w "$policy/scaling_max_freq" ]; then
      if echo "$original" >"$policy/scaling_max_freq" 2>/dev/null; then
        restored=$((restored + 1))
      fi
    else
      skipped=$((skipped + 1))
    fi
  done <"$FREQ_STATE_FILE"
  rm -f "$FREQ_STATE_FILE" "$FREQ_STATE_FILE.tmp"
  log_state "frequency-restored reason=$reason restored=$restored skipped=$skipped"
}

select_frequency_limit() {
  local policy="$1" target="$2" value chosen frequencies
  chosen=0
  if [ -r "$policy/scaling_available_frequencies" ]; then
    IFS= read -r frequencies <"$policy/scaling_available_frequencies"
    for value in $frequencies; do
      case "$value" in ''|*[!0-9]*) continue ;; esac
      [ "$value" -le "$target" ] || continue
      [ "$value" -le "$chosen" ] || chosen="$value"
    done
  fi
  [ "$chosen" -gt 0 ] || chosen="$target"
  printf '%s' "$chosen"
}

refresh_frequency_info() {
  local little_value policy related related_compact token policy_mask current maximum
  derive_launcher_masks
  little_value=$((0x$THREAD_LITTLE_MASK))
  : >"$FREQ_INFO_FILE.tmp"
  for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -r "$policy/related_cpus" ] || continue
    IFS= read -r related <"$policy/related_cpus"
    policy_mask="$(cpulist_to_mask "$related")"
    [ -n "$policy_mask" ] || continue
    [ $((0x$policy_mask & little_value)) -ne 0 ] || continue
    [ $((0x$policy_mask & ~little_value)) -eq 0 ] || continue
    related_compact=""
    for token in $related; do
      related_compact="${related_compact}${related_compact:+,}$token"
    done
    IFS= read -r current <"$policy/scaling_max_freq"
    IFS= read -r maximum <"$policy/cpuinfo_max_freq"
    printf '%s %s %s %s\n' "$policy" "$related_compact" "$current" "$maximum" >>"$FREQ_INFO_FILE.tmp"
  done
  mv -f "$FREQ_INFO_FILE.tmp" "$FREQ_INFO_FILE"
}

schedule_frequency_restore() {
  local serial="$1" timeout_ms
  timeout_ms="$(read_bounded_number "$FREQ_TIMEOUT_FILE" 1500 300 5000)"
  (
    sleep_milliseconds "$timeout_ms"
    [ "$(cat "$FREQ_SERIAL_FILE" 2>/dev/null)" = "$serial" ] || exit 0
    restore_source_frequency timeout
  ) &
}

apply_source_frequency() {
  local reason="$1" percent policy related recorded_current recorded_maximum
  local original target applied readback serial count
  config_enabled "$FREQ_POLICY_FILE" || return 0
  config_enabled "$SOURCE_POLICY_FILE" || return 0
  percent="$(read_bounded_number "$FREQ_PERCENT_FILE" 78 40 100)"
  [ "$percent" -lt 100 ] || return 0
  restore_source_frequency reapply
  [ -s "$FREQ_INFO_FILE" ] || refresh_frequency_info
  : >"$FREQ_STATE_FILE.tmp"
  count=0
  while read -r policy related recorded_current recorded_maximum; do
    [ -n "$policy" ] || continue
    [ -r "$policy/scaling_max_freq" ] || continue
    [ -w "$policy/scaling_max_freq" ] || continue
    IFS= read -r original <"$policy/scaling_max_freq"
    case "$original" in ''|*[!0-9]*) continue ;; esac
    target=$((original * percent / 100))
    applied="$(select_frequency_limit "$policy" "$target")"
    [ "$applied" -lt "$original" ] || continue
    echo "$applied" >"$policy/scaling_max_freq" 2>/dev/null || continue
    IFS= read -r readback <"$policy/scaling_max_freq"
    [ "$readback" = "$applied" ] || continue
    printf '%s %s %s\n' "$policy" "$original" "$applied" >>"$FREQ_STATE_FILE.tmp"
    count=$((count + 1))
  done <"$FREQ_INFO_FILE"
  if [ "$count" -eq 0 ]; then
    rm -f "$FREQ_STATE_FILE.tmp"
    log_state "frequency-limit-skipped reason=$reason percent=$percent"
    return 0
  fi
  mv -f "$FREQ_STATE_FILE.tmp" "$FREQ_STATE_FILE"
  serial="$(next_frequency_serial)"
  log_state "frequency-limited reason=$reason percent=$percent policies=$count serial=$serial"
  schedule_frequency_restore "$serial"
}

read_controller_group() {
  local pid="$1"
  local controller="$2"
  local hierarchy controllers path
  CGROUP_RESULT=""
  [ -r "/proc/$pid/cgroup" ] || return 0
  while IFS=: read -r hierarchy controllers path; do
    case ",$controllers," in
      *",$controller,"*) CGROUP_RESULT="$path"; return 0 ;;
    esac
  done <"/proc/$pid/cgroup"
}

write_controller_group() {
  local pid="$1"
  local root="$2"
  local group="$3"
  local relative target
  [ -d "/proc/$pid" ] || return 0
  relative=${group#/}
  if [ -n "$relative" ]; then
    target="$root/$relative/cgroup.procs"
  else
    target="$root/cgroup.procs"
  fi
  [ -w "$target" ] || return 1
  echo "$pid" >"$target" 2>/dev/null
}

move_pid_to_background() {
  local pid="$1"
  [ -d "/proc/$pid" ] || return 0
  echo "$pid" >/dev/cpuset/background/cgroup.procs 2>/dev/null ||
    log_state "cpuset-failed pid=$pid group=background"
  echo "$pid" >/dev/cpuctl/background/cgroup.procs 2>/dev/null ||
    log_state "cpuctl-failed pid=$pid group=background"
}

capture_groups_once() {
  local pid="$1"
  local file="$2"
  local cpuset cpu
  [ -r "$file" ] && return 0
  [ -d "/proc/$pid" ] || return 0
  read_controller_group "$pid" cpuset
  cpuset="$CGROUP_RESULT"
  read_controller_group "$pid" cpu
  cpu="$CGROUP_RESULT"
  printf '%s %s\n' "$cpuset" "$cpu" >"$file"
}

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
  local pid="$1"
  local protected pending_pid pending_uid pending_name
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
  local pid="$1"
  local destination="$2"
  local uid name key first rest record role
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ -r "/proc/$pid/status" ] || return 0
  uid=""
  name=""
  while read -r key first rest; do
    [ "$key" = "Uid:" ] && uid="$first"
    [ "$key" = "Name:" ] && name="$first"
  done <"/proc/$pid/status"
  case "$uid" in ''|*[!0-9]*) return 0 ;; esac
  [ "$uid" -ge 1000 ] || return 0
  record="$pid $uid $name"
  [ "$(cat "$destination" 2>/dev/null)" = "$record" ] && return 0
  printf '%s\n' "$record" >"$destination.tmp"
  mv -f "$destination.tmp" "$destination"
  role=source
  [ "$destination" = "$PENDING_SOURCE_FILE" ] && role=pending-source
  log_state "app-cached role=$role pid=$pid uid=$uid name=$name"
}

cache_resume_package() {
  local package="$1"
  local destination="$2"
  local pid
  case "$package" in
    com.miui.home|com.android.systemui|com.miui.miwallpaper) return 0 ;;
  esac
  pid="$(pidof "$package" 2>/dev/null)"
  pid=${pid%% *}
  cache_pid_record "$pid" "$destination"
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
  cache_pid_record "$pid" "$SOURCE_FILE"
  place_resumed_record_top_app "$SOURCE_FILE" initial-resumed-activity
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
  apply_source_affinity "$pid" "$uid" source-yield apply
  move_pid_to_background "$pid"
  log_state "source-yield pid=$pid uid=$uid name=$name"
}

apply_source_affinity() {
  local pid="$1"
  local uid="$2"
  local reason="$3"
  local operation="${4:-apply}"
  [ -x "$SOURCE_AFFINITYCTL" ] || return 0
  if "$SOURCE_AFFINITYCTL" "$operation" "$pid" "$uid" "$SOURCE_AFFINITY_STATE"; then
    log_state "source-affinity-applied pid=$pid uid=$uid reason=$reason operation=$operation"
  else
    log_state "source-affinity-apply-failed pid=$pid uid=$uid reason=$reason"
  fi
}

restore_source_after_cancel() {
  local pid uid name
  # Invalidate work from the old transition before restoring the source.
  increment_file "$EPOCH_FILE" >/dev/null
  [ -r "$SOURCE_FILE" ] || return 0
  read -r pid uid name <"$SOURCE_FILE"
  write_controller_group "$pid" /dev/cpuset /top-app
  write_controller_group "$pid" /dev/cpuctl /top-app
  restore_source_affinity enter-canceled "$uid"
  log_state "source-restored pid=$pid reason=enter-canceled"
}

restore_source_affinity() {
  local reason="$1"
  local resumed_uid="$2"
  local magic active_pid active_uid original_minor target count operation
  [ -x "$SOURCE_AFFINITYCTL" ] || return 0
  [ -r "$SOURCE_AFFINITY_STATE" ] || return 0
  operation=restore
  if [ -n "$resumed_uid" ]; then
    read -r magic active_pid active_uid original_minor target count <"$SOURCE_AFFINITY_STATE"
    [ "$magic" = SAF1 ] && [ "$active_uid" = "$resumed_uid" ] || operation=restore-no-minor
  fi
  if "$SOURCE_AFFINITYCTL" "$operation" "$SOURCE_AFFINITY_STATE"; then
    log_state "source-affinity-restored reason=$reason operation=$operation resumed_uid=$resumed_uid"
  else
    log_state "source-affinity-restore-failed reason=$reason"
  fi
}

place_resumed_record_top_app() {
  local record="$1"
  local reason="$2"
  local pid uid name cpuset cpu
  [ -r "$record" ] || return 0
  read -r pid uid name <"$record"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ -d "/proc/$pid" ] || return 0
  read_controller_group "$pid" cpuset
  cpuset="$CGROUP_RESULT"
  read_controller_group "$pid" cpu
  cpu="$CGROUP_RESULT"
  if [ "$cpuset" != /top-app ] || [ "$cpu" != /top-app ]; then
    write_controller_group "$pid" /dev/cpuset /top-app
    write_controller_group "$pid" /dev/cpuctl /top-app
    log_state "target-top-app pid=$pid reason=$reason from_cpuset=$cpuset from_cpuctl=$cpu"
  fi
}

restore_resumed_target() {
  local reason="${1:-launcher-animation-complete}"
  local pending_pid pending_uid pending_name
  [ -r "$PENDING_SOURCE_FILE" ] || return 0
  read -r pending_pid pending_uid pending_name <"$PENDING_SOURCE_FILE"

  # A resumed app becomes top-app only after Launcher finishes its exit.
  # This also repairs any transitional ActivityManager placement.
  place_resumed_record_top_app "$PENDING_SOURCE_FILE" "$reason"
}

hold_resumed_target_for_animation() {
  local pid uid name
  config_enabled "$SOURCE_POLICY_FILE" || return 0
  [ -r "$PENDING_SOURCE_FILE" ] || return 0
  read -r pid uid name <"$PENDING_SOURCE_FILE"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ -d "/proc/$pid" ] || return 0
  apply_source_affinity "$pid" "$uid" launcher-exit-animation replace
  move_pid_to_background "$pid"
  log_state "target-yield pid=$pid uid=$uid name=$name reason=launcher-exit-animation"
}

restore_source_for_app_completion() {
  local pid uid name
  [ -r "$SOURCE_FILE" ] || return 0
  read -r pid uid name <"$SOURCE_FILE"
  place_resumed_record_top_app "$SOURCE_FILE" app-completion
}

apply_policy() {
  local pid
  # SOURCE_FILE is already cached while the app is stably resumed.  Move that
  # process first so the hand-off starts on the same Launcher signal that
  # begins card motion.  Refreshing wallpaper/IME/MiMD PIDs may involve several
  # service lookups and must not sit on the source-app critical path.
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

increment_file() {
  local file="$1"
  local value
  value="$(cat "$file" 2>/dev/null)"
  case "$value" in ''|*[!0-9]*) value=0 ;; esac
  value=$((value + 1))
  echo "$value" >"$file"
  echo "$value"
}

commit_pending_source() {
  [ -r "$PENDING_SOURCE_FILE" ] || return 0
  mv -f "$PENDING_SOURCE_FILE" "$SOURCE_FILE"
}

set_mode() {
  local next="$1"
  local reason="$2"
  local current resumed_pid resumed_uid resumed_name
  current="$(cat "$MODE_FILE" 2>/dev/null)"

  case "$next" in
    app|home|recents) restore_source_frequency "mode-$next" ;;
  esac

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
    # This is deliberately last so the committed resumed app cannot retain a
    # transitional cgroup or affinity transaction.
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
  local serial="$1"
  local fallback_ms
  fallback_ms="$(read_bounded_number "$APP_FALLBACK_MS_FILE" 2000 500 5000)"
  (
    sleep_milliseconds "$fallback_ms"
    [ "$(cat "$SERIAL_FILE" 2>/dev/null)" = "$serial" ] || exit 0
    [ "$(cat "$MODE_FILE" 2>/dev/null)" = leaving ] || exit 0
    set_mode app resume-timeout
  ) &
}

monitor_launcher() {
  local line package serial
  LAUNCHER_PID="$1"
  refresh_policy_pids
  apply_launcher_base_affinity "$LAUNCHER_PID"
  log_state "monitor launcher_pid=$LAUNCHER_PID"

  "$MODDIR/bin/launcher-logwatch" 2>/dev/null |
  while IFS= read -r line; do
    [ "$(cat "$ENABLE_FILE" 2>/dev/null)" = enabled ] || continue
    case "$line" in
      *"activityResumed pkg="*)
        package=${line##*activityResumed pkg=}
        package=${package%%,*}
        package=${package%% *}
        case "$package" in
          com.miui.home)
            rm -f "$PENDING_SOURCE_FILE" "$PENDING_SOURCE_FILE.tmp"
            increment_file "$SERIAL_FILE" >/dev/null
            trigger_launcher_thread_boost "$LAUNCHER_PID" launcher-resumed
            set_mode home launcher-resumed
            ;;
          *)
            case "$(cat "$MODE_FILE" 2>/dev/null)" in
              entering|home|recents|leaving)
                # Invalidate the previous transition before transferring the
                # affinity transaction to the resumed target.
                increment_file "$EPOCH_FILE" >/dev/null
                cache_resume_package "$package" "$PENDING_SOURCE_FILE"
                hold_resumed_target_for_animation
                serial="$(increment_file "$SERIAL_FILE")"
                apply_source_frequency app-resumed
                trigger_launcher_thread_boost "$LAUNCHER_PID" app-resumed
                set_mode leaving app-resumed
                schedule_app_fallback "$serial"
                ;;
              *) cache_resume_package "$package" "$SOURCE_FILE" ;;
            esac
            ;;
        esac
        ;;
      *"onOverviewToggle is_home_and_overview_same=true"*|*"on_animation_start called type: CloseApp"*)
        increment_file "$SERIAL_FILE" >/dev/null
        apply_source_frequency launcher-transition-start
        trigger_launcher_thread_boost "$LAUNCHER_PID" overview-toggle
        set_mode entering launcher-transition-start
        ;;
      *SceneTransitionDetectorService*SceneAnimationSignalType.gestureStart*)
        # This signal is emitted when Launcher takes control and the full-screen
        # app starts becoming a card.  Yield the cached source before bookkeeping
        # or Launcher thread tuning so an active stream cannot occupy the first
        # animation frames.  Raw multi-touch contact is intentionally not used.
        apply_source_frequency launcher-transition-start
        suppress_source
        case "$line" in
          *" nativeYieldPid="*) log_state "native-yield ${line##* nativeYieldPid=}" ;;
        esac
        : >"$GESTURE_FILE"
        increment_file "$SERIAL_FILE" >/dev/null
        trigger_launcher_thread_boost "$LAUNCHER_PID" gesture-start
        set_mode entering launcher-transition-start
        ;;
      *SceneTransitionDetectorService*SceneAnimationSignalType.gestureToHome*)
        rm -f "$GESTURE_FILE"
        increment_file "$SERIAL_FILE" >/dev/null
        trigger_launcher_thread_boost "$LAUNCHER_PID" gesture-to-home
        set_mode home gesture-committed-home
        ;;
      *SceneTransitionDetectorService*enterOverviewState*)
        rm -f "$GESTURE_FILE"
        increment_file "$SERIAL_FILE" >/dev/null
        trigger_launcher_thread_boost "$LAUNCHER_PID" overview-entered
        set_mode recents overview-entered
        ;;
      *SceneTransitionDetectorService*exitOverviewState*|*SceneAnimationSignalType.openingRemoteAnimationOpen*)
        increment_file "$SERIAL_FILE" >/dev/null
        apply_source_frequency launcher-exit-start
        trigger_launcher_thread_boost "$LAUNCHER_PID" launcher-exit-start
        set_mode leaving launcher-exit-start
        ;;
      *SceneAnimationSignalType.openingRemoteAnimationClose*)
        increment_file "$SERIAL_FILE" >/dev/null
        set_mode app launcher-exit-complete
        ;;
      *SceneTransitionDetectorService*SceneAnimationSignalType.gestureToApp*)
        if [ -f "$GESTURE_FILE" ]; then
          rm -f "$GESTURE_FILE"
          increment_file "$SERIAL_FILE" >/dev/null
          restore_source_after_cancel
          trigger_launcher_thread_boost "$LAUNCHER_PID" gesture-canceled
          set_mode app launcher-transition-canceled
        fi
        ;;
      *IRecentsAnimationRunnerImplForRemoteBack*on_animation_canceled*)
        rm -f "$GESTURE_FILE"
        increment_file "$SERIAL_FILE" >/dev/null
        restore_source_after_cancel
        trigger_launcher_thread_boost "$LAUNCHER_PID" remote-back-canceled
        set_mode app launcher-transition-canceled
        ;;
    esac
  done

  set_mode app launcher-monitor-ended
}

i=0
while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$i" -lt 180 ]; do
  sleep 1
  i=$((i + 1))
done

# Xiaomi may publish the final background cpuset a few seconds after
# sys.boot_completed.  Avoid installing the temporary all-CPU topology as the
# Launcher base policy.  This wait only runs once at daemon start.
i=0
while [ "$i" -lt 20 ]; do
  derive_launcher_masks
  [ "$THREAD_PERF_MASK" != "$THREAD_ALL_MASK" ] && break
  sleep 0.25
  i=$((i + 1))
done

refresh_frequency_info

while true; do
  if [ "$(cat "$ENABLE_FILE" 2>/dev/null)" != enabled ]; then
    set_mode app module-disabled
    restore_launcher_threads
    sleep 2
    continue
  fi

  launcher_pid="$(pidof com.miui.home 2>/dev/null)"
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
