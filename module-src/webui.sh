#!/system/bin/sh

MODDIR=${0%/*}
LOG_FILE=/data/local/tmp/hyperos4-launcher-scheduling.log
STATE_FILE="$MODDIR/state"
THREAD_STATE_FILE="$MODDIR/thread-policy.state"
PROFILE_FILE="$MODDIR/thread-boost-profile"

emit() {
  local key="$1"
  shift
  # All values come from a single line, getprop, pidof, or fixed module state.
  # Keep status reads in-process instead of spawning one tr process per field.
  printf '%s=%s\n' "$key" "$*"
}

read_first_line() {
  local file="$1"
  local value=""
  [ -r "$file" ] && IFS= read -r value <"$file"
  printf '%s' "$value"
}

kill_tree() {
  local target="$1"
  local child
  [ -d "/proc/$target" ] || return 0
  for child in $(cat "/proc/$target/task/$target/children" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -9 "$target" 2>/dev/null || true
}

restart_daemon() {
  local daemon_pid watcher_pid
  daemon_pid="$(read_first_line "$MODDIR/daemon.pid")"
  [ -n "$daemon_pid" ] && kill_tree "$daemon_pid"
  for watcher_pid in $(pidof launcher-logwatch 2>/dev/null); do
    kill -9 "$watcher_pid" 2>/dev/null || true
  done
  sleep 1
  nohup /system/bin/sh "$MODDIR/service.sh" >/dev/null 2>&1 &
  sleep 1
}

read_proc_controller() {
  local pid="$1"
  local controller="$2"
  local hierarchy controllers path
  [ -r "/proc/$pid/cgroup" ] || return 0
  while IFS=: read -r hierarchy controllers path; do
    case ",$controllers," in
      *",$controller,"*) printf '%s' "$path"; return 0 ;;
    esac
  done <"/proc/$pid/cgroup"
}

read_allowed_list() {
  local status_file="$1"
  local key value rest
  [ -r "$status_file" ] || return 0
  while read -r key value rest; do
    [ "$key" = Cpus_allowed_list: ] && { printf '%s' "$value"; return 0; }
  done <"$status_file"
}

module_version() {
  local line
  [ -r "$MODDIR/module.prop" ] || return 0
  while IFS= read -r line; do
    case "$line" in version=*) printf '%s' "${line#version=}"; return 0 ;; esac
  done <"$MODDIR/module.prop"
}

print_status() {
  local policy thread_policy profile mode daemon_pid daemon_alive
  local launcher_pid topology all_mask perf_mask mid_mask little_mask
  local source_record source_pid source_uid source_name
  local pending_record pending_pid pending_uid pending_name

  policy="$(read_first_line "$STATE_FILE")"
  [ "$policy" = disabled ] || policy=enabled
  thread_policy="$(read_first_line "$THREAD_STATE_FILE")"
  [ "$thread_policy" = disabled ] || thread_policy=enabled
  profile="$(read_first_line "$PROFILE_FILE")"
  case "$profile" in 1|2) ;; *) profile=2 ;; esac
  mode="$(read_first_line "$MODDIR/launcher-mode")"
  [ -n "$mode" ] || mode=unknown
  daemon_pid="$(read_first_line "$MODDIR/daemon.pid")"
  daemon_alive=0
  [ -n "$daemon_pid" ] && [ -d "/proc/$daemon_pid" ] && daemon_alive=1
  launcher_pid="$(read_first_line "$MODDIR/launcher-thread-pid")"
  [ -d "/proc/$launcher_pid" ] || launcher_pid=""

  topology="$(read_first_line "$MODDIR/launcher-thread-topology")"
  read -r all_mask perf_mask mid_mask little_mask <<EOF
$topology
EOF
  [ -n "$all_mask" ] || all_mask=-
  [ -n "$perf_mask" ] || perf_mask=-
  [ -n "$mid_mask" ] || mid_mask=-
  [ -n "$little_mask" ] || little_mask=-

  source_record="$(read_first_line "$MODDIR/source-app")"
  read -r source_pid source_uid source_name <<EOF
$source_record
EOF
  pending_record="$(read_first_line "$MODDIR/pending-source-app")"
  read -r pending_pid pending_uid pending_name <<EOF
$pending_record
EOF

  emit version "$(module_version)"
  emit policy "$policy"
  emit thread_policy "$thread_policy"
  emit profile "$profile"
  emit mode "$mode"
  emit epoch "$(read_first_line "$MODDIR/policy.epoch")"
  emit transition_serial "$(read_first_line "$MODDIR/transition.serial")"
  emit daemon_pid "$daemon_pid"
  emit daemon_alive "$daemon_alive"
  emit launcher_pid "$launcher_pid"
  emit all_mask "$all_mask"
  emit perf_mask "$perf_mask"
  emit mid_mask "$mid_mask"
  emit little_mask "$little_mask"
  emit source_pid "$source_pid"
  emit source_uid "$source_uid"
  emit source_name "$source_name"
  emit pending_pid "$pending_pid"
  emit pending_uid "$pending_uid"
  emit pending_name "$pending_name"
}

print_info() {
  local launcher_pid source_record source_pid source_uid source_name
  launcher_pid="$(pidof com.miui.home 2>/dev/null)"
  launcher_pid=${launcher_pid%% *}
  source_record="$(read_first_line "$MODDIR/source-app")"
  read -r source_pid source_uid source_name <<EOF
$source_record
EOF
  emit device "$(getprop ro.product.device)"
  emit model "$(getprop ro.product.model)"
  emit os "$(getprop ro.mi.os.version.name)"
  emit android "$(getprop ro.build.version.release)"
  emit kernel "$(uname -r 2>/dev/null)"
  emit selinux "$(getenforce 2>/dev/null)"
  emit watcher_pids "$(pidof launcher-logwatch 2>/dev/null)"
  emit launcher_pid "$launcher_pid"
  emit source_cpuset "$(read_proc_controller "$source_pid" cpuset)"
  emit source_cpuctl "$(read_proc_controller "$source_pid" cpu)"
  emit source_allowed "$(read_allowed_list "/proc/$source_pid/status")"
}

print_threads() {
  local launcher_pid task tid name allowed uclamp_min
  launcher_pid="$(pidof com.miui.home 2>/dev/null)"
  launcher_pid=${launcher_pid%% *}
  [ -n "$launcher_pid" ] && [ -d "/proc/$launcher_pid/task" ] || return 0
  for task in /proc/"$launcher_pid"/task/*; do
    [ -r "$task/comm" ] || continue
    tid=${task##*/}
    IFS= read -r name <"$task/comm"
    case "$name" in
      1.raster|1.ui|rt-launcher-mai|IplrVkResMgr|IplrVkFenceWait) ;;
      *) continue ;;
    esac
    allowed="$(read_allowed_list "$task/status")"
    uclamp_min="$(awk '/^[[:space:]]*uclamp\.min[[:space:]]*:/ { print $3; exit }' "$task/sched" 2>/dev/null)"
    [ -n "$uclamp_min" ] || uclamp_min=-
    printf '%s\t%s\t%s\t%s\n' "$name" "$tid" "$allowed" "$uclamp_min"
  done
}

