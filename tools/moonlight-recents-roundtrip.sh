#!/system/bin/sh

set -eu

width="$(wm size | sed -n 's/.*Physical size: \([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1/p')"
height="$(wm size | sed -n 's/.*Physical size: \([0-9][0-9]*\)x\([0-9][0-9]*\).*/\2/p')"
rotation="$(dumpsys window displays | sed -n 's/.*DisplayFrames w=\([0-9][0-9]*\) h=\([0-9][0-9]*\).*/\1x\2/p' | head -n 1)"
case "$rotation" in
  *x*) width=${rotation%x*}; height=${rotation#*x} ;;
esac
case "$width:$height" in *[!0-9:]*|:|*:|'') exit 3 ;; esac

# In the Sheng landscape Recents grid, the current task is the upper-right card.
card_x=$((width * 83 / 100))
card_y=$((height * 25 / 100))
mark_phase() {
  local uptime rest
  read -r uptime rest </proc/uptime
  printf 'phase=%s uptime=%s\n' "$1" "$uptime"
}

sleep 0.70
mark_phase before_recents
"${0%/*}/three-finger-swipe" 480
mark_phase after_recents_command
sleep 2
mark_phase before_card_tap
input tap "$card_x" "$card_y"
mark_phase after_card_tap
sleep 2
mark_phase complete
