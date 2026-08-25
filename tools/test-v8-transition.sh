#!/system/bin/sh

set -eu

runtime=/dev/.hyperos4-launcher-scheduling
injector=/data/local/tmp/three-finger-swipe
output=/data/local/tmp/hyperos4-v8-transition-test.log
orientation=${1:-1}

display_size="$(dumpsys window displays 2>/dev/null |
  sed -n 's/.*DisplayFrames w=\([0-9][0-9]*\) h=\([0-9][0-9]*\).*/\1x\2/p' |
  head -n 1)"
width=${display_size%x*}
height=${display_size#*x}
card_x=$((width * 83 / 100))
card_y=$((height * 25 / 100))

snapshot() {
  label=$1
  uptime="$(cut -d' ' -f1 /proc/uptime)"
  echo "=== $label uptime=$uptime ==="
  cat "$runtime/coordinator.status" 2>/dev/null || echo coordinator=missing
  cat "$runtime/source-guard.status" 2>/dev/null || echo source_guard=missing
  source_pid="$(sed -n 's/^pid=//p' "$runtime/source-guard.status" 2>/dev/null | head -n 1)"
  case "$source_pid" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$source_pid" -gt 0 ] && [ -r "/proc/$source_pid/status" ]; then
        grep -E '^(Name|State|Cpus_allowed_list):' "/proc/$source_pid/status" || true
        printf 'cgroup='
        tr '\n' ' ' <"/proc/$source_pid/cgroup"
        echo
        ps -p "$source_pid" -o PID,NI,NAME 2>/dev/null || true
      fi
      ;;
  esac
}

[ -x "$injector" ]
rm -f "$output"
exec >"$output" 2>&1

snapshot before_entry
"$injector" 480 "$orientation" &
gesture_pid=$!
sleep 0.10
snapshot entry_100ms
wait "$gesture_pid"
sleep 0.20
snapshot recents_200ms
sleep 0.70
snapshot recents_stable

input tap "$card_x" "$card_y"
sleep 0.10
snapshot return_100ms
sleep 0.25
snapshot return_350ms
sleep 0.30
snapshot return_650ms
sleep 0.50
snapshot return_stable

echo '=== runtime-log-tail ==='
tail -n 80 /data/local/tmp/hyperos4-launcher-scheduling.log 2>/dev/null || true
