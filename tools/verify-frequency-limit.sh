#!/system/bin/sh

set -eu

moddir=/data/adb/modules/hyperos4_recents_source_app_yield
gesture=/data/local/tmp/gesture-scenarios-dynamic.sh
samples=/data/local/tmp/hyperos4-frequency-samples.txt

policy="$(awk 'NR == 1 { print $1; exit }' "$moddir/frequency-info" 2>/dev/null)"
[ -n "$policy" ] || { echo "frequency policy not found" >&2; exit 2; }
[ -x "$gesture" ] || { echo "gesture script not found" >&2; exit 3; }

input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
wm dismiss-keyguard >/dev/null 2>&1 || true
am start -W -a android.settings.SETTINGS >/dev/null 2>&1
attempt=0
while [ "$(cat "$moddir/launcher-mode" 2>/dev/null)" != app ] && [ "$attempt" -lt 50 ]; do
  sleep 0.10
  attempt=$((attempt + 1))
done
sleep 0.50

: >"$samples"
(
  index=0
  while [ "$index" -lt 180 ]; do
    read -r uptime rest </proc/uptime
    read -r maximum <"$policy/scaling_max_freq"
    mode="$(cat "$moddir/launcher-mode" 2>/dev/null)"
    active=0
    [ -r "$moddir/frequency-limit.active" ] && active=1
    printf '%s %s %s %s\n' "$uptime" "$maximum" "$mode" "$active" >>"$samples"
    sleep 0.02
    index=$((index + 1))
  done
) &
sampler=$!

sleep 0.20
"$gesture" slow-recents
wait "$sampler"

echo "policy=$policy"
echo "samples=$samples"
awk '
  NR == 1 { min = $2; max = $2 }
  $2 < min { min = $2 }
  $2 > max { max = $2 }
  $4 == 1 { active += 1 }
  END { printf "min_khz=%s max_khz=%s active_samples=%d total_samples=%d\n", min, max, active, NR }
' "$samples"
tail -n 30 /data/local/tmp/hyperos4-launcher-scheduling.log
