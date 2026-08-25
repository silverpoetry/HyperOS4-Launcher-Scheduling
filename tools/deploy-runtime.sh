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
[ -x "$STAGE/bin/source-guard" ]

for script in "$STAGE/service.sh" "$STAGE/action.sh" "$STAGE/uninstall.sh" \
  "$STAGE/webui.sh" "$STAGE/lib"/*.sh; do
  /system/bin/sh -n "$script"
done

. "$STAGE/lib/config.sh"
. "$STAGE/lib/runtime.sh"
. "$STAGE/lib/source-guard.sh"
promote_controller_process
snapshot_source_guard || true
rm -f "$RESTART_PHASE_CONTEXT_FILE" "$RESTART_SOURCE_CONTEXT_FILE"
if [ -r "$COORDINATOR_STATUS" ] && [ -r "$SOURCE_FILE" ] &&
   grep -q '^phase=recents$' "$COORDINATOR_STATUS"; then
  printf 'recents\n' >"$RESTART_PHASE_CONTEXT_FILE"
  cp "$SOURCE_FILE" "$RESTART_SOURCE_CONTEXT_FILE"
fi
for watcher in $(pidof launcher-logwatch 2>/dev/null); do
  kill "$watcher" 2>/dev/null || true
done
sleep 0.10
if [ -S "$SOURCE_GUARD_SOCKET" ] && [ -x "$MODDIR/bin/source-guard" ]; then
  "$MODDIR/bin/source-guard" reset-top >/dev/null 2>&1 || true
fi
cleanup_stale_daemons
[ "$SOURCE_RUNTIME_DIR" = /dev/.hyperos4-launcher-scheduling ] || exit 4
rm -rf "$SOURCE_RUNTIME_DIR"
rm -f "$SERVICE_LOCK_OWNER" "$RESTART_LOCK_OWNER"
rmdir "$SERVICE_LOCK_DIR" "$RESTART_LOCK_DIR" 2>/dev/null || true

mkdir -p "$MODDIR"
cp "$STAGE/module.prop" "$MODDIR/module.prop"
cp "$STAGE/service.sh" "$MODDIR/service.sh"
cp "$STAGE/action.sh" "$MODDIR/action.sh"
cp "$STAGE/uninstall.sh" "$MODDIR/uninstall.sh"
cp "$STAGE/webui.sh" "$MODDIR/webui.sh"

rm -rf "$MODDIR/lib.new" "$MODDIR/bin.new"
mkdir -p "$MODDIR/lib.new" "$MODDIR/bin.new"
cp "$STAGE/lib"/*.sh "$MODDIR/lib.new/"
cp "$STAGE/bin"/* "$MODDIR/bin.new/"
rm -rf "$MODDIR/lib" "$MODDIR/bin"
mv "$MODDIR/lib.new" "$MODDIR/lib"
mv "$MODDIR/bin.new" "$MODDIR/bin"

[ "$MODDIR" = /data/adb/modules/hyperos4_recents_source_app_yield ] || exit 3
rm -rf "$MODDIR/webroot.new"
cp -R "$STAGE/webroot" "$MODDIR/webroot.new"
rm -rf "$MODDIR/webroot"
mv "$MODDIR/webroot.new" "$MODDIR/webroot"

chmod 0755 "$MODDIR/service.sh" "$MODDIR/action.sh" "$MODDIR/uninstall.sh" "$MODDIR/webui.sh"
chmod 0755 "$MODDIR/bin/launcher-logwatch" "$MODDIR/bin/source-guard"
chmod 0644 "$MODDIR/lib"/*.sh

echo runtime_deployed=1
echo "version=$(sed -n 's/^version=//p' "$MODDIR/module.prop" | head -n 1)"
