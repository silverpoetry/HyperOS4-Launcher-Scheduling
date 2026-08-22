#!/system/bin/sh

MODDIR=${0%/*}
PUBLIC_LOG=/data/local/tmp/hyperos4-recents-source-app-yield.log
PIDFILE="$MODDIR/daemon.pid"
GENFILE="$MODDIR/boost.generation"
STATEFILE="$MODDIR/state"
LOGCAT=/system/bin/logcat
SUPPRESS_SECONDS=1
SOURCEFILE="$MODDIR/source-app"
RESUME_TOKENFILE="$MODDIR/resume-token"
WALLPAPER_GROUPFILE="$MODDIR/wallpaper-groups"
MIMD_GROUPFILE="$MODDIR/mimd-groups"

cleanup_stale_processes() {
  local pid args process_list
  process_list="$MODDIR/processes.$$"
  ps -A -o PID,ARGS >"$process_list" 2>/dev/null
  while read -r pid args; do
    [ "$pid" = "$$" ] && continue
    case "$args" in
      *"$MODDIR/service.sh"*|*"logcat -b events -v brief -T 1 -s wm_on_resume_called:I"*|*"logcat -b main -v raw -T 1 --pid="*"onOverviewToggle is_home_and_overview_same=true"*)
        kill -9 "$pid" 2>/dev/null
        ;;
    esac
  done <"$process_list"
  rm -f "$process_list"
}

cleanup_stale_processes

: >"$PUBLIC_LOG"
chmod 0644 "$PUBLIC_LOG" 2>/dev/null
exec >>"$PUBLIC_LOG" 2>&1
echo "=== HyperOS 4 Recents Source-App Yield v1.1 ==="
date 2>/dev/null || true
echo "daemon_pid=$$"
echo $$ >"$PIDFILE"
[ -f "$STATEFILE" ] || echo enabled >"$STATEFILE"

case "$(getprop ro.mi.os.version.name)" in
  OS4*) ;;
  *)
    echo "SKIP: HyperOS 4 is required"
    exit 0
    ;;
esac

# The monitor is part of the background workload. Keep it and every helper it
# spawns away from the performance cores used by the Recents transition.
echo $$ >/dev/cpuset/background/cgroup.procs 2>/dev/null
echo $$ >/dev/cpuctl/background/cgroup.procs 2>/dev/null
rm -f "$SOURCEFILE" "$SOURCEFILE.tmp" "$RESUME_TOKENFILE"

CURRENT_LAUNCHER_PID=""
WALLPAPER_PIDS=""
IME_PACKAGE=""
IME_PIDS=""
MIMD_PIDS=""
WALLPAPER_CPUSET_ORIGINAL=""
WALLPAPER_CPU_ORIGINAL=""
MIMD_CPUSET_ORIGINAL=""
MIMD_CPU_ORIGINAL=""
CGROUP_RESULT=""
NOW_CS=0
SUPPRESSED_PID=""
SUPPRESSED_UID=""
SUPPRESSED_NAME=""
SUPPRESSED_TOKEN=""

read_uptime_cs() {
  local uptime seconds fraction
  IFS=' ' read -r uptime _ </proc/uptime
  seconds=${uptime%.*}
  fraction=${uptime#*.}
  fraction=${fraction%${fraction#??}}
  case "$fraction" in
    '') fraction=0 ;;
    ?) fraction="${fraction}0" ;;
  esac
  NOW_CS=$((seconds * 100 + fraction))
}

read_controller_group() {
  local pid="$1"
  local controller="$2"
  local hierarchy controllers path
  CGROUP_RESULT=""
  [ -r "/proc/$pid/cgroup" ] || return 0
  while IFS=: read -r hierarchy controllers path; do
    case ",$controllers," in
      *",$controller,"*)
        CGROUP_RESULT="$path"
        return 0
        ;;
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

capture_wallpaper_groups() {
  local pid
  [ -n "$WALLPAPER_CPUSET_ORIGINAL" ] && return 0
  if [ -r "$WALLPAPER_GROUPFILE" ]; then
    read -r WALLPAPER_CPUSET_ORIGINAL WALLPAPER_CPU_ORIGINAL <"$WALLPAPER_GROUPFILE"
    return 0
  fi
  for pid in $WALLPAPER_PIDS; do
    read_controller_group "$pid" cpuset
    WALLPAPER_CPUSET_ORIGINAL="$CGROUP_RESULT"
    read_controller_group "$pid" cpu
    WALLPAPER_CPU_ORIGINAL="$CGROUP_RESULT"
    printf '%s %s\n' "$WALLPAPER_CPUSET_ORIGINAL" "$WALLPAPER_CPU_ORIGINAL" >"$WALLPAPER_GROUPFILE"
    return 0
  done
}

capture_mimd_groups() {
  local pid
  [ -n "$MIMD_CPUSET_ORIGINAL" ] && return 0
  if [ -r "$MIMD_GROUPFILE" ]; then
    read -r MIMD_CPUSET_ORIGINAL MIMD_CPU_ORIGINAL <"$MIMD_GROUPFILE"
    return 0
  fi
  for pid in $MIMD_PIDS; do
    read_controller_group "$pid" cpuset
    MIMD_CPUSET_ORIGINAL="$CGROUP_RESULT"
    read_controller_group "$pid" cpu
    MIMD_CPU_ORIGINAL="$CGROUP_RESULT"
    printf '%s %s\n' "$MIMD_CPUSET_ORIGINAL" "$MIMD_CPU_ORIGINAL" >"$MIMD_GROUPFILE"
    return 0
  done
}

move_process_group() {
  local pid="$1"
  local cpuset_group="$2"
  local cpu_group="$3"
  [ -d "/proc/$pid" ] || return 0
  echo "$pid" >"/dev/cpuset/$cpuset_group/cgroup.procs" 2>/dev/null ||
    echo "FAIL cpuset pid=$pid group=$cpuset_group"
  echo "$pid" >"/dev/cpuctl/$cpu_group/cgroup.procs" 2>/dev/null ||
    echo "FAIL cpuctl pid=$pid group=$cpu_group"
}

refresh_protected_apps() {
  local ime_setting
  WALLPAPER_PIDS="$(pidof com.miui.miwallpaper 2>/dev/null)"
  ime_setting="$(settings get secure default_input_method 2>/dev/null)"
  IME_PACKAGE=${ime_setting%%/*}
  IME_PIDS=""
  [ -n "$IME_PACKAGE" ] && [ "$IME_PACKAGE" != "null" ] &&
    IME_PIDS="$(pidof "$IME_PACKAGE" 2>/dev/null)"
  capture_wallpaper_groups
}

refresh_mimd() {
  MIMD_PIDS="$(pidof vendor.xiaomi.hardware.mimd@2.0-service 2>/dev/null)"
  capture_mimd_groups
}

watch_resumed_activities() {
  local line pid_part pid uid key first rest name eligible source_tmp token_tmp

  "$LOGCAT" -b events -v brief -T 1 -s wm_on_resume_called:I 2>/dev/null |
  while IFS= read -r line; do
    case "$line" in
      *com.miui.home*|*com.android.systemui*|*com.miui.miwallpaper*) continue ;;
    esac

    pid_part=${line#*\(}
    pid=${pid_part%%\)*}
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    [ -r "/proc/$pid/status" ] || continue

    uid=""
    name=""
    while read -r key first rest; do
      [ "$key" = "Uid:" ] && uid="$first"
      [ "$key" = "Name:" ] && name="$first"
    done <"/proc/$pid/status"

    eligible=false
    [ -n "$uid" ] && [ "$uid" -ge 10000 ] && eligible=true
    case "$line" in *com.android.settings*) eligible=true ;; esac
    $eligible || continue

    source_tmp="$SOURCEFILE.tmp.$$"
    printf '%s %s %s\n' "$pid" "$uid" "$name" >"$source_tmp"
    mv -f "$source_tmp" "$SOURCEFILE"
    read_uptime_cs
    token_tmp="$RESUME_TOKENFILE.tmp.$$"
    printf '%s:%s\n' "$NOW_CS" "$pid" >"$token_tmp"
    mv -f "$token_tmp" "$RESUME_TOKENFILE"
  done
}

is_protected_pid() {
  local pid="$1"
  local protected
  for protected in $CURRENT_LAUNCHER_PID $WALLPAPER_PIDS $IME_PIDS; do
    [ "$pid" = "$protected" ] && return 0
  done
  return 1
}

suppress_wallpaper() {
  local pid
  for pid in $WALLPAPER_PIDS; do
    move_process_group "$pid" background background
  done
}

suppress_source_app() {
  local pid uid name
  SUPPRESSED_PID=""
  SUPPRESSED_UID=""
  SUPPRESSED_NAME=""
  SUPPRESSED_TOKEN=""
  [ -r "$SOURCEFILE" ] || return 0
  read -r pid uid name <"$SOURCEFILE"
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ -d "/proc/$pid" ] || return 0
  is_protected_pid "$pid" && return 0
  move_process_group "$pid" background background
  SUPPRESSED_PID="$pid"
  SUPPRESSED_UID="$uid"
  SUPPRESSED_NAME="$name"
  SUPPRESSED_TOKEN="$(cat "$RESUME_TOKENFILE" 2>/dev/null)"
  read_uptime_cs
  echo "uptime_cs=$NOW_CS suppress-source pid=$pid uid=$uid name=$name"
}

schedule_source_reassert() {
  local generation="$1"
  local pid="$2"
  local resume_token="$3"
  local delay current current_token
  [ -n "$pid" ] && [ -n "$resume_token" ] || return 0
  (
    for delay in 0.12 0.20; do
      sleep "$delay"
      current="$(cat "$GENFILE" 2>/dev/null)"
      [ "$current" = "$generation" ] || exit 0
      current_token="$(cat "$RESUME_TOKENFILE" 2>/dev/null)"
      [ "$current_token" = "$resume_token" ] || exit 0
      [ -d "/proc/$pid" ] || exit 0
      is_protected_pid "$pid" && exit 0
      move_process_group "$pid" background background
      read_uptime_cs
      echo "uptime_cs=$NOW_CS reassert-source pid=$pid generation=$generation"
    done
  ) &
}

suppress_mimd() {
  local pid
  refresh_mimd
  for pid in $MIMD_PIDS; do
    move_process_group "$pid" background background
    read_uptime_cs
    echo "uptime_cs=$NOW_CS suppress-mimd pid=$pid"
  done
}

restore_mimd() {
  local pid
  refresh_mimd
  for pid in $MIMD_PIDS; do
    [ -d "/proc/$pid" ] || continue
    write_controller_group "$pid" /dev/cpuset "${MIMD_CPUSET_ORIGINAL:-/system-background}" ||
      echo "FAIL cpuset restore pid=$pid group=${MIMD_CPUSET_ORIGINAL:-/system-background}"
    write_controller_group "$pid" /dev/cpuctl "$MIMD_CPU_ORIGINAL" ||
      echo "FAIL cpuctl restore pid=$pid group=${MIMD_CPU_ORIGINAL:-/}"
  done
}

restore_wallpaper() {
  local pid
  for pid in $WALLPAPER_PIDS; do
    write_controller_group "$pid" /dev/cpuset "${WALLPAPER_CPUSET_ORIGINAL:-/foreground}" ||
      echo "FAIL cpuset restore pid=$pid group=${WALLPAPER_CPUSET_ORIGINAL:-/foreground}"
    write_controller_group "$pid" /dev/cpuctl "${WALLPAPER_CPU_ORIGINAL:-/foreground}" ||
      echo "FAIL cpuctl restore pid=$pid group=${WALLPAPER_CPU_ORIGINAL:-/foreground}"
  done
}

suppress_external_apps() {
  suppress_source_app
  suppress_wallpaper
  suppress_mimd
}

schedule_restore() {
  local generation="$1"
  (
    sleep "$SUPPRESS_SECONDS"
    current="$(cat "$GENFILE" 2>/dev/null)"
    if [ "$current" = "$generation" ]; then
      restore_wallpaper
      restore_mimd
      read_uptime_cs
      echo "uptime_cs=$NOW_CS restore generation=$generation"
    fi
  ) &
}

monitor_launcher() {
  local pid="$1"
  local generation=0
  local line
  local last_enter_cs=-100000
  local signal_cs complete_cs elapsed_ms

  CURRENT_LAUNCHER_PID="$pid"
  refresh_protected_apps
  read_uptime_cs
  echo "uptime_cs=$NOW_CS monitor launcher_pid=$pid"

  "$LOGCAT" -b main -v raw -T 1 --pid="$pid" \
    --regex='\[RecentsActivity\] onOverviewToggle is_home_and_overview_same=true|PassBlurWindow: on_create, window_id=0|SceneTransitionDetectorService.*SceneAnimationSignalType\.exitOverviewState' \
    -s flutter:I hyper_launcher_app:I 2>/dev/null |
  while IFS= read -r line; do
    case "$line" in
      *"[RecentsActivity] onOverviewToggle is_home_and_overview_same=true"*|*"PassBlurWindow: on_create, window_id=0"*)
        read_uptime_cs
        [ $((NOW_CS - last_enter_cs)) -lt 75 ] && continue
        last_enter_cs=$NOW_CS
        signal_cs=$NOW_CS
        generation=$((generation + 1))
        echo "$generation" >"$GENFILE"
        suppress_external_apps
        read_uptime_cs
        complete_cs=$NOW_CS
        elapsed_ms=$(( (complete_cs - signal_cs) * 10 ))
        echo "uptime_cs=$complete_cs enter generation=$generation cgroup_ms=$elapsed_ms"
        schedule_source_reassert "$generation" "$SUPPRESSED_PID" "$SUPPRESSED_TOKEN"
        schedule_restore "$generation"
        ;;
      *SceneTransitionDetectorService*SceneAnimationSignalType.exitOverviewState*)
        generation=$((generation + 1))
        echo "$generation" >"$GENFILE"
        restore_wallpaper
        restore_mimd
        read_uptime_cs
        echo "uptime_cs=$NOW_CS exit generation=$generation"
        ;;
    esac
  done

  restore_wallpaper
  restore_mimd
}

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 180 ]; do
  sleep 1
  i=$((i + 1))
done

# This listener only updates a three-field cache on activity resumes. It does
# no cgroup work and inherits the daemon's background CPU placement.
watch_resumed_activities &

while true; do
  if [ "$(cat "$STATEFILE" 2>/dev/null)" != "enabled" ]; then
    refresh_protected_apps
    restore_wallpaper
    restore_mimd
    sleep 2
    continue
  fi

  launcher_pid="$(pidof com.miui.home 2>/dev/null)"
  if [ -z "$launcher_pid" ]; then
    sleep 1
    continue
  fi

  monitor_launcher "$launcher_pid"
  sleep 1
done
