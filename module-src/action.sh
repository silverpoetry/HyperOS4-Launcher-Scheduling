#!/system/bin/sh

MODDIR=${0%/*}
STATEFILE="$MODDIR/state"

kill_tree() {
  local target="$1"
  local child
  [ -d "/proc/$target" ] || return 0
  for child in $(cat "/proc/$target/task/$target/children" 2>/dev/null); do
    kill_tree "$child"
  done
  kill "$target" 2>/dev/null
}

if [ "$(cat "$STATEFILE" 2>/dev/null)" = "enabled" ]; then
  echo disabled >"$STATEFILE"
  echo "Recents external-competitor suppression disabled."
else
  echo enabled >"$STATEFILE"
  echo "Recents external-competitor suppression enabled."
fi

daemon_pid="$(cat "$MODDIR/daemon.pid" 2>/dev/null)"
[ -n "$daemon_pid" ] && kill_tree "$daemon_pid"
sleep 1
nohup /system/bin/sh "$MODDIR/service.sh" >/dev/null 2>&1 &
sleep 1

echo
tail -n 30 /data/local/tmp/sheng-recents-cpu-boost-v1.log 2>/dev/null
