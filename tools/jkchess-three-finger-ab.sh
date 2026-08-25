#!/system/bin/sh

set -eu

rounds=${1:-4}
injector=/data/local/tmp/three-finger-swipe
orientation=1

size="$(dumpsys window displays 2>/dev/null |
  sed -n 's/.*DisplayFrames w=\([0-9][0-9]*\) h=\([0-9][0-9]*\).*/\1x\2/p' |
  head -n 1)"
width=${size%x*}
height=${size#*x}
case "$width:$height" in *[!0-9:]*|:|*:|'') exit 3 ;; esac

card_x=$((width * 83 / 100))
card_y=$((height * 25 / 100))

mark_phase() {
  local uptime rest
  read -r uptime rest </proc/uptime
  printf 'phase=%s uptime=%s\n' "$1" "$uptime"
}

mark_phase stress_start
round=1
while [ "$round" -le "$rounds" ]; do
  mark_phase "round_${round}_before_overview"
  "$injector" 480 "$orientation"
  mark_phase "round_${round}_after_overview_command"
  sleep 0.70
  mark_phase "round_${round}_before_card_tap"
  input tap "$card_x" "$card_y"
  mark_phase "round_${round}_after_card_tap"
  sleep 0.80
  round=$((round + 1))
done
mark_phase stress_complete