print_logs() {
  local count="$1"
  case "$count" in ''|*[!0-9]*) count=100 ;; esac
  [ "$count" -le 200 ] || count=200
  tail -n "$count" "$LOG_FILE" 2>/dev/null
}

case "$1" in
  status)
    print_status
    ;;
  info)
    print_info
    ;;
  threads)
    print_threads
    ;;
  logs)
    print_logs "$2"
    ;;
  diagnostics)
    echo '[status]'
    print_status
    echo
    echo '[device]'
    print_info
    echo
    echo '[threads]'
    print_threads
    echo
    echo '[recent log]'
    print_logs 120
    ;;
  set-policy)
    case "$2" in enabled|disabled) ;; *) echo 'invalid policy state' >&2; exit 2 ;; esac
    printf '%s\n' "$2" >"$STATE_FILE"
    restart_daemon
    emit ok 1
    emit message "Policy $2"
    ;;
  set-thread-policy)
    case "$2" in enabled|disabled) ;; *) echo 'invalid thread policy state' >&2; exit 2 ;; esac
    printf '%s\n' "$2" >"$THREAD_STATE_FILE"
    restart_daemon
    emit ok 1
    emit message "Thread policy $2"
    ;;
  set-profile)
    case "$2" in 1|2) ;; *) echo 'invalid boost profile' >&2; exit 2 ;; esac
    printf '%s\n' "$2" >"$PROFILE_FILE"
    emit ok 1
    emit message "Boost profile $2"
    ;;
  restart)
    restart_daemon
    emit ok 1
    emit message 'Service restarted'
    ;;
  clear-log)
    : >"$LOG_FILE"
    emit ok 1
    emit message 'Log cleared'
    ;;
  *)
    echo "usage: $0 {status|info|threads|logs|diagnostics|set-policy|set-thread-policy|set-profile|restart|clear-log}" >&2
    exit 2
    ;;
esac
