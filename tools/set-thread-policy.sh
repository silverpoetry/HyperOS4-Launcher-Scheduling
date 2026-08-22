#!/system/bin/sh

set -eu
MODDIR=/data/adb/modules/hyperos4_recents_source_app_yield
requested="$1"
. "$MODDIR/thread-policy.sh"
log_state() { :; }

case "$requested" in
  enabled)
    echo enabled >"$THREAD_POLICY_STATE_FILE"
    launcher_pid="$(pidof com.miui.home 2>/dev/null)"
    launcher_pid=${launcher_pid%% *}
    apply_launcher_base_affinity "$launcher_pid"
    ;;
  disabled)
    echo disabled >"$THREAD_POLICY_STATE_FILE"
    restore_launcher_threads
    ;;
  *)
    echo "expected enabled or disabled" >&2
    exit 2
    ;;
esac

echo "thread_policy=$requested"
