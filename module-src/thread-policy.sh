#!/system/bin/sh

# Per-thread Launcher policy. CPU masks are derived from this device's own
# cpusets and capacities; no SoC-specific CPU number is encoded here.
TASKSET=/system/bin/taskset
UCLAMPSET=/system/bin/uclampset
THREADCTL="$MODDIR/bin/launcher-threadctl"
THREAD_SNAPSHOT_FILE="$MODDIR/launcher-thread-original"
THREAD_LAUNCHER_PID_FILE="$MODDIR/launcher-thread-pid"
THREAD_BOOST_SERIAL_FILE="$MODDIR/launcher-thread-boost.serial"
THREAD_POLICY_STATE_FILE="$MODDIR/thread-policy.state"
THREAD_TOPOLOGY_FILE="$MODDIR/launcher-thread-topology"
THREAD_TOPOLOGY_INPUT_FILE="$MODDIR/launcher-thread-topology.input"
THREAD_BOOST_MS=1

THREAD_ALL_MASK=""
THREAD_PERF_MASK=""
THREAD_MID_MASK=""
THREAD_LITTLE_MASK=""
THREAD_RASTER=""
THREAD_UI=""
THREAD_RUST=""
THREAD_RESMGR=""
THREAD_FENCE=""
THREAD_FILE_VALUE=""

read_thread_file() {
  THREAD_FILE_VALUE=""
  [ -r "$1" ] && IFS= read -r THREAD_FILE_VALUE <"$1"
  return 0
}

thread_log() {
  command -v log_state >/dev/null 2>&1 && log_state "$*"
  return 0
}

thread_policy_enabled() {
  read_thread_file "$THREAD_POLICY_STATE_FILE"
  [ "$THREAD_FILE_VALUE" != disabled ]
}

cpulist_to_mask() {
  local list="$1"
  local token first last cpu mask old_ifs
  mask=0
  old_ifs="$IFS"
  IFS=,
  for token in $list; do
    case "$token" in
      *-*) first=${token%-*}; last=${token#*-} ;;
      *) first=$token; last=$token ;;
    esac
    case "$first:$last" in
      *[!0-9:]*|:|*:|'') continue ;;
    esac
    cpu=$first
    while [ "$cpu" -le "$last" ]; do
      mask=$((mask | (1 << cpu)))
      cpu=$((cpu + 1))
    done
  done
  IFS="$old_ifs"
  printf '%x' "$mask"
}

derive_launcher_masks() {
  local online_list top_list background_list
  local all_value top_value background_value perf_value mid_value
  local cpu bit capacity best_capacity prime_cpu
  local lowest_capacity little_value capacity_seen topology previous_topology
  local topology_input previous_input

  read_thread_file /sys/devices/system/cpu/online
  online_list="$THREAD_FILE_VALUE"
  read_thread_file /dev/cpuset/top-app/cpus
  top_list="$THREAD_FILE_VALUE"
  read_thread_file /dev/cpuset/background/cpus
  background_list="$THREAD_FILE_VALUE"
  topology_input="$online_list|$top_list|$background_list"
  read_thread_file "$THREAD_TOPOLOGY_INPUT_FILE"
  previous_input="$THREAD_FILE_VALUE"
  if [ "$topology_input" = "$previous_input" ] && [ -r "$THREAD_TOPOLOGY_FILE" ]; then
    read -r THREAD_ALL_MASK THREAD_PERF_MASK THREAD_MID_MASK THREAD_LITTLE_MASK <"$THREAD_TOPOLOGY_FILE"
    [ -n "$THREAD_LITTLE_MASK" ] && return 0
  fi
  THREAD_ALL_MASK="$(cpulist_to_mask "$online_list")"
  [ -n "$THREAD_ALL_MASK" ] || THREAD_ALL_MASK=ff
  [ -n "$top_list" ] || top_list="$online_list"

  all_value=$((0x$THREAD_ALL_MASK))
  top_value=$((0x$(cpulist_to_mask "$top_list")))
  background_value=$((0x$(cpulist_to_mask "$background_list")))
  perf_value=$((top_value & ~background_value & all_value))
  [ "$perf_value" -ne 0 ] || perf_value=$((top_value & all_value))
  [ "$perf_value" -ne 0 ] || perf_value=$all_value

  best_capacity=-1
  prime_cpu=-1
  lowest_capacity=999999
  little_value=0
  capacity_seen=0
  cpu=0
  while [ "$cpu" -lt 32 ]; do
    bit=$((1 << cpu))
    if [ $((all_value & bit)) -ne 0 ]; then
      read_thread_file "/sys/devices/system/cpu/cpu$cpu/cpu_capacity"
      capacity="$THREAD_FILE_VALUE"
      case "$capacity" in ''|*[!0-9]*) capacity="" ;; esac
      if [ -n "$capacity" ]; then
        capacity_seen=1
        if [ "$capacity" -lt "$lowest_capacity" ]; then
          lowest_capacity=$capacity
          little_value=$bit
        elif [ "$capacity" -eq "$lowest_capacity" ]; then
          little_value=$((little_value | bit))
        fi
      fi
    fi
    if [ $((perf_value & bit)) -ne 0 ]; then
      read_thread_file "/sys/devices/system/cpu/cpu$cpu/cpu_capacity"
      capacity="$THREAD_FILE_VALUE"
      case "$capacity" in ''|*[!0-9]*) capacity=0 ;; esac
      if [ "$capacity" -gt "$best_capacity" ]; then
        best_capacity=$capacity
        prime_cpu=$cpu
      fi
    fi
    cpu=$((cpu + 1))
  done

  mid_value=$perf_value
  [ "$prime_cpu" -lt 0 ] || mid_value=$((perf_value & ~(1 << prime_cpu)))
  [ "$mid_value" -ne 0 ] || mid_value=$perf_value
  background_value=$((background_value & all_value))
  [ "$background_value" -ne 0 ] || background_value=$((all_value & ~perf_value))
  [ "$background_value" -ne 0 ] || background_value=$all_value
  [ "$capacity_seen" -ne 0 ] || little_value=$background_value
  [ "$little_value" -ne 0 ] || little_value=$background_value

  THREAD_PERF_MASK="$(printf '%x' "$perf_value")"
  THREAD_MID_MASK="$(printf '%x' "$mid_value")"
  THREAD_LITTLE_MASK="$(printf '%x' "$little_value")"
  topology="$THREAD_ALL_MASK $THREAD_PERF_MASK $THREAD_MID_MASK $THREAD_LITTLE_MASK"
  read_thread_file "$THREAD_TOPOLOGY_FILE"
  previous_topology="$THREAD_FILE_VALUE"
  echo "$topology_input" >"$THREAD_TOPOLOGY_INPUT_FILE"
  if [ "$topology" != "$previous_topology" ]; then
    echo "$topology" >"$THREAD_TOPOLOGY_FILE"
    thread_log "thread-topology all=$THREAD_ALL_MASK perf=$THREAD_PERF_MASK mid=$THREAD_MID_MASK little=$THREAD_LITTLE_MASK"
  fi
}

