#!/system/bin/sh

# Shared paths and validated configuration defaults. Persistent user choices
# live outside the replaceable module directory so KernelSU upgrades retain
# them; transition snapshots remain beside the active runtime.
CONFIG_DIR=/data/adb/hyperos4-launcher-scheduling
LOG_FILE=/data/local/tmp/hyperos4-launcher-scheduling.log
PID_FILE="$MODDIR/daemon.pid"
ENABLE_FILE="$CONFIG_DIR/state"
MODE_FILE="$MODDIR/launcher-mode"
SERIAL_FILE="$MODDIR/transition.serial"
EPOCH_FILE="$MODDIR/policy.epoch"
SOURCE_FILE="$MODDIR/source-app"
PENDING_SOURCE_FILE="$MODDIR/pending-source-app"
GESTURE_FILE="$MODDIR/gesture.active"
WALLPAPER_GROUP_FILE="$MODDIR/wallpaper-groups"
MIMD_GROUP_FILE="$MODDIR/mimd-groups"

SOURCE_AFFINITYCTL="$MODDIR/bin/source-affinityctl"
SOURCE_AFFINITY_STATE="$MODDIR/source-affinity.state"
SOURCE_POLICY_FILE="$CONFIG_DIR/source-policy.state"
AUX_POLICY_FILE="$CONFIG_DIR/aux-policy.state"

FREQ_POLICY_FILE="$CONFIG_DIR/frequency-policy.state"
FREQ_PERCENT_FILE="$CONFIG_DIR/frequency-limit-percent"
FREQ_TIMEOUT_FILE="$CONFIG_DIR/frequency-timeout-ms"
FREQ_STATE_FILE="$MODDIR/frequency-limit.active"
FREQ_INFO_FILE="$MODDIR/frequency-info"
FREQ_SERIAL_FILE="$MODDIR/frequency.serial"
APP_FALLBACK_MS_FILE="$CONFIG_DIR/app-fallback-ms"

TASKSET=/system/bin/taskset
UCLAMPSET=/system/bin/uclampset
THREADCTL="$MODDIR/bin/launcher-threadctl"
THREAD_SNAPSHOT_FILE="$MODDIR/launcher-thread-original"
THREAD_LAUNCHER_PID_FILE="$MODDIR/launcher-thread-pid"
THREAD_BOOST_SERIAL_FILE="$MODDIR/launcher-thread-boost.serial"
THREAD_POLICY_STATE_FILE="$CONFIG_DIR/thread-policy.state"
THREAD_PLACEMENT_FILE="$CONFIG_DIR/launcher-placement"
THREAD_FENCE_PLACEMENT_FILE="$CONFIG_DIR/fence-placement"
THREAD_BOOST_MS_FILE="$CONFIG_DIR/boost-duration-ms"
THREAD_RASTER_UCLAMP_FILE="$CONFIG_DIR/uclamp-raster"
THREAD_UI_UCLAMP_FILE="$CONFIG_DIR/uclamp-ui"
THREAD_RUST_UCLAMP_FILE="$CONFIG_DIR/uclamp-rust"
THREAD_RESMGR_UCLAMP_FILE="$CONFIG_DIR/uclamp-resmgr"
THREAD_TOPOLOGY_FILE="$MODDIR/launcher-thread-topology"
THREAD_TOPOLOGY_INPUT_FILE="$MODDIR/launcher-thread-topology.input"

write_default() {
  [ -f "$1" ] || printf '%s\n' "$2" >"$1"
}

migrate_config_file() {
  local legacy="$MODDIR/$1" current="$2"
  if [ ! -e "$current" ] && [ -r "$legacy" ]; then
    cp "$legacy" "$current" || return 1
  fi
  [ -e "$current" ] && rm -f "$legacy"
}

migrate_legacy_configuration() {
  migrate_config_file state "$ENABLE_FILE"
  migrate_config_file source-policy.state "$SOURCE_POLICY_FILE"
  migrate_config_file aux-policy.state "$AUX_POLICY_FILE"
  migrate_config_file frequency-policy.state "$FREQ_POLICY_FILE"
  migrate_config_file frequency-limit-percent "$FREQ_PERCENT_FILE"
  migrate_config_file frequency-timeout-ms "$FREQ_TIMEOUT_FILE"
  migrate_config_file app-fallback-ms "$APP_FALLBACK_MS_FILE"
  migrate_config_file thread-policy.state "$THREAD_POLICY_STATE_FILE"
  migrate_config_file launcher-placement "$THREAD_PLACEMENT_FILE"
  migrate_config_file fence-placement "$THREAD_FENCE_PLACEMENT_FILE"
  migrate_config_file boost-duration-ms "$THREAD_BOOST_MS_FILE"
  migrate_config_file uclamp-raster "$THREAD_RASTER_UCLAMP_FILE"
  migrate_config_file uclamp-ui "$THREAD_UI_UCLAMP_FILE"
  migrate_config_file uclamp-rust "$THREAD_RUST_UCLAMP_FILE"
  migrate_config_file uclamp-resmgr "$THREAD_RESMGR_UCLAMP_FILE"
}

read_first_line() {
  READ_VALUE=""
  [ -r "$1" ] && IFS= read -r READ_VALUE <"$1"
  return 0
}

config_enabled() {
  read_first_line "$1"
  [ "$READ_VALUE" != disabled ]
}

read_bounded_number() {
  local file="$1" default="$2" minimum="$3" maximum="$4" value
  read_first_line "$file"
  value="$READ_VALUE"
  case "$value" in ''|*[!0-9]*) value="$default" ;; esac
  [ "$value" -ge "$minimum" ] || value="$minimum"
  [ "$value" -le "$maximum" ] || value="$maximum"
  printf '%s' "$value"
}

sleep_milliseconds() {
  local value="$1" seconds millis
  seconds=$((value / 1000))
  millis=$((value % 1000))
  sleep "$(printf '%d.%03d' "$seconds" "$millis")"
}

initialize_configuration() {
  umask 077
  mkdir -p "$CONFIG_DIR" || return 1
  chmod 0700 "$CONFIG_DIR" 2>/dev/null
  migrate_legacy_configuration || return 1
  write_default "$ENABLE_FILE" enabled
  write_default "$SOURCE_POLICY_FILE" enabled
  write_default "$AUX_POLICY_FILE" enabled
  write_default "$THREAD_POLICY_STATE_FILE" enabled
  write_default "$FREQ_POLICY_FILE" disabled
  write_default "$FREQ_PERCENT_FILE" 78
  write_default "$FREQ_TIMEOUT_FILE" 1500
  write_default "$APP_FALLBACK_MS_FILE" 2000
  write_default "$THREAD_PLACEMENT_FILE" 2
  write_default "$THREAD_FENCE_PLACEMENT_FILE" 2
  write_default "$THREAD_BOOST_MS_FILE" 1
  write_default "$THREAD_RASTER_UCLAMP_FILE" 928
  write_default "$THREAD_UI_UCLAMP_FILE" 768
  write_default "$THREAD_RUST_UCLAMP_FILE" 512
  write_default "$THREAD_RESMGR_UCLAMP_FILE" 384
  chmod 0600 "$CONFIG_DIR"/* 2>/dev/null
}
