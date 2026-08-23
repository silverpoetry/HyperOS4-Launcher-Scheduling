#!/system/bin/sh

MODDIR=${0%/*}
LOG_FILE=/data/local/tmp/hyperos4-launcher-scheduling.log

emit() {
  local key="$1"
  shift
  printf '%s=%s\n' "$key" "$*"
}

read_first_line() {
  local value=""
  [ -r "$1" ] && IFS= read -r value <"$1"
  printf '%s' "$value"
}

read_state() {
  local value
  value="$(read_first_line "$1")"
  [ "$value" = disabled ] || value=enabled
  printf '%s' "$value"
}

read_number() {
  local value
  value="$(read_first_line "$1")"
  case "$value" in ''|*[!0-9]*) value="$2" ;; esac
  printf '%s' "$value"
}

valid_state() {
  case "$1" in enabled|disabled) return 0 ;; *) return 1 ;; esac
}

valid_number() {
  local value="$1" minimum="$2" maximum="$3"
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  [ "$value" -ge "$minimum" ] && [ "$value" -le "$maximum" ]
}

kill_tree() {
  local target="$1" child
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
  local pid="$1" controller="$2" hierarchy controllers path
  [ -r "/proc/$pid/cgroup" ] || return 0
  while IFS=: read -r hierarchy controllers path; do
    case ",$controllers," in
      *",$controller,"*) printf '%s' "$path"; return 0 ;;
    esac
  done <"/proc/$pid/cgroup"
}

read_allowed_list() {
  local key value rest
  [ -r "$1" ] || return 0
  while read -r key value rest; do
    [ "$key" = Cpus_allowed_list: ] && { printf '%s' "$value"; return 0; }
  done <"$1"
}

module_version() {
  local line
  [ -r "$MODDIR/module.prop" ] || return 0
  while IFS= read -r line; do
    case "$line" in version=*) printf '%s' "${line#version=}"; return 0 ;; esac
  done <"$MODDIR/module.prop"
}

print_frequency() {
  local active policy related current maximum original applied
  active=0
  policy=""
  related=""
  current=""
  maximum=""
  original=""
  applied=""
  if [ -r "$MODDIR/frequency-limit.active" ]; then
    active=1
    read -r policy original applied <"$MODDIR/frequency-limit.active"
    [ -r "$policy/related_cpus" ] && IFS= read -r related <"$policy/related_cpus"
    [ -r "$policy/scaling_max_freq" ] && IFS= read -r current <"$policy/scaling_max_freq"
    [ -r "$policy/cpuinfo_max_freq" ] && IFS= read -r maximum <"$policy/cpuinfo_max_freq"
  elif [ -r "$MODDIR/frequency-info" ]; then
    read -r policy related current maximum <"$MODDIR/frequency-info"
    [ -r "$policy/scaling_max_freq" ] && IFS= read -r current <"$policy/scaling_max_freq"
  fi
  emit frequency_active "$active"
  emit frequency_policy "${policy##*/}"
  emit frequency_cpus "$related"
  emit frequency_current_khz "$current"
  emit frequency_max_khz "$maximum"
  emit frequency_original_khz "$original"
  emit frequency_applied_khz "$applied"
}

