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
SOURCE_GROUP_FILE="$MODDIR/active-source-groups"
GESTURE_FILE="$MODDIR/gesture.active"
WALLPAPER_GROUP_FILE="$MODDIR/wallpaper-groups"
MIMD_GROUP_FILE="$MODDIR/mimd-groups"

. "$MODDIR/thread-policy.sh"

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
restore_launcher_threads
: >"$LOG_FILE"
chmod 0644 "$LOG_FILE" 2>/dev/null
exec >>"$LOG_FILE" 2>&1

echo "=== HyperOS 4 Launcher Scheduling v3.0 ==="
date 2>/dev/null || true
echo $$ >"$PID_FILE"
[ -f "$ENABLE_FILE" ] || echo enabled >"$ENABLE_FILE"
[ -f "$THREAD_POLICY_STATE_FILE" ] || echo enabled >"$THREAD_POLICY_STATE_FILE"
echo booting >"$MODE_FILE"
echo 0 >"$SERIAL_FILE"
echo 0 >"$EPOCH_FILE"
rm -f "$SOURCE_FILE" "$SOURCE_FILE.tmp" "$PENDING_SOURCE_FILE" "$PENDING_SOURCE_FILE.tmp"
rm -f "$SOURCE_GROUP_FILE" "$GESTURE_FILE"

case "$(getprop ro.mi.os.version.name)" in
  OS4*) ;;
  *) echo "SKIP: HyperOS 4 is required"; exit 0 ;;
esac

# The controller and its native log watcher stay outside Launcher performance CPUs.
echo $$ >/dev/cpuset/background/cgroup.procs 2>/dev/null
echo $$ >/dev/cpuctl/background/cgroup.procs 2>/dev/null

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
  set_mode app initial-resumed-activity
}

capture_active_source_groups() {
  local pid uid name
  rm -f "$SOURCE_GROUP_FILE"
  [ -r "$SOURCE_FILE" ] || return 0
  read -r pid uid name <"$SOURCE_FILE"
  capture_groups_once "$pid" "$SOURCE_GROUP_FILE"
}

suppress_source() {
  local pid uid name
  [ -r "$SOURCE_FILE" ] || return 0
  read -r pid uid name <"$SOURCE_FILE"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ -d "/proc/$pid" ] || return 0
  is_protected_pid "$pid" && return 0
  move_pid_to_background "$pid"
  log_state "source-yield pid=$pid uid=$uid name=$name"
}

restore_source_after_cancel() {
  local pid uid name cpuset cpu
  # Invalidate all delayed source writes before restoring the source. A task
  # that already passed its old epoch check must not win after this restore.
  increment_file "$EPOCH_FILE" >/dev/null
  [ -r "$SOURCE_FILE" ] && [ -r "$SOURCE_GROUP_FILE" ] || return 0
  read -r pid uid name <"$SOURCE_FILE"
  read -r cpuset cpu <"$SOURCE_GROUP_FILE"
  write_controller_group "$pid" /dev/cpuset "$cpuset"
  write_controller_group "$pid" /dev/cpuctl "$cpu"
  log_state "source-restored pid=$pid reason=enter-canceled"
}

restore_resumed_source_target() {
  local source_pid source_uid source_name pending_pid pending_uid pending_name cpuset cpu
  [ -r "$SOURCE_FILE" ] && [ -r "$PENDING_SOURCE_FILE" ] &&
    [ -r "$SOURCE_GROUP_FILE" ] || return 0
  read -r source_pid source_uid source_name <"$SOURCE_FILE"
  read -r pending_pid pending_uid pending_name <"$PENDING_SOURCE_FILE"
  [ "$source_pid" = "$pending_pid" ] || return 0
  read -r cpuset cpu <"$SOURCE_GROUP_FILE"
  write_controller_group "$pending_pid" /dev/cpuset "$cpuset"
  write_controller_group "$pending_pid" /dev/cpuctl "$cpu"
  log_state "target-restored pid=$pending_pid reason=resumed-source-pid"
}

apply_policy() {
  local pid
  refresh_policy_pids
  suppress_source
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
  local current
  current="$(cat "$MODE_FILE" 2>/dev/null)"

  if [ "$current" = "$next" ]; then
    [ "$next" != app ] && apply_policy
    return 0
  fi

  if [ "$current" = app ] && [ "$next" != app ]; then
    increment_file "$EPOCH_FILE" >/dev/null
    capture_active_source_groups
  fi

  echo "$next" >"$MODE_FILE"
  if [ "$next" = app ]; then
    increment_file "$EPOCH_FILE" >/dev/null
    rm -f "$GESTURE_FILE"
    restore_processes
    commit_pending_source
    rm -f "$SOURCE_GROUP_FILE"
  else
    apply_policy
  fi
  log_state "mode=$next reason=$reason"
}

schedule_source_reassert() {
  local epoch="$1"
  local source_snapshot="$2"
  local delay mode current_source
  [ -n "$source_snapshot" ] || return 0
  (
    for delay in 0.12 0.20; do
      sleep "$delay"
      [ "$(cat "$EPOCH_FILE" 2>/dev/null)" = "$epoch" ] || exit 0
      mode="$(cat "$MODE_FILE" 2>/dev/null)"
      [ "$mode" != app ] || exit 0
      current_source="$(cat "$SOURCE_FILE" 2>/dev/null)"
      [ "$current_source" = "$source_snapshot" ] || exit 0
      suppress_source
    done
  ) &
}

schedule_app_fallback() {
  local serial="$1"
  (
    sleep 2
    [ "$(cat "$SERIAL_FILE" 2>/dev/null)" = "$serial" ] || exit 0
    [ "$(cat "$MODE_FILE" 2>/dev/null)" = leaving ] || exit 0
    set_mode app resume-timeout
  ) &
}

begin_launcher_transition() {
  local epoch source_snapshot
  set_mode entering launcher-transition-start
  epoch="$(cat "$EPOCH_FILE" 2>/dev/null)"
  source_snapshot="$(cat "$SOURCE_FILE" 2>/dev/null)"
  schedule_source_reassert "$epoch" "$source_snapshot"
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
                cache_resume_package "$package" "$PENDING_SOURCE_FILE"
                restore_resumed_source_target
                serial="$(increment_file "$SERIAL_FILE")"
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
        trigger_launcher_thread_boost "$LAUNCHER_PID" overview-toggle
        begin_launcher_transition
        ;;
      *SceneTransitionDetectorService*SceneAnimationSignalType.gestureStart*)
        : >"$GESTURE_FILE"
        increment_file "$SERIAL_FILE" >/dev/null
        trigger_launcher_thread_boost "$LAUNCHER_PID" gesture-start
        begin_launcher_transition
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
