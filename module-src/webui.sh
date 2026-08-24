#!/system/bin/sh

# Narrow command dispatcher for the KernelSU WebUI. No arbitrary shell input
# is accepted; configuration is a fixed set of validated key=value tokens.
MODDIR=${0%/*}

. "$MODDIR/lib/config.sh"
. "$MODDIR/lib/runtime.sh"
. "$MODDIR/lib/webui-status.sh"
. "$MODDIR/lib/webui-control.sh"

initialize_configuration || { echo 'configuration storage is unavailable' >&2; exit 1; }

print_diagnostics() {
  echo '[status]'; print_status
  echo; echo '[device]'; print_device_info
  echo; echo '[threads]'; print_launcher_threads
  echo; echo '[recent log]'; print_logs 120
}

case "$1" in
  status) print_status ;;
  info) print_device_info ;;
  threads) print_launcher_threads ;;
  logs) print_logs "$2" ;;
  diagnostics) print_diagnostics ;;
  configure)
    save_configuration "$@" || { echo 'invalid configuration' >&2; exit 2; }
    ;;
  restart)
    restart_daemon || { echo 'service restart failed' >&2; exit 1; }
    emit ok 1
    ;;
  clear-log)
    : >"$LOG_FILE"
    emit ok 1
    ;;
  *)
    echo "usage: $0 {status|info|threads|logs|diagnostics|configure|restart|clear-log}" >&2
    exit 2
    ;;
esac
