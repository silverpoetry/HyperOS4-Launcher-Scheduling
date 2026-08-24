#!/system/bin/sh

MODDIR=${0%/*}
. "$MODDIR/lib/config.sh"
. "$MODDIR/lib/runtime.sh"

initialize_configuration || { echo 'Configuration storage is unavailable.' >&2; exit 1; }

read_first_line "$ENABLE_FILE"
if [ "$READ_VALUE" = enabled ]; then
  echo disabled >"$ENABLE_FILE"
  echo 'Launcher scheduling policy disabled.'
else
  echo enabled >"$ENABLE_FILE"
  echo 'Launcher scheduling policy enabled.'
fi

restart_daemon || { echo 'Failed to restart scheduling service.' >&2; exit 1; }
echo
tail -n 30 "$LOG_FILE" 2>/dev/null
