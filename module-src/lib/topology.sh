#!/system/bin/sh

THREAD_ALL_MASK=""
THREAD_PERF_MASK=""
THREAD_MID_MASK=""
THREAD_LITTLE_MASK=""
THREAD_RENDER_MASK=""
THREAD_PRIME_MASK=""
THREAD_SECONDARY_MASK=""
THREAD_BACKGROUND_MASK=""
THREAD_LITTLE_SPARE_MASK=""
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
  local list="$1" token first last cpu mask old_ifs
  mask=0
  old_ifs="$IFS"
  IFS=', '
  for token in $list; do
    case "$token" in
      *-*) first=${token%-*}; last=${token#*-} ;;
      *) first=$token; last=$token ;;
    esac
    case "$first:$last" in *[!0-9:]*|:|*:|'') continue ;; esac
    cpu=$first
    while [ "$cpu" -le "$last" ]; do
      mask=$((mask | (1 << cpu)))
      cpu=$((cpu + 1))
    done
  done
  IFS="$old_ifs"
  printf '%x' "$mask"
}

mask_to_cpulist() {
  local value=$((0x$1)) cpu start=-1 last=-1 output=""
  cpu=0
  while [ "$cpu" -lt 32 ]; do
    if [ $((value & (1 << cpu))) -ne 0 ]; then
      [ "$start" -ge 0 ] || start=$cpu
      last=$cpu
    elif [ "$start" -ge 0 ]; then
      [ -z "$output" ] || output="$output,"
      if [ "$start" -eq "$last" ]; then output="$output$start"; else output="$output$start-$last"; fi
      start=-1
      last=-1
    fi
    cpu=$((cpu + 1))
  done
  if [ "$start" -ge 0 ]; then
    [ -z "$output" ] || output="$output,"
    if [ "$start" -eq "$last" ]; then output="$output$start"; else output="$output$start-$last"; fi
  fi
  printf '%s' "$output"
}

derive_launcher_masks() {
  local online_list top_list background_list topology_input previous_input
  local all_value top_value background_value perf_value mid_value prime_value
  local cpu bit capacity best_capacity prime_cpu lowest_capacity
  local best_nonprime_capacity render_value secondary_value
  local little_value little_spare_value capacity_seen topology previous_topology
  local little_count reserved_cpu

  read_thread_file /sys/devices/system/cpu/online; online_list="$THREAD_FILE_VALUE"
  read_thread_file /dev/cpuset/top-app/cpus; top_list="$THREAD_FILE_VALUE"
  read_thread_file /dev/cpuset/background/cpus; background_list="$THREAD_FILE_VALUE"
  topology_input="$online_list|$top_list|$background_list"
  read_thread_file "$THREAD_TOPOLOGY_INPUT_FILE"; previous_input="$THREAD_FILE_VALUE"
  if [ "$topology_input" = "$previous_input" ] && [ -r "$THREAD_TOPOLOGY_FILE" ]; then
    read -r THREAD_ALL_MASK THREAD_PERF_MASK THREAD_MID_MASK THREAD_LITTLE_MASK \
      THREAD_RENDER_MASK THREAD_PRIME_MASK THREAD_SECONDARY_MASK \
      THREAD_BACKGROUND_MASK THREAD_LITTLE_SPARE_MASK <"$THREAD_TOPOLOGY_FILE"
    [ -n "$THREAD_LITTLE_SPARE_MASK" ] && return 0
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
  prime_value=$perf_value
  [ "$prime_cpu" -lt 0 ] || prime_value=$((1 << prime_cpu))

  # The render set combines prime with the fastest non-prime capacity tier.
  # It lets latency-sensitive work migrate when prime is occupied, while the
  # remaining performance tier can isolate maintenance work.
  best_nonprime_capacity=-1
  render_value=$prime_value
  cpu=0
  while [ "$cpu" -lt 32 ]; do
    bit=$((1 << cpu))
    if [ $((mid_value & bit)) -ne 0 ]; then
      read_thread_file "/sys/devices/system/cpu/cpu$cpu/cpu_capacity"
      capacity="$THREAD_FILE_VALUE"
      case "$capacity" in ''|*[!0-9]*) capacity=0 ;; esac
      if [ "$capacity" -gt "$best_nonprime_capacity" ]; then
        best_nonprime_capacity=$capacity
        render_value=$((prime_value | bit))
      elif [ "$capacity" -eq "$best_nonprime_capacity" ]; then
        render_value=$((render_value | bit))
      fi
    fi
    cpu=$((cpu + 1))
  done
  render_value=$((render_value & perf_value))
  [ "$render_value" -ne 0 ] || render_value=$perf_value
  secondary_value=$((perf_value & ~render_value))
  [ "$secondary_value" -ne 0 ] || secondary_value=$mid_value
  background_value=$((background_value & all_value))
  [ "$background_value" -ne 0 ] || background_value=$((all_value & ~perf_value))
  [ "$background_value" -ne 0 ] || background_value=$all_value
  [ "$capacity_seen" -ne 0 ] || little_value=$background_value
  [ "$little_value" -ne 0 ] || little_value=$background_value

  # Reserve the highest-numbered efficiency CPU for system background work.
  # A single-CPU efficiency tier cannot be reduced without creating an empty
  # cpuset, so it remains unchanged.
  little_spare_value=$little_value
  little_count=0
  reserved_cpu=-1
  cpu=0
  while [ "$cpu" -lt 32 ]; do
    bit=$((1 << cpu))
    if [ $((little_value & bit)) -ne 0 ]; then
      little_count=$((little_count + 1))
      reserved_cpu=$cpu
    fi
    cpu=$((cpu + 1))
  done
  if [ "$little_count" -gt 1 ] && [ "$reserved_cpu" -ge 0 ]; then
    little_spare_value=$((little_value & ~(1 << reserved_cpu)))
  fi

  THREAD_PERF_MASK="$(printf '%x' "$perf_value")"
  THREAD_MID_MASK="$(printf '%x' "$mid_value")"
  THREAD_LITTLE_MASK="$(printf '%x' "$little_value")"
  THREAD_RENDER_MASK="$(printf '%x' "$render_value")"
  THREAD_PRIME_MASK="$(printf '%x' "$prime_value")"
  THREAD_SECONDARY_MASK="$(printf '%x' "$secondary_value")"
  THREAD_BACKGROUND_MASK="$(printf '%x' "$background_value")"
  THREAD_LITTLE_SPARE_MASK="$(printf '%x' "$little_spare_value")"
  topology="$THREAD_ALL_MASK $THREAD_PERF_MASK $THREAD_MID_MASK $THREAD_LITTLE_MASK $THREAD_RENDER_MASK $THREAD_PRIME_MASK $THREAD_SECONDARY_MASK $THREAD_BACKGROUND_MASK $THREAD_LITTLE_SPARE_MASK"
  read_thread_file "$THREAD_TOPOLOGY_FILE"; previous_topology="$THREAD_FILE_VALUE"
  echo "$topology_input" >"$THREAD_TOPOLOGY_INPUT_FILE"
  if [ "$topology" != "$previous_topology" ]; then
    echo "$topology" >"$THREAD_TOPOLOGY_FILE"
    thread_log "thread-topology all=$THREAD_ALL_MASK perf=$THREAD_PERF_MASK mid=$THREAD_MID_MASK efficiency=$THREAD_LITTLE_MASK efficiency_spare=$THREAD_LITTLE_SPARE_MASK render=$THREAD_RENDER_MASK prime=$THREAD_PRIME_MASK secondary=$THREAD_SECONDARY_MASK background=$THREAD_BACKGROUND_MASK"
  fi
}
