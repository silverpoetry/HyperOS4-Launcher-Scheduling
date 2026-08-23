#!/system/bin/sh

set -eu

moddir=/data/adb/modules/hyperos4_recents_source_app_yield
gesture="${0%/*}/gesture-scenarios-dynamic.sh"

mark() {
  read -r uptime rest </proc/uptime
  echo "phase=$1 uptime=$uptime"
}

wait_for_app_mode() {
  attempt=0
  while [ "$(cat "$moddir/launcher-mode" 2>/dev/null)" != app ] && [ "$attempt" -lt 40 ]; do
    sleep 0.10
    attempt=$((attempt + 1))
  done
}

am start -W -a android.settings.SETTINGS >/dev/null 2>&1
wait_for_app_mode
sleep 0.60
mark test_start

round=1
while [ "$round" -le 5 ]; do
  mark "round_${round}_entry_start"
  "$gesture" slow-recents
  mark "round_${round}_gesture_end"
  sleep 1.20
  mark "round_${round}_return_start"
  am start -W -a android.settings.SETTINGS >/dev/null 2>&1
  wait_for_app_mode
  mark "round_${round}_app_stable"
  sleep 0.60
  round=$((round + 1))
done

mark test_end
