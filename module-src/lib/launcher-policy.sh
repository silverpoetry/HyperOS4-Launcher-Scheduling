#!/system/bin/sh

# Launcher thread discovery and policy transactions. All CPU masks are derived
# by topology.sh; this layer contains no device-specific CPU numbers.
THREAD_RASTER=""
THREAD_UI=""
THREAD_RUST=""
THREAD_RESMGR=""
THREAD_FENCE=""

refresh_launcher_threads() {
  local pid="$1" task tid name
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
  local launcher_pid="$1" tid="$2" name="$3"
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

reset_launcher_boost() {
  local launcher_pid="$1" ui_placement raster_placement resmgr_placement fence_placement
  [ -x "$THREADCTL" ] || return 0
  derive_launcher_masks
  read_thread_file "$THREAD_PLACEMENT_FILE"; ui_placement="$THREAD_FILE_VALUE"
  case "$ui_placement" in 1|2|3|4|5|6) ;; *) ui_placement=2 ;; esac
  read_thread_file "$THREAD_RASTER_PLACEMENT_FILE"; raster_placement="$THREAD_FILE_VALUE"
  case "$raster_placement" in 1|2|3|4|5|6) ;; *) raster_placement=4 ;; esac
  read_thread_file "$THREAD_RESMGR_PLACEMENT_FILE"; resmgr_placement="$THREAD_FILE_VALUE"
  case "$resmgr_placement" in 1|2|3|4|5|6) ;; *) resmgr_placement=2 ;; esac
  read_thread_file "$THREAD_FENCE_PLACEMENT_FILE"; fence_placement="$THREAD_FILE_VALUE"
  case "$fence_placement" in 1|2|3|4|5|6) ;; *) fence_placement=2 ;; esac
  "$THREADCTL" apply "$launcher_pid" "$THREAD_PERF_MASK" "$THREAD_MID_MASK" \
    "$THREAD_LITTLE_MASK" "$THREAD_RENDER_MASK" "$THREAD_PRIME_MASK" \
    "$THREAD_SECONDARY_MASK" "$ui_placement" "$raster_placement" \
    "$resmgr_placement" "$fence_placement" 0 0 0 0 >/dev/null 2>&1 ||
    thread_log "thread-boost-reset-failed launcher_pid=$launcher_pid"
}

restore_launcher_threads() {
  local launcher_pid tid name mask saved_launcher saved_tid saved_name saved_mask found
  if [ -r "$THREAD_SNAPSHOT_FILE" ]; then
    while read -r launcher_pid tid name mask; do
      [ -r "/proc/$launcher_pid/task/$tid/status" ] || continue
      "$TASKSET" -p "$mask" "$tid" >/dev/null 2>&1
      "$UCLAMPSET" -m -1 -M -1 -p "$tid" >/dev/null 2>&1
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
      "$TASKSET" -p "$THREAD_ALL_MASK" "$tid" >/dev/null 2>&1
      "$UCLAMPSET" -m -1 -M -1 -p "$tid" >/dev/null 2>&1
    done
  fi
  rm -f "$THREAD_SNAPSHOT_FILE" "$THREAD_LAUNCHER_PID_FILE" "$THREAD_BOOST_SERIAL_FILE"
  rm -f "$THREAD_TOPOLOGY_FILE" "$THREAD_TOPOLOGY_INPUT_FILE"
}

prepare_launcher_thread_policy() {
  local launcher_pid="$1" previous_pid
  read_thread_file "$THREAD_LAUNCHER_PID_FILE"; previous_pid="$THREAD_FILE_VALUE"
  if [ -n "$previous_pid" ] && [ "$previous_pid" != "$launcher_pid" ]; then
    restore_launcher_threads
  fi
  [ "$previous_pid" = "$launcher_pid" ] || echo "$launcher_pid" >"$THREAD_LAUNCHER_PID_FILE"
}

snapshot_discovered_launcher_threads() {
  local launcher_pid="$1" tid
  for tid in $THREAD_RASTER; do snapshot_launcher_thread "$launcher_pid" "$tid" 1.raster; done
  for tid in $THREAD_UI; do snapshot_launcher_thread "$launcher_pid" "$tid" 1.ui; done
  for tid in $THREAD_RUST; do snapshot_launcher_thread "$launcher_pid" "$tid" rt-launcher-mai; done
  for tid in $THREAD_RESMGR; do snapshot_launcher_thread "$launcher_pid" "$tid" IplrVkResMgr; done
  for tid in $THREAD_FENCE; do snapshot_launcher_thread "$launcher_pid" "$tid" IplrVkFenceWait; done
}

