#!/system/bin/sh

set -eu
MODDIR=/data/adb/modules/hyperos4_recents_source_app_yield
STAGE=/data/local/tmp/hyperos4-launcher-scheduling-stage

[ -f "$STAGE/service.sh" ]
[ -f "$STAGE/thread-policy.sh" ]
[ -f "$STAGE/module.prop" ]
[ -x "$STAGE/launcher-logwatch" ]
[ -x "$STAGE/launcher-threadctl" ]

kill_tree() {
  local target="$1"
  local child
  [ -d "/proc/$target" ] || return 0
  for child in $(cat "/proc/$target/task/$target/children" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -9 "$target" 2>/dev/null || true
}

daemon_pid="$(cat "$MODDIR/daemon.pid" 2>/dev/null || true)"
if [ -n "$daemon_pid" ] && [ -d "/proc/$daemon_pid" ]; then
  kill_tree "$daemon_pid"
fi
for watcher_pid in $(pidof launcher-logwatch 2>/dev/null); do
  kill -9 "$watcher_pid" 2>/dev/null || true
done
process_list="$STAGE/module-processes"
ps -A -o PID,ARGS >"$process_list" 2>/dev/null || true
while read -r process_pid process_args; do
  case "$process_args" in
    *"$MODDIR/service.sh"*) kill -9 "$process_pid" 2>/dev/null || true ;;
  esac
done <"$process_list"
rm -f "$process_list"
sleep 1

cp "$STAGE/module.prop" "$MODDIR/module.prop"
cp "$STAGE/service.sh" "$MODDIR/service.sh"
cp "$STAGE/thread-policy.sh" "$MODDIR/thread-policy.sh"
cp "$STAGE/launcher-logwatch" "$MODDIR/bin/launcher-logwatch"
cp "$STAGE/launcher-threadctl" "$MODDIR/bin/launcher-threadctl"
chmod 0755 "$MODDIR/service.sh" "$MODDIR/thread-policy.sh" "$MODDIR/bin/launcher-logwatch" "$MODDIR/bin/launcher-threadctl"

nohup /system/bin/sh "$MODDIR/service.sh" >/dev/null 2>&1 &
sleep 2

echo "runtime_deployed=1"
echo "daemon_pid=$(cat "$MODDIR/daemon.pid" 2>/dev/null)"
echo "version=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null)"