refresh_launcher_threads() {
  local pid="$1"
  local task tid name
  THREAD_RASTER=""
  THREAD_UI=""
  THREAD_RUST=""
  THREAD_RESMGR=""
  THREAD_FENCE=""
  [ -d "/proc/$pid/task" ] || return 1
  for task in /proc/"$pid"/task/*; do
    [ -r "$task/comm" ] || continue
    tid=${task##*/}
    IFS= read -r name <"$task/comm"
    case "$name" in
      1.raster) THREAD_RASTER="$THREAD_RASTER $tid" ;;
      1.ui) THREAD_UI="$THREAD_UI $tid" ;;
      rt-launcher-mai) THREAD_RUST="$THREAD_RUST $tid" ;;
      IplrVkResMgr) THREAD_RESMGR="$THREAD_RESMGR $tid" ;;
      IplrVkFenceWait) THREAD_FENCE="$THREAD_FENCE $tid" ;;
    esac
  done
}

snapshot_launcher_thread() {
  local launcher_pid="$1"
  local tid="$2"
  local name="$3"
  local output mask saved_launcher saved_tid saved_name saved_mask
  [ -r "/proc/$launcher_pid/task/$tid/status" ] || return 0
  if [ -r "$THREAD_SNAPSHOT_FILE" ]; then
    while read -r saved_launcher saved_tid saved_name saved_mask; do
      [ "$saved_launcher" = "$launcher_pid" ] && [ "$saved_tid" = "$tid" ] && return 0
    done <"$THREAD_SNAPSHOT_FILE"
  fi
  output="$($TASKSET -p "$tid" 2>/dev/null)"
  mask=${output##*: }
  case "$mask" in ''|*[!0-9a-fA-F]*) return 0 ;; esac
  printf '%s %s %s %s\n' "$launcher_pid" "$tid" "$name" "$mask" >>"$THREAD_SNAPSHOT_FILE"
}

reset_launcher_uclamp() {
  local launcher_pid="$1"
  [ -x "$THREADCTL" ] || return 0
  "$THREADCTL" reset "$launcher_pid" >/dev/null 2>&1 ||
    thread_log "thread-uclamp-reset-failed launcher_pid=$launcher_pid"
}