print_status() {
  local mode daemon_pid daemon_alive launcher_pid topology
  local all_mask perf_mask mid_mask little_mask source_record
  local source_pid source_uid source_name pending_record pending_pid pending_uid pending_name
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
  emit author "github: silverpoetry"
  emit policy "$(read_state "$MODDIR/state")"
  emit source_policy "$(read_state "$MODDIR/source-policy.state")"
  emit aux_policy "$(read_state "$MODDIR/aux-policy.state")"
  emit thread_policy "$(read_state "$MODDIR/thread-policy.state")"
  emit frequency_policy_state "$(read_state "$MODDIR/frequency-policy.state")"
  emit frequency_percent "$(read_number "$MODDIR/frequency-limit-percent" 78)"
  emit frequency_timeout_ms "$(read_number "$MODDIR/frequency-timeout-ms" 1500)"
  emit app_fallback_ms "$(read_number "$MODDIR/app-fallback-ms" 2000)"
  emit launcher_placement "$(read_number "$MODDIR/launcher-placement" 2)"
  emit fence_placement "$(read_number "$MODDIR/fence-placement" 2)"
  emit boost_duration_ms "$(read_number "$MODDIR/boost-duration-ms" 1)"
  emit uclamp_raster "$(read_number "$MODDIR/uclamp-raster" 928)"
  emit uclamp_ui "$(read_number "$MODDIR/uclamp-ui" 768)"
  emit uclamp_rust "$(read_number "$MODDIR/uclamp-rust" 512)"
  emit uclamp_resmgr "$(read_number "$MODDIR/uclamp-resmgr" 384)"
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
  print_frequency
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
  local launcher_pid task tid name allowed uclamp_min uclamp_max
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
    uclamp_max="$(awk '/^[[:space:]]*uclamp\.max[[:space:]]*:/ { print $3; exit }' "$task/sched" 2>/dev/null)"
    [ -n "$uclamp_min" ] || uclamp_min=-
    [ -n "$uclamp_max" ] || uclamp_max=-
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$tid" "$allowed" "$uclamp_min" "$uclamp_max"
  done
}

print_logs() {
  local count="$1"
  case "$count" in ''|*[!0-9]*) count=100 ;; esac
  [ "$count" -le 200 ] || count=200
  tail -n "$count" "$LOG_FILE" 2>/dev/null
}

save_config() {
  valid_state "$2" && valid_state "$3" && valid_state "$4" &&
    valid_state "$5" && valid_state "$6" || return 2
  valid_number "$7" 40 100 || return 2
  valid_number "$8" 300 5000 || return 2
  valid_number "$9" 500 5000 || return 2
  valid_number "${10}" 1 2 || return 2
  valid_number "${11}" 1 2 || return 2
  valid_number "${12}" 1 1000 || return 2
  valid_number "${13}" 0 1024 || return 2
  valid_number "${14}" 0 1024 || return 2
  valid_number "${15}" 0 1024 || return 2
  valid_number "${16}" 0 1024 || return 2
  printf '%s\n' "$2" >"$MODDIR/state"
  printf '%s\n' "$3" >"$MODDIR/source-policy.state"
  printf '%s\n' "$4" >"$MODDIR/aux-policy.state"
  printf '%s\n' "$5" >"$MODDIR/thread-policy.state"
  printf '%s\n' "$6" >"$MODDIR/frequency-policy.state"
  printf '%s\n' "$7" >"$MODDIR/frequency-limit-percent"
  printf '%s\n' "$8" >"$MODDIR/frequency-timeout-ms"
  printf '%s\n' "$9" >"$MODDIR/app-fallback-ms"
  printf '%s\n' "${10}" >"$MODDIR/launcher-placement"
  printf '%s\n' "${11}" >"$MODDIR/fence-placement"
  printf '%s\n' "${12}" >"$MODDIR/boost-duration-ms"
  printf '%s\n' "${13}" >"$MODDIR/uclamp-raster"
  printf '%s\n' "${14}" >"$MODDIR/uclamp-ui"
  printf '%s\n' "${15}" >"$MODDIR/uclamp-rust"
  printf '%s\n' "${16}" >"$MODDIR/uclamp-resmgr"
  restart_daemon
  emit ok 1
  emit message 'Settings saved'
}

case "$1" in
  status) print_status ;;
  info) print_info ;;
  threads) print_threads ;;
  logs) print_logs "$2" ;;
  diagnostics)
    echo '[status]'; print_status
    echo; echo '[device]'; print_info
    echo; echo '[threads]'; print_threads
    echo; echo '[recent log]'; print_logs 120
    ;;
  save-config)
    save_config "$@" || { echo 'invalid settings' >&2; exit 2; }
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
    echo "usage: $0 {status|info|threads|logs|diagnostics|save-config|restart|clear-log}" >&2
    exit 2
    ;;
esac
