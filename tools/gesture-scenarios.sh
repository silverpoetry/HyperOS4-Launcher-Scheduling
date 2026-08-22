#!/system/bin/sh

scenario="$1"

case "$scenario" in
  fast-home)
    input touchscreen swipe 540 2380 540 650 180
    ;;
  slow-recents)
    input touchscreen swipe 540 2380 540 1250 750
    ;;
  cancel-half)
    input touchscreen motionevent DOWN 540 2380
    sleep 0.04
    input touchscreen motionevent MOVE 540 2220
    sleep 0.04
    input touchscreen motionevent MOVE 540 2040
    sleep 0.04
    input touchscreen motionevent MOVE 540 1880
    sleep 0.20
    input touchscreen motionevent MOVE 540 2040
    sleep 0.04
    input touchscreen motionevent MOVE 540 2220
    sleep 0.04
    input touchscreen motionevent MOVE 540 2360
    input touchscreen motionevent UP 540 2380
    ;;
  open-home-file-manager)
    input keyevent HOME
    sleep 1
    input tap 159 1817
    ;;
  open-recents-center)
    input tap 540 1100
    ;;
  *)
    echo "unknown scenario: $scenario" >&2
    exit 2
    ;;
esac
