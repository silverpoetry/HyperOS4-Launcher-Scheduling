#!/system/bin/sh

set -eu

pid="${1:?source PID is required}"
orientation="${2:?display orientation is required}"
duration="${3:-8}"
base=/data/local/tmp
trace="$base/v52-source-cancel.tsv"

"$base/watch-target-placement.sh" "$pid" "$duration" "$trace" &
sampler_pid=$!
sleep 0.3

"$base/three-finger-swipe" 480 "$orientation"
sleep 1
input keyevent BACK

wait "$sampler_pid"
cat "$trace"
