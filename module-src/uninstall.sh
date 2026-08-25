#!/system/bin/sh

MODDIR=${0%/*}
. "$MODDIR/lib/config.sh"
. "$MODDIR/lib/runtime.sh"
. "$MODDIR/lib/topology.sh"
. "$MODDIR/lib/source-guard.sh"

read_first_line "$PID_FILE"
[ -n "$READ_VALUE" ] && kill_process_tree "$READ_VALUE"
stop_source_guard
remove_source_groups

rm -f "$LOG_FILE" "$MODE_FILE" "$SERIAL_FILE" "$PID_FILE"
rm -f "$SOURCE_FILE" "$SOURCE_FILE.tmp" "$COORDINATOR_CONFIG" \
  "$COORDINATOR_CONFIG.tmp" "$COORDINATOR_STATUS"
rm -f "$SERVICE_LOCK_OWNER" "$RESTART_LOCK_OWNER"
rmdir "$SERVICE_LOCK_DIR" "$RESTART_LOCK_DIR" "$SOURCE_RUNTIME_DIR" 2>/dev/null || true

[ "$CONFIG_DIR" = /data/adb/hyperos4-launcher-scheduling ] && rm -rf "$CONFIG_DIR"
