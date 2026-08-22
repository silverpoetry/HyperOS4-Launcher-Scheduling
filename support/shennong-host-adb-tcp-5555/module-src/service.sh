#!/system/bin/sh

MODDIR=${0%/*}
LOG="$MODDIR/last-service.log"
RESETPROP=/data/adb/ksu/bin/resetprop

exec >"$LOG" 2>&1
echo "Shennong Host ADB TCP 5555 v1"
date 2>/dev/null || true

if [ "$(getprop ro.gsid.image_running)" = "1" ]; then
  echo "SKIP: running a DSU"
  exit 0
fi

if [ "$(getprop ro.product.device)" != "shennong" ] && \
   [ "$(getprop ro.product.odm.device)" != "shennong" ]; then
  echo "SKIP: device is not shennong"
  exit 0
fi

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 180 ]; do
  sleep 1
  i=$((i + 1))
done

if [ ! -x "$RESETPROP" ]; then
  echo "FAIL: resetprop unavailable"
  exit 1
fi

"$RESETPROP" -n service.adb.tcp.port 5555
"$RESETPROP" -n persist.adb.tcp.port 5555
/system/bin/setprop ctl.restart adbd
sleep 2

echo "service.adb.tcp.port=$(getprop service.adb.tcp.port)"
echo "persist.adb.tcp.port=$(getprop persist.adb.tcp.port)"
echo "DONE"
exit 0
