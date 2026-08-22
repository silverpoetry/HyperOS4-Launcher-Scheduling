#!/system/bin/sh

set -eu

scenario="$1"
size="$(dumpsys window displays 2>/dev/null |
  sed -n 's/.*DisplayFrames w=\([0-9][0-9]*\) h=\([0-9][0-9]*\).*/\1x\2/p' |
  head -n 1)"
[ -n "$size" ] || size="$(wm size | sed -n 's/.*size: //p' | tail -n 1)"
width=${size%x*}
height=${size#*x}
case "$width:$height" in *[!0-9:]*|:|*:|'') exit 3 ;; esac

x=$((width / 2))
bottom=$((height - 24))
high=$((height * 28 / 100))
middle=$((height * 53 / 100))
move1=$((height * 88 / 100))
move2=$((height * 76 / 100))

case "$scenario" in
  fast-home)
    input touchscreen swipe "$x" "$bottom" "$x" "$high" 180
    ;;
  slow-recents)
    input touchscreen swipe "$x" "$bottom" "$x" "$middle" 750
    ;;
  cancel-half)
    input touchscreen motionevent DOWN "$x" "$bottom"
    sleep 0.04
    input touchscreen motionevent MOVE "$x" "$move1"
    sleep 0.04
    input touchscreen motionevent MOVE "$x" "$move2"
    sleep 0.20
    input touchscreen motionevent MOVE "$x" "$move1"
    sleep 0.04
    input touchscreen motionevent UP "$x" "$bottom"
    ;;
  *)
    echo "unknown scenario: $scenario" >&2
    exit 2
    ;;
esac
