#!/system/bin/sh

set -eu

runtime=/dev/.hyperos4-launcher-scheduling
output=/data/local/tmp/hyperos4-v8-cross-card.log
injector=/data/local/tmp/three-finger-swipe
tap_x=${1:?tap X is required}
tap_y=${2:?tap Y is required}

snapshot() {
  label=$1
  printf '\n=== %s %s ===\n' "$label" "$(cut -d' ' -f1 /proc/uptime)"
  cat "$runtime/coordinator.status" 2>/dev/null || true
  cat "$runtime/source-guard.status" 2>/dev/null || true
  for package in com.android.fileexplorer com.android.settings; do
    pid="$(pidof "$package" 2>/dev/null)"
    pid=${pid%% *}
    [ -n "$pid" ] || continue
    printf 'process=%s pid=%s\n' "$package" "$pid"
    sed -n 's/^Cpus_allowed_list:[[:space:]]*/allowed=/p' "/proc/$pid/status"
    tr '\n' ' ' <"/proc/$pid/cgroup"
    echo
    ps -p "$pid" -o PID,NI,NAME 2>/dev/null || true
  done
}

exec >"$output" 2>&1
monkey -p com.android.fileexplorer 1
sleep 1
"$injector" 480 1
sleep 1
snapshot recents
input tap "$tap_x" "$tap_y"
sleep 0.05
snapshot target_50ms
sleep 0.10
snapshot target_150ms
sleep 0.15
snapshot target_300ms
sleep 0.30
snapshot target_600ms
sleep 1
snapshot stable
