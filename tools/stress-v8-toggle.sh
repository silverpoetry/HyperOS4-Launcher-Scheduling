#!/system/bin/sh

set -eu

rounds=${1:-5}
round=1
while [ "$round" -le "$rounds" ]; do
  input keyevent KEYCODE_APP_SWITCH
  sleep 0.90
  input keyevent KEYCODE_APP_SWITCH
  sleep 1.30
  round=$((round + 1))
done
