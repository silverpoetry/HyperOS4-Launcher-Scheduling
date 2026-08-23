#!/system/bin/sh

set -eu

state=/data/local/tmp/hyperos4-frequency-ab-original.txt
policy=/sys/devices/system/cpu/cpufreq/policy0

if [ -r "$state" ]; then
  read -r original <"$state"
  echo "$original" >"$policy/scaling_max_freq" 2>/dev/null || true
fi
monkey -p com.omarea.vtools -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 3
rm -f "$state"
echo "restored_khz=$(cat "$policy/scaling_max_freq")"
echo "vtools_pid=$(pidof com.omarea.vtools 2>/dev/null)"
