#!/system/bin/sh

set -eu
MODDIR=/data/adb/modules/hyperos4_recents_source_app_yield
STAGE=/data/local/tmp/hyperos4-launcher-scheduling-stage

[ -f "$STAGE/service.sh" ]
[ -f "$STAGE/action.sh" ]
[ -f "$STAGE/uninstall.sh" ]
[ -f "$STAGE/webui.sh" ]
[ -f "$STAGE/module.prop" ]
[ -d "$STAGE/lib" ]
[ -d "$STAGE/webroot" ]
[ -x "$STAGE/bin/launcher-logwatch" ]
[ -x "$STAGE/bin/launcher-threadctl" ]
[ -x "$STAGE/bin/source-affinityctl" ]
[ -x "$STAGE/bin/systemui-threadctl" ]

for script in "$STAGE/service.sh" "$STAGE/action.sh" "$STAGE/uninstall.sh" \
  "$STAGE/webui.sh" "$STAGE/lib"/*.sh; do
  /system/bin/sh -n "$script"
done

. "$STAGE/lib/config.sh"
. "$STAGE/lib/runtime.sh"
read_first_line "$MODDIR/daemon.pid"
[ -n "$READ_VALUE" ] && kill_process_tree "$READ_VALUE"
for watcher_pid in $(pidof launcher-logwatch 2>/dev/null); do
  kill -9 "$watcher_pid" 2>/dev/null || true
done
sleep 1

mkdir -p "$MODDIR/lib" "$MODDIR/bin"
cp "$STAGE/module.prop" "$MODDIR/module.prop"
cp "$STAGE/service.sh" "$MODDIR/service.sh"
cp "$STAGE/action.sh" "$MODDIR/action.sh"
cp "$STAGE/uninstall.sh" "$MODDIR/uninstall.sh"
cp "$STAGE/webui.sh" "$MODDIR/webui.sh"
cp "$STAGE/lib"/*.sh "$MODDIR/lib/"
cp "$STAGE/bin/launcher-logwatch" "$MODDIR/bin/launcher-logwatch"
cp "$STAGE/bin/launcher-threadctl" "$MODDIR/bin/launcher-threadctl"
cp "$STAGE/bin/source-affinityctl" "$MODDIR/bin/source-affinityctl"
cp "$STAGE/bin/systemui-threadctl" "$MODDIR/bin/systemui-threadctl"

[ "$MODDIR" = /data/adb/modules/hyperos4_recents_source_app_yield ] || exit 3
rm -rf "$MODDIR/webroot.new"
cp -R "$STAGE/webroot" "$MODDIR/webroot.new"
rm -rf "$MODDIR/webroot"
mv "$MODDIR/webroot.new" "$MODDIR/webroot"

chmod 0755 "$MODDIR/service.sh" "$MODDIR/action.sh" "$MODDIR/uninstall.sh" "$MODDIR/webui.sh"
chmod 0755 "$MODDIR/bin/launcher-logwatch" "$MODDIR/bin/launcher-threadctl" "$MODDIR/bin/source-affinityctl" "$MODDIR/bin/systemui-threadctl"
chmod 0644 "$MODDIR/lib"/*.sh
find "$MODDIR/webroot" -type d -exec chmod 0755 {} \;
find "$MODDIR/webroot" -type f -exec chmod 0644 {} \;
rm -f "$MODDIR/thread-policy.sh"

nohup /system/bin/sh "$MODDIR/service.sh" >/dev/null 2>&1 &
sleep 2

echo runtime_deployed=1
echo "daemon_pid=$(cat "$MODDIR/daemon.pid" 2>/dev/null)"
echo "version=$(sed -n 's/^version=//p' "$MODDIR/module.prop" | head -n 1)"
