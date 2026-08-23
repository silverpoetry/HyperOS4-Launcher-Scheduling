#!/system/bin/sh

set -eu

mode="${1:-active}"
package=com.tencent.jkchess
base="${0%/*}"

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

resume_source() {
  pids="$(pidof "$package" 2>/dev/null || true)"
  if [ -n "$pids" ]; then
    kill -CONT $pids 2>/dev/null || true
  fi
}

trap resume_source EXIT INT TERM

mark stress_start
round=1
while [ "$round" -le 4 ]; do
  mark "round_${round}_before_gesture"
  if [ "$mode" = frozen ]; then
    pids="$(pidof "$package" 2>/dev/null || true)"
    if [ -z "$pids" ]; then
      echo "source process not found" >&2
      exit 1
    fi
    kill -STOP $pids
    mark "round_${round}_after_stop"
  fi

  "$base/three-finger-swipe" 480
  mark "round_${round}_after_gesture"
  sleep 0.90
  resume_source
  mark "round_${round}_after_resume"
  sleep 0.45
  input tap "$card_x" "$card_y"
  mark "round_${round}_after_tap"
  sleep 1.50
  round=$((round + 1))
done
mark stress_complete

