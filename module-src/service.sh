#!/system/bin/sh

MODDIR=${0%/*}
PUBLIC_LOG=/data/local/tmp/sheng-recents-cpu-boost-v1.log
PIDFILE="$MODDIR/daemon.pid"
GENFILE="$MODDIR/boost.generation"
STATEFILE="$MODDIR/state"
LOGCAT=/system/bin/logcat
SUPPRESS_SECONDS=1
SOURCEFILE="$MODDIR/source-app"

: >"$PUBLIC_LOG"
chmod 0644 "$PUBLIC_LOG" 2>/dev/null
exec >>"$PUBLIC_LOG" 2>&1
echo "=== Sheng Recents Source-App Yield v1.0 ==="
date 2>/dev/null || true
echo "daemon_pid=$$"
echo $$ >"$PIDFILE"
[ -f "$STATEFILE" ] || echo enabled >"$STATEFILE"

# The monitor is part of the background workload. Keep it and every helper it
# spawns away from the performance cores used by the Recents transition.
echo $$ >/dev/cpuset/background/cgroup.procs 2>/dev/null
echo $$ >/dev/cpuctl/background/cgroup.procs 2>/dev/null
rm -f "$SOURCEFILE" "$SOURCEFILE.tmp"

CURRENT_LAUNCHER_PID=""
WALLPAPER_PIDS=""
IME_PACKAGE=""
IME_PIDS=""
MIMD_PIDS=""

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
}

refresh_mimd() {
  MIMD_PIDS="$(pidof vendor.xiaomi.hardware.mimd@2.0-service 2>/dev/null)"
}

watch_resumed_activities() {
  local line pid_part pid uid key first rest name eligible

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

    printf '%s %s %s\n' "$pid" "$uid" "$name" >"$SOURCEFILE.tmp"
    mv -f "$SOURCEFILE.tmp" "$SOURCEFILE"
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
  [ -r "$SOURCEFILE" ] || return 0
  read -r pid uid name <"$SOURCEFILE"
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ -d "/proc/$pid" ] || return 0
  is_protected_pid "$pid" && return 0
  move_process_group "$pid" background background
  echo "$(date '+%F %T' 2>/dev/null) suppress-source pid=$pid uid=$uid name=$name"
}

suppress_mimd() {
  local pid
  refresh_mimd
  for pid in $MIMD_PIDS; do
    move_process_group "$pid" background background
    echo "$(date '+%F %T' 2>/dev/null) suppress-mimd pid=$pid"
  done
}

restore_mimd() {
  local pid
  refresh_mimd
  for pid in $MIMD_PIDS; do
    [ -d "/proc/$pid" ] || continue
    echo "$pid" >/dev/cpuset/system-background/cgroup.procs 2>/dev/null ||
      echo "FAIL cpuset pid=$pid group=system-background"
    echo "$pid" >/dev/cpuctl/cgroup.procs 2>/dev/null ||
      echo "FAIL cpuctl pid=$pid group=root"
  done
}

restore_wallpaper() {
  local pid
  for pid in $WALLPAPER_PIDS; do
    move_process_group "$pid" foreground foreground
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
      echo "$(date '+%F %T' 2>/dev/null) restore generation=$generation"
    fi
  ) &
}

monitor_launcher() {
  local pid="$1"
  local generation=0
  local line
  local in_recents=0

  CURRENT_LAUNCHER_PID="$pid"
  refresh_protected_apps
  echo "$(date '+%F %T' 2>/dev/null) monitor launcher_pid=$pid"

  "$LOGCAT" -b main -v raw -T 1 --pid="$pid" \
    --regex='\[RecentsActivity\] onOverviewToggle is_home_and_overview_same=true|PassBlurWindow: on_create, window_id=0|SceneTransitionDetectorService.*SceneAnimationSignalType\.exitOverviewState' \
    -s flutter:I hyper_launcher_app:I 2>/dev/null |
  while IFS= read -r line; do
    case "$line" in
      *"[RecentsActivity] onOverviewToggle is_home_and_overview_same=true"*|*"PassBlurWindow: on_create, window_id=0"*)
        [ "$in_recents" = "1" ] && continue
        in_recents=1
        generation=$((generation + 1))
        echo "$generation" >"$GENFILE"
        suppress_external_apps
        echo "$(date '+%F %T' 2>/dev/null) enter generation=$generation"
        schedule_restore "$generation"
        ;;
      *SceneTransitionDetectorService*SceneAnimationSignalType.exitOverviewState*)
        in_recents=0
        generation=$((generation + 1))
        echo "$generation" >"$GENFILE"
        restore_wallpaper
        restore_mimd
        echo "$(date '+%F %T' 2>/dev/null) exit generation=$generation"
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
