#!/system/bin/sh

log_state() {
  local monotonic rest
  read -r monotonic rest </proc/uptime
  echo "$(date '+%F %T' 2>/dev/null) mono=$monotonic $*"
}

increment_file() {
  local file="$1" value
  read_first_line "$file"
  value="$READ_VALUE"
  case "$value" in ''|*[!0-9]*) value=0 ;; esac
  value=$((value + 1))
  echo "$value" >"$file"
  echo "$value"
}

kill_process_tree() {
  local target="$1" child
  [ -d "/proc/$target" ] || return 0
  for child in $(cat "/proc/$target/task/$target/children" 2>/dev/null); do
    kill_process_tree "$child"
  done
  kill -9 "$target" 2>/dev/null || true
}

cleanup_stale_daemons() {
  local pid args list
  list="$MODDIR/processes.$$"
  ps -A -o PID,ARGS >"$list" 2>/dev/null
  while read -r pid args; do
    [ "$pid" = "$$" ] && continue
    case "$args" in
      *"$MODDIR/service.sh"*) kill_process_tree "$pid" ;;
      *launcher-logwatch*) kill -9 "$pid" 2>/dev/null ;;
    esac
  done <"$list"
  rm -f "$list"
}

restart_daemon() {
  local daemon_pid watcher_pid
  read_first_line "$PID_FILE"; daemon_pid="$READ_VALUE"
  [ -n "$daemon_pid" ] && kill_process_tree "$daemon_pid"
  for watcher_pid in $(pidof launcher-logwatch 2>/dev/null); do
    kill -9 "$watcher_pid" 2>/dev/null || true
  done
  sleep 1
  nohup /system/bin/sh "$MODDIR/service.sh" >/dev/null 2>&1 &
  sleep 1
}

read_controller_group() {
  local pid="$1" controller="$2" hierarchy controllers path
  CGROUP_RESULT=""
  [ -r "/proc/$pid/cgroup" ] || return 0
  while IFS=: read -r hierarchy controllers path; do
    case ",$controllers," in
      *",$controller,"*) CGROUP_RESULT="$path"; return 0 ;;
    esac
  done <"/proc/$pid/cgroup"
}

write_controller_group() {
  local pid="$1" root="$2" group="$3" relative target
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
  local pid="$1" file="$2" cpuset cpu
  [ -r "$file" ] && return 0
  [ -d "/proc/$pid" ] || return 0
  read_controller_group "$pid" cpuset
  cpuset="$CGROUP_RESULT"
  read_controller_group "$pid" cpu
  cpu="$CGROUP_RESULT"
  printf '%s %s\n' "$cpuset" "$cpu" >"$file"
}
