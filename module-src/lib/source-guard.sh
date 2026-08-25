#!/system/bin/sh

source_guard_command() {
  [ -x "$SOURCE_GUARD" ] && [ -S "$SOURCE_GUARD_SOCKET" ] || return 1
  "$SOURCE_GUARD" "$@"
}

drain_source_group() {
  local controller="$1" destination="$2" pid
  [ -r "$controller/cgroup.procs" ] || return 0
  while IFS= read -r pid; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$pid" >"$destination/cgroup.procs" 2>/dev/null || true
  done <"$controller/cgroup.procs"
}

remove_source_groups() {
  drain_source_group "$SOURCE_CPUSET_DIR" /dev/cpuset/background
  drain_source_group "$SOURCE_CPUCTL_DIR" /dev/cpuctl/background
  rmdir "$SOURCE_CPUSET_DIR" "$SOURCE_CPUCTL_DIR" 2>/dev/null || true
}

configure_source_groups() {
  local placement mask cpus mems suppression shares
  derive_launcher_masks
  read_first_line "$SOURCE_PLACEMENT_FILE"; placement="$READ_VALUE"
  case "$placement" in
    1) mask="$THREAD_PERF_MASK" ;;
    2) mask="$THREAD_MID_MASK" ;;
    3) mask="$THREAD_RENDER_MASK" ;;
    4) mask="$THREAD_PRIME_MASK" ;;
    5) mask="$THREAD_LITTLE_MASK" ;;
    6) mask="$THREAD_SECONDARY_MASK" ;;
    7) mask="$THREAD_BACKGROUND_MASK" ;;
    8) mask="$THREAD_LITTLE_SPARE_MASK" ;;
    *) return 1 ;;
  esac
  cpus="$(mask_to_cpulist "$mask")"
  [ -n "$cpus" ] || return 1
  read_first_line /dev/cpuset/mems; mems="$READ_VALUE"
  [ -n "$mems" ] || mems=0

  mkdir -p "$SOURCE_CPUSET_DIR" "$SOURCE_CPUCTL_DIR" || return 1
  printf '%s\n' "$mems" >"$SOURCE_CPUSET_DIR/mems" || return 1
  printf '%s\n' "$cpus" >"$SOURCE_CPUSET_DIR/cpus" || return 1
  printf '0\n' >"$SOURCE_CPUSET_DIR/sched_load_balance" 2>/dev/null || true

  suppression="$(read_bounded_number "$SOURCE_NICE_SUPPRESSION_FILE" 40 0 40)"
  shares=$((1024 - suppression * 24))
  [ "$shares" -ge 64 ] || shares=64
  printf '%s\n' "$shares" >"$SOURCE_CPUCTL_DIR/cpu.shares" || return 1
  printf '0\n' >"$SOURCE_CPUCTL_DIR/cpu.uclamp.min" 2>/dev/null || true
  printf '1024\n' >"$SOURCE_CPUCTL_DIR/cpu.uclamp.max" 2>/dev/null || true
  printf '0\n' >"$SOURCE_CPUCTL_DIR/cpu.uclamp.latency_sensitive" 2>/dev/null || true
  log_state "source-groups cpus=$cpus shares=$shares"
}

refresh_source_guard_configuration() {
  configure_source_groups || return 1
  config_enabled "$SOURCE_POLICY_FILE" ||
    source_guard_command disable >/dev/null 2>&1 || true
}

start_source_guard() {
  local attempt=0
  [ -x "$SOURCE_GUARD" ] || return 1
  [ -d "$SOURCE_CPUSET_DIR" ] && [ -d "$SOURCE_CPUCTL_DIR" ] || return 1
  "$SOURCE_GUARD" daemon &
  SOURCE_GUARD_PID=$!
  printf '%s\n' "$SOURCE_GUARD_PID" >"$SOURCE_GUARD_PID_FILE"
  while [ "$attempt" -lt 100 ]; do
    [ -S "$SOURCE_GUARD_SOCKET" ] && return 0
    [ -d "/proc/$SOURCE_GUARD_PID" ] || return 1
    sleep 0.01
    attempt=$((attempt + 1))
  done
  return 1
}

stop_source_guard() {
  local pid attempt=0
  [ -S "$SOURCE_GUARD_SOCKET" ] && "$SOURCE_GUARD" stop 2>/dev/null || true
  read_first_line "$SOURCE_GUARD_PID_FILE"; pid="$READ_VALUE"
  case "$pid" in ''|*[!0-9]*) pid= ;; esac
  if [ -n "$pid" ]; then
    while [ "$attempt" -lt 50 ] && [ -d "/proc/$pid" ]; do
      sleep 0.01
      attempt=$((attempt + 1))
    done
    [ -d "/proc/$pid" ] && kill "$pid" 2>/dev/null || true
  fi
  rm -f "$SOURCE_GUARD_PID_FILE" "$SOURCE_GUARD_SOCKET" "$SOURCE_GUARD_STATUS"
}