restore_launcher_threads() {
  local launcher_pid tid name mask saved_launcher saved_tid saved_name saved_mask found
  if [ -r "$THREAD_SNAPSHOT_FILE" ]; then
    while read -r launcher_pid tid name mask; do
      [ -r "/proc/$launcher_pid/task/$tid/status" ] || continue
      $TASKSET -p "$mask" "$tid" >/dev/null 2>&1
      $UCLAMPSET -m -1 -M -1 -p "$tid" >/dev/null 2>&1
    done <"$THREAD_SNAPSHOT_FILE"
  fi

  launcher_pid="$(pidof com.miui.home 2>/dev/null)"
  launcher_pid=${launcher_pid%% *}
  if [ -n "$launcher_pid" ] && [ -d "/proc/$launcher_pid/task" ]; then
    derive_launcher_masks
    refresh_launcher_threads "$launcher_pid" || true
    for tid in $THREAD_RASTER $THREAD_UI $THREAD_RUST $THREAD_RESMGR $THREAD_FENCE; do
      found=0
      if [ -r "$THREAD_SNAPSHOT_FILE" ]; then
        while read -r saved_launcher saved_tid saved_name saved_mask; do
          if [ "$saved_launcher" = "$launcher_pid" ] && [ "$saved_tid" = "$tid" ]; then
            found=1
            break
          fi
        done <"$THREAD_SNAPSHOT_FILE"
      fi
      [ "$found" -eq 0 ] || continue
      mask="$THREAD_ALL_MASK"
      case " $THREAD_RESMGR $THREAD_FENCE " in *" $tid "*) mask="$THREAD_LITTLE_MASK" ;; esac
      $TASKSET -p "$mask" "$tid" >/dev/null 2>&1
      $UCLAMPSET -m -1 -M -1 -p "$tid" >/dev/null 2>&1
    done
  fi
  rm -f "$THREAD_SNAPSHOT_FILE" "$THREAD_LAUNCHER_PID_FILE" "$THREAD_BOOST_SERIAL_FILE"
  rm -f "$THREAD_TOPOLOGY_FILE" "$THREAD_TOPOLOGY_INPUT_FILE"
}

prepare_launcher_thread_policy() {
  local launcher_pid="$1"
  local previous_pid
  read_thread_file "$THREAD_LAUNCHER_PID_FILE"
  previous_pid="$THREAD_FILE_VALUE"
  if [ -n "$previous_pid" ] && [ "$previous_pid" != "$launcher_pid" ]; then
    restore_launcher_threads
  fi
  if [ "$previous_pid" != "$launcher_pid" ]; then
    echo "$launcher_pid" >"$THREAD_LAUNCHER_PID_FILE"
  fi
}

apply_launcher_base_affinity() {
  local launcher_pid="$1"
  local tid
  [ -x "$TASKSET" ] && [ -x "$THREADCTL" ] || return 0
  if ! thread_policy_enabled; then
    restore_launcher_threads
    return 0
  fi
  prepare_launcher_thread_policy "$launcher_pid"
  derive_launcher_masks
  refresh_launcher_threads "$launcher_pid" || return 0
  for tid in $THREAD_RASTER; do snapshot_launcher_thread "$launcher_pid" "$tid" 1.raster; done
  for tid in $THREAD_UI; do snapshot_launcher_thread "$launcher_pid" "$tid" 1.ui; done
  for tid in $THREAD_RUST; do snapshot_launcher_thread "$launcher_pid" "$tid" rt-launcher-mai; done
  for tid in $THREAD_RESMGR; do snapshot_launcher_thread "$launcher_pid" "$tid" IplrVkResMgr; done
  for tid in $THREAD_FENCE; do snapshot_launcher_thread "$launcher_pid" "$tid" IplrVkFenceWait; done
  "$THREADCTL" apply "$launcher_pid" "$THREAD_PERF_MASK" "$THREAD_MID_MASK" "$THREAD_LITTLE_MASK" 0 >/dev/null 2>&1 ||
    thread_log "thread-affinity-batch-failed launcher_pid=$launcher_pid"
}

apply_launcher_uclamp_boost() {
  local launcher_pid="$1"
  apply_launcher_base_affinity "$launcher_pid"
  "$THREADCTL" apply "$launcher_pid" "$THREAD_PERF_MASK" "$THREAD_MID_MASK" "$THREAD_LITTLE_MASK" 1 >/dev/null 2>&1 ||
    thread_log "thread-boost-batch-failed launcher_pid=$launcher_pid"
}

increment_thread_boost_serial() {
  local value
  read_thread_file "$THREAD_BOOST_SERIAL_FILE"
  value="$THREAD_FILE_VALUE"
  case "$value" in ''|*[!0-9]*) value=0 ;; esac
  value=$((value + 1))
  echo "$value" >"$THREAD_BOOST_SERIAL_FILE"
  echo "$value"
}

trigger_launcher_thread_boost() {
  local launcher_pid="$1"
  local reason="$2"
  local serial
  thread_policy_enabled || return 0
  [ -d "/proc/$launcher_pid/task" ] || return 0
  serial="$(increment_thread_boost_serial)"
  apply_launcher_uclamp_boost "$launcher_pid"
  thread_log "thread-boost serial=$serial reason=$reason"
  (
    sleep "$THREAD_BOOST_MS"
    read_thread_file "$THREAD_BOOST_SERIAL_FILE"
    [ "$THREAD_FILE_VALUE" = "$serial" ] || exit 0
    reset_launcher_uclamp "$launcher_pid"
    thread_log "thread-boost-reset serial=$serial"
  ) &
}
