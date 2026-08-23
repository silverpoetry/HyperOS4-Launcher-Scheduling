#!/system/bin/sh

# Optional transition-time little-cluster cap. The feature is disabled by
# default; every write is recorded and restored only if no other scheduler has
# changed the value in the meantime.
restore_frequency_state_quiet() {
  local policy original applied current
  [ -r "$FREQ_STATE_FILE" ] || return 0
  while read -r policy original applied; do
    [ -r "$policy/scaling_max_freq" ] || continue
    IFS= read -r current <"$policy/scaling_max_freq"
    [ "$current" = "$applied" ] && [ -w "$policy/scaling_max_freq" ] &&
      echo "$original" >"$policy/scaling_max_freq" 2>/dev/null
  done <"$FREQ_STATE_FILE"
  rm -f "$FREQ_STATE_FILE" "$FREQ_STATE_FILE.tmp"
}

next_frequency_serial() {
  increment_file "$FREQ_SERIAL_FILE"
}

restore_source_frequency() {
  local reason="$1" policy original applied current restored skipped
  next_frequency_serial >/dev/null
  [ -r "$FREQ_STATE_FILE" ] || return 0
  restored=0
  skipped=0
  while read -r policy original applied; do
    [ -r "$policy/scaling_max_freq" ] || continue
    IFS= read -r current <"$policy/scaling_max_freq"
    if [ "$current" = "$applied" ] && [ -w "$policy/scaling_max_freq" ]; then
      if echo "$original" >"$policy/scaling_max_freq" 2>/dev/null; then
        restored=$((restored + 1))
      fi
    else
      skipped=$((skipped + 1))
    fi
  done <"$FREQ_STATE_FILE"
  rm -f "$FREQ_STATE_FILE" "$FREQ_STATE_FILE.tmp"
  log_state "frequency-restored reason=$reason restored=$restored skipped=$skipped"
}

select_frequency_limit() {
  local policy="$1" target="$2" value chosen frequencies
  chosen=0
  if [ -r "$policy/scaling_available_frequencies" ]; then
    IFS= read -r frequencies <"$policy/scaling_available_frequencies"
    for value in $frequencies; do
      case "$value" in ''|*[!0-9]*) continue ;; esac
      [ "$value" -le "$target" ] || continue
      [ "$value" -le "$chosen" ] || chosen="$value"
    done
  fi
  [ "$chosen" -gt 0 ] || chosen="$target"
  printf '%s' "$chosen"
}

refresh_frequency_info() {
  local little_value policy related related_compact token policy_mask current maximum
  derive_launcher_masks
  little_value=$((0x$THREAD_LITTLE_MASK))
  : >"$FREQ_INFO_FILE.tmp"
  for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -r "$policy/related_cpus" ] || continue
    IFS= read -r related <"$policy/related_cpus"
    policy_mask="$(cpulist_to_mask "$related")"
    [ -n "$policy_mask" ] || continue
    [ $((0x$policy_mask & little_value)) -ne 0 ] || continue
    [ $((0x$policy_mask & ~little_value)) -eq 0 ] || continue
    related_compact=""
    for token in $related; do
      related_compact="${related_compact}${related_compact:+,}$token"
    done
    IFS= read -r current <"$policy/scaling_max_freq"
    IFS= read -r maximum <"$policy/cpuinfo_max_freq"
    printf '%s %s %s %s\n' "$policy" "$related_compact" "$current" "$maximum" >>"$FREQ_INFO_FILE.tmp"
  done
  mv -f "$FREQ_INFO_FILE.tmp" "$FREQ_INFO_FILE"
}

schedule_frequency_restore() {
  local serial="$1" timeout_ms
  timeout_ms="$(read_bounded_number "$FREQ_TIMEOUT_FILE" 1500 300 5000)"
  (
    sleep_milliseconds "$timeout_ms"
    read_first_line "$FREQ_SERIAL_FILE"
    [ "$READ_VALUE" = "$serial" ] || exit 0
    restore_source_frequency timeout
  ) &
}

apply_source_frequency() {
  local reason="$1" percent policy related recorded_current recorded_maximum
  local original hardware_maximum target applied readback serial count
  config_enabled "$FREQ_POLICY_FILE" || return 0
  config_enabled "$SOURCE_POLICY_FILE" || return 0
  percent="$(read_bounded_number "$FREQ_PERCENT_FILE" 78 40 100)"
  [ "$percent" -lt 100 ] || return 0
  restore_source_frequency reapply
  [ -s "$FREQ_INFO_FILE" ] || refresh_frequency_info
  : >"$FREQ_STATE_FILE.tmp"
  count=0
  while read -r policy related recorded_current recorded_maximum; do
    [ -n "$policy" ] || continue
    [ -r "$policy/scaling_max_freq" ] && [ -w "$policy/scaling_max_freq" ] || continue
    IFS= read -r original <"$policy/scaling_max_freq"
    case "$original" in ''|*[!0-9]*) continue ;; esac
    hardware_maximum="$recorded_maximum"
    case "$hardware_maximum" in
      ''|*[!0-9]*) IFS= read -r hardware_maximum <"$policy/cpuinfo_max_freq" ;;
    esac
    case "$hardware_maximum" in ''|*[!0-9]*) continue ;; esac
    target=$((hardware_maximum * percent / 100))
    applied="$(select_frequency_limit "$policy" "$target")"
    [ "$applied" -lt "$original" ] || continue
    echo "$applied" >"$policy/scaling_max_freq" 2>/dev/null || continue
    IFS= read -r readback <"$policy/scaling_max_freq"
    [ "$readback" = "$applied" ] || continue
    printf '%s %s %s\n' "$policy" "$original" "$applied" >>"$FREQ_STATE_FILE.tmp"
    count=$((count + 1))
  done <"$FREQ_INFO_FILE"
  if [ "$count" -eq 0 ]; then
    rm -f "$FREQ_STATE_FILE.tmp"
    log_state "frequency-limit-skipped reason=$reason percent=$percent"
    return 0
  fi
  mv -f "$FREQ_STATE_FILE.tmp" "$FREQ_STATE_FILE"
  serial="$(next_frequency_serial)"
  log_state "frequency-limited reason=$reason percent=$percent policies=$count serial=$serial"
  schedule_frequency_restore "$serial"
}
