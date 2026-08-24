#!/system/bin/sh

MODDIR=${0%/*}
. "$MODDIR/lib/config.sh"
. "$MODDIR/lib/runtime.sh"
. "$MODDIR/lib/topology.sh"
. "$MODDIR/lib/launcher-policy.sh"
. "$MODDIR/lib/systemui-policy.sh"
. "$MODDIR/lib/frequency-policy.sh"
. "$MODDIR/lib/process-policy.sh"

read_first_line "$PID_FILE"
[ -n "$READ_VALUE" ] && kill_process_tree "$READ_VALUE"
restore_frequency_state_quiet
[ -x "$SOURCE_AFFINITYCTL" ] && [ -r "$SOURCE_AFFINITY_STATE" ] &&
  "$SOURCE_AFFINITYCTL" restore "$SOURCE_AFFINITY_STATE" >/dev/null 2>&1
restore_launcher_threads
restore_systemui_threads uninstall
restore_processes

rm -f "$LOG_FILE"
rm -f "$MODE_FILE" "$SERIAL_FILE" "$EPOCH_FILE" "$PID_FILE"
rm -f "$SOURCE_FILE" "$SOURCE_FILE.tmp" "$PENDING_SOURCE_FILE" "$PENDING_SOURCE_FILE.tmp"
rm -f "$GESTURE_FILE" "$WALLPAPER_GROUP_FILE" "$MIMD_GROUP_FILE"
rm -f "$SOURCE_AFFINITY_STATE" "$SOURCE_AFFINITY_STATE.tmp" "$SOURCE_AFFINITY_STATE.lock"
rm -f "$FREQ_STATE_FILE" "$FREQ_STATE_FILE.tmp" "$FREQ_INFO_FILE" "$FREQ_INFO_FILE.tmp"
rm -f "$FREQ_SERIAL_FILE"
rm -f "$SYSTEMUI_STATE_FILE" "$SYSTEMUI_STATE_FILE.lock" "$SYSTEMUI_PID_FILE" "$SYSTEMUI_SERIAL_FILE"

[ "$CONFIG_DIR" = /data/adb/hyperos4-launcher-scheduling ] && rm -rf "$CONFIG_DIR"
