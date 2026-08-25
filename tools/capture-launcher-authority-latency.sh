#!/system/bin/sh

set -eu

runtime=/dev/.hyperos4-launcher-scheduling
injector=/data/local/tmp/three-finger-swipe
orientation=${1:-1}
output=/data/local/tmp/hyperos4-launcher-authority-latency.tsv
source_pid="$(sed -n 's/^pid=//p' "$runtime/source-guard.status")"

read_coordinator() {
  sequence="" phase="" reason="" event_lag_us=""
  while IFS='=' read -r key value; do
    case "$key" in
      sequence) sequence=$value ;;
      phase) phase=$value ;;
      reason) reason=$value ;;
      last_event_lag_us) event_lag_us=$value ;;
    esac
  done <"$runtime/coordinator.status"
}

read_source() {
  active=""
  while IFS='=' read -r key value; do
    case "$key" in
      active) active=$value ;;
    esac
  done <"$runtime/source-guard.status"
}

read_placement() {
  allowed="" cpuset_group=""
  while IFS=':' read -r key value; do
    if [ "$key" = Cpus_allowed_list ]; then
      allowed=${value#${value%%[![:space:]]*}}
      break
    fi
  done <"/proc/$source_pid/status"
  while IFS=: read -r hierarchy controllers path; do
    if [ "$controllers" = cpuset ]; then
      cpuset_group=$path
      break
    fi
  done <"/proc/$source_pid/cgroup"
  read -r stat_line <"/proc/$source_pid/stat"
  set -- $stat_line
  nice=${19}
}

sample_changes() {
  label=$1
  count=$2
  previous=""
  index=0
  while [ "$index" -lt "$count" ]; do
    read -r uptime _ </proc/uptime
    read_coordinator
    read_source
    read_placement
    signature="$sequence:$phase:$reason:$event_lag_us:$active:$allowed:$cpuset_group:$nice"
    if [ "$signature" != "$previous" ]; then
      printf '%s\t%s\tsequence=%s\tphase=%s\treason=%s\tevent_lag_us=%s\tactive=%s\tallowed=%s\tcpuset=%s\tnice=%s\n' \
        "$label" "$uptime" "$sequence" "$phase" "$reason" "$event_lag_us" \
        "$active" "$allowed" "$cpuset_group" "$nice"
      previous=$signature
    fi
    sleep 0.01
    index=$((index + 1))
  done
}

rm -f "$output"
exec >"$output" 2>&1
printf 'source_pid=%s\n' "$source_pid"
read -r uptime _ </proc/uptime
printf 'entry_start\t%s\n' "$uptime"
"$injector" 480 "$orientation" &
gesture_pid=$!
sample_changes entry 70
wait "$gesture_pid"
sleep 0.4

size="$(dumpsys window displays 2>/dev/null |
  sed -n 's/.*DisplayFrames w=\([0-9][0-9]*\) h=\([0-9][0-9]*\).*/\1x\2/p' |
  head -n 1)"
width=${size%x*}
height=${size#*x}
read -r uptime _ </proc/uptime
printf 'return_start\t%s\n' "$uptime"
input tap "$((width * 83 / 100))" "$((height * 25 / 100))"
sample_changes return 100
