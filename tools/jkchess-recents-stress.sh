#!/system/bin/sh

set -eu

size="$(wm size | sed -n 's/.*Physical size: //p' | tail -n 1)"
width=${size%x*}
height=${size#*x}
if [ "$width" -lt "$height" ]; then
  swap=$width
  width=$height
  height=$swap
fi

card_x=$((width * 83 / 100))
card_y=$((height * 25 / 100))
mark() {
  read -r uptime rest </proc/uptime
  echo "phase=$1 uptime=$uptime"
}

mark stress_start
round=1
while [ "$round" -le 4 ]; do
  mark "round_${round}_before_gesture"
  "${0%/*}/three-finger-swipe" 480
  mark "round_${round}_after_gesture"
  sleep 1.35
  input tap "$card_x" "$card_y"
  mark "round_${round}_after_tap"
  sleep 1.50
  round=$((round + 1))
done
mark stress_complete
