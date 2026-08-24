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

promote_controller_process() {
  # WebUI commands can be launched from a background cgroup. Move only the
  # short-lived controller (or the daemon itself) before taking lifecycle
  # locks so heavy source-app load cannot delay a restart by several seconds.
  printf '%s\n' "$$" >/dev/cpuset/foreground/cgroup.procs 2>/dev/null || true
  printf '%s\n' "$$" >/dev/cpuctl/foreground/cgroup.procs 2>/dev/null || true
}

is_module_service_pid() {
  local target="$1" command
  case "$target" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "/proc/$target/cmdline" ] || return 1
  command="$(tr '\000' ' ' <"/proc/$target/cmdline" 2>/dev/null)"
  case "$command" in *"$MODDIR/service.sh"*) return 0 ;; *) return 1 ;; esac
}

find_active_service_pid() {
  local candidate
  ACTIVE_SERVICE_PID=""
  read_first_line "$PID_FILE"; candidate="$READ_VALUE"
  if is_module_service_pid "$candidate"; then
    ACTIVE_SERVICE_PID="$candidate"
    return 0
  fi
  read_first_line "$SERVICE_LOCK_OWNER"; candidate="$READ_VALUE"
  if is_module_service_pid "$candidate"; then
    ACTIVE_SERVICE_PID="$candidate"
    return 0
  fi
  return 1
}

remove_owned_lock() {
  local directory="$1" owner_file="$2" owner
  read_first_line "$owner_file"; owner="$READ_VALUE"
  [ "$owner" = "$$" ] || return 0
  rm -f "$owner_file"
  rmdir "$directory" 2>/dev/null || true
}

claim_service_instance() {
  local owner
  if mkdir "$SERVICE_LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$SERVICE_LOCK_OWNER"
    return 0
  fi
  read_first_line "$SERVICE_LOCK_OWNER"; owner="$READ_VALUE"
  is_module_service_pid "$owner" && return 1
  # A competing instance may have created the directory but not its owner
  # file yet. Give it one scheduling window before treating the lock as stale.
  sleep 0.10
  read_first_line "$SERVICE_LOCK_OWNER"; owner="$READ_VALUE"
  is_module_service_pid "$owner" && return 1
  rm -f "$SERVICE_LOCK_OWNER"
  rmdir "$SERVICE_LOCK_DIR" 2>/dev/null || return 1
  mkdir "$SERVICE_LOCK_DIR" 2>/dev/null || return 1
  printf '%s\n' "$$" >"$SERVICE_LOCK_OWNER"
}

release_service_instance() {
  remove_owned_lock "$SERVICE_LOCK_DIR" "$SERVICE_LOCK_OWNER"
}

acquire_restart_lock() {
  local attempt=0 owner
  RESTART_LOCK_ACQUIRED=0
  while [ "$attempt" -lt 100 ]; do
    if mkdir "$RESTART_LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" >"$RESTART_LOCK_OWNER"
      RESTART_LOCK_ACQUIRED=1
      return 0
    fi
    read_first_line "$RESTART_LOCK_OWNER"; owner="$READ_VALUE"
    if [ -z "$owner" ]; then
      # mkdir and owner-file creation are two operations. Do not reclaim the
      # directory while the winning process is between them.
      sleep 0.10
      read_first_line "$RESTART_LOCK_OWNER"; owner="$READ_VALUE"
    fi
    case "$owner" in ''|*[!0-9]*) owner=0 ;; esac
    if [ ! -d "/proc/$owner" ]; then
      rm -f "$RESTART_LOCK_OWNER"
      rmdir "$RESTART_LOCK_DIR" 2>/dev/null || true
    fi
    sleep 0.10
    # Configuration is read dynamically. If another valid restart completed
    # while this caller was waiting, coalesce with it instead of killing the
    # daemon that has just become ready and starting the whole cycle again.
    if [ ! -d "$RESTART_LOCK_DIR" ] && find_active_service_pid; then
      return 0
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

release_restart_lock() {
  remove_owned_lock "$RESTART_LOCK_DIR" "$RESTART_LOCK_OWNER"
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
  local daemon_pid watcher_pid started_pid attempt result=1
  promote_controller_process
  acquire_restart_lock || return 1
  [ "$RESTART_LOCK_ACQUIRED" = 1 ] || return 0
  find_active_service_pid && daemon_pid="$ACTIVE_SERVICE_PID"
  [ -n "$daemon_pid" ] && kill_process_tree "$daemon_pid"
  for watcher_pid in $(pidof launcher-logwatch 2>/dev/null); do
    kill -9 "$watcher_pid" 2>/dev/null || true
  done
  rm -f "$PID_FILE"
  nohup /system/bin/sh "$MODDIR/service.sh" >/dev/null 2>&1 &
  started_pid=$!
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    read_first_line "$PID_FILE"; daemon_pid="$READ_VALUE"
    if is_module_service_pid "$daemon_pid"; then
      result=0
      break
    fi
    [ -d "/proc/$started_pid" ] || break
    sleep 0.10
    attempt=$((attempt + 1))
  done
  release_restart_lock
  return "$result"
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
