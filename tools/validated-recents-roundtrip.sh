#!/system/bin/sh

set -eu

injector="${0%/*}/three-finger-swipe"
orientation=${1:?display orientation is required}
size="$(dumpsys window displays 2>/dev/null |
  sed -n 's/.*DisplayFrames w=\([0-9][0-9]*\) h=\([0-9][0-9]*\).*/\1x\2/p' |
  head -n 1)"
width=${size%x*}
height=${size#*x}
case "$width:$height" in *[!0-9:]*|:|*:|'') exit 3 ;; esac

mark_phase() {
  local uptime rest
  read -r uptime rest </proc/uptime
  printf 'phase=%s uptime=%s\n' "$1" "$uptime"
}

card_x=$((width * 83 / 100))
card_y=$((height * 25 / 100))
sleep 0.5
mark_phase before_recents
"$injector" 480 "$orientation"
mark_phase after_recents_command
sleep 2
mark_phase before_card_tap
input tap "$card_x" "$card_y"
mark_phase after_card_tap
sleep 2
mark_phase complete