apply_launcher_base_affinity() {
  local launcher_pid="$1" ui_placement raster_placement resmgr_placement fence_placement
  [ -x "$TASKSET" ] && [ -x "$THREADCTL" ] || return 0
  if ! thread_policy_enabled; then
    restore_launcher_threads
    return 0
  fi
  prepare_launcher_thread_policy "$launcher_pid"
  derive_launcher_masks
  refresh_launcher_threads "$launcher_pid" || return 0
  snapshot_discovered_launcher_threads "$launcher_pid"
  read_thread_file "$THREAD_PLACEMENT_FILE"; ui_placement="$THREAD_FILE_VALUE"
  case "$ui_placement" in 1|2|3|4|5|6) ;; *) ui_placement=2 ;; esac
  read_thread_file "$THREAD_RASTER_PLACEMENT_FILE"; raster_placement="$THREAD_FILE_VALUE"
  case "$raster_placement" in 1|2|3|4|5|6) ;; *) raster_placement=4 ;; esac
  read_thread_file "$THREAD_RESMGR_PLACEMENT_FILE"; resmgr_placement="$THREAD_FILE_VALUE"
  case "$resmgr_placement" in 1|2|3|4|5|6) ;; *) resmgr_placement=2 ;; esac
  read_thread_file "$THREAD_FENCE_PLACEMENT_FILE"; fence_placement="$THREAD_FILE_VALUE"
  case "$fence_placement" in 1|2|3|4|5|6) ;; *) fence_placement=2 ;; esac
  "$THREADCTL" apply "$launcher_pid" "$THREAD_PERF_MASK" "$THREAD_MID_MASK" \
    "$THREAD_LITTLE_MASK" "$THREAD_RENDER_MASK" "$THREAD_PRIME_MASK" \
    "$THREAD_SECONDARY_MASK" "$ui_placement" "$raster_placement" \
    "$resmgr_placement" "$fence_placement" 0 0 0 0 >/dev/null 2>&1 ||
    thread_log "thread-affinity-batch-failed launcher_pid=$launcher_pid"
}

read_uclamp_configuration() {
  read_thread_file "$THREAD_RASTER_UCLAMP_FILE"; THREAD_RASTER_MIN="$THREAD_FILE_VALUE"
  read_thread_file "$THREAD_UI_UCLAMP_FILE"; THREAD_UI_MIN="$THREAD_FILE_VALUE"
  read_thread_file "$THREAD_RUST_UCLAMP_FILE"; THREAD_RUST_MIN="$THREAD_FILE_VALUE"
  read_thread_file "$THREAD_RESMGR_UCLAMP_FILE"; THREAD_RESMGR_MIN="$THREAD_FILE_VALUE"
  case "$THREAD_RASTER_MIN" in ''|*[!0-9]*) THREAD_RASTER_MIN=928 ;; esac
  case "$THREAD_UI_MIN" in ''|*[!0-9]*) THREAD_UI_MIN=768 ;; esac
  case "$THREAD_RUST_MIN" in ''|*[!0-9]*) THREAD_RUST_MIN=512 ;; esac
  case "$THREAD_RESMGR_MIN" in ''|*[!0-9]*) THREAD_RESMGR_MIN=384 ;; esac
}

apply_launcher_uclamp_boost() {
  local launcher_pid="$1" ui_placement raster_placement resmgr_placement fence_placement
  apply_launcher_base_affinity "$launcher_pid"
  read_thread_file "$THREAD_PLACEMENT_FILE"; ui_placement="$THREAD_FILE_VALUE"
  case "$ui_placement" in 1|2|3|4|5|6) ;; *) ui_placement=2 ;; esac
  read_thread_file "$THREAD_RASTER_PLACEMENT_FILE"; raster_placement="$THREAD_FILE_VALUE"
  case "$raster_placement" in 1|2|3|4|5|6) ;; *) raster_placement=4 ;; esac
  read_thread_file "$THREAD_RESMGR_PLACEMENT_FILE"; resmgr_placement="$THREAD_FILE_VALUE"
  case "$resmgr_placement" in 1|2|3|4|5|6) ;; *) resmgr_placement=2 ;; esac
  read_thread_file "$THREAD_FENCE_PLACEMENT_FILE"; fence_placement="$THREAD_FILE_VALUE"
  case "$fence_placement" in 1|2|3|4|5|6) ;; *) fence_placement=2 ;; esac
  read_uclamp_configuration
  "$THREADCTL" apply "$launcher_pid" "$THREAD_PERF_MASK" "$THREAD_MID_MASK" \
    "$THREAD_LITTLE_MASK" "$THREAD_RENDER_MASK" "$THREAD_PRIME_MASK" \
    "$THREAD_SECONDARY_MASK" "$ui_placement" "$raster_placement" \
    "$resmgr_placement" "$fence_placement" "$THREAD_RASTER_MIN" \
    "$THREAD_UI_MIN" "$THREAD_RUST_MIN" \
    "$THREAD_RESMGR_MIN" >/dev/null 2>&1 ||
    thread_log "thread-boost-batch-failed launcher_pid=$launcher_pid"
}

increment_thread_boost_serial() {
  local value
  read_thread_file "$THREAD_BOOST_SERIAL_FILE"; value="$THREAD_FILE_VALUE"
  case "$value" in ''|*[!0-9]*) value=0 ;; esac
  value=$((value + 1))
  echo "$value" >"$THREAD_BOOST_SERIAL_FILE"
  echo "$value"
}

trigger_launcher_thread_boost() {
  local launcher_pid="$1" reason="$2" serial boost_ms
  thread_policy_enabled || return 0
  [ -d "/proc/$launcher_pid/task" ] || return 0
  serial="$(increment_thread_boost_serial)"
  apply_launcher_uclamp_boost "$launcher_pid"
  thread_log "thread-boost serial=$serial reason=$reason"
  (
    read_thread_file "$THREAD_BOOST_MS_FILE"; boost_ms="$THREAD_FILE_VALUE"
    case "$boost_ms" in ''|*[!0-9]*) boost_ms=1 ;; esac
    sleep_milliseconds "$boost_ms"
    read_thread_file "$THREAD_BOOST_SERIAL_FILE"
    [ "$THREAD_FILE_VALUE" = "$serial" ] || exit 0
    reset_launcher_boost "$launcher_pid"
    thread_log "thread-boost-reset serial=$serial"
  ) &
}
