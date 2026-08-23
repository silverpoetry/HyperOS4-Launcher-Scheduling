#!/system/bin/sh

set -eu

state=/data/local/tmp/hyperos4-frequency-ab-original.txt
policy=/sys/devices/system/cpu/cpufreq/policy0

read -r original <"$policy/scaling_max_freq"
printf '%s\n' "$original" >"$state"
am force-stop com.omarea.vtools
sleep 1
read -r hardware_max <"$policy/cpuinfo_max_freq"
echo "$hardware_max" >"$policy/scaling_max_freq"
sleep 2
read -r current <"$policy/scaling_max_freq"
echo "original_khz=$original"
echo "test_khz=$current"
echo "vtools_pid=$(pidof com.omarea.vtools 2>/dev/null)"
