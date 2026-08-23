#!/system/bin/sh

set -eu
ROOT=${1:?module root is required}

for required in \
  service.sh webui.sh action.sh uninstall.sh module.prop \
  lib/config.sh lib/runtime.sh lib/topology.sh lib/launcher-policy.sh \
  lib/frequency-policy.sh lib/process-policy.sh lib/state-machine.sh lib/events.sh \
  lib/webui-status.sh lib/webui-control.sh \
  webroot/index.html webroot/js/main.js; do
  [ -f "$ROOT/$required" ] || { echo "missing=$required" >&2; exit 1; }
done

for script in "$ROOT"/*.sh "$ROOT/lib"/*.sh; do
  /system/bin/sh -n "$script"
done

[ ! -e "$ROOT/thread-policy.sh" ] || { echo 'legacy=thread-policy.sh' >&2; exit 1; }
[ ! -e "$ROOT/webroot/app.js" ] || { echo 'legacy=webroot/app.js' >&2; exit 1; }
[ ! -e "$ROOT/webroot/styles.css" ] || { echo 'legacy=webroot/styles.css' >&2; exit 1; }

MODDIR="$ROOT"
. "$ROOT/lib/config.sh"
. "$ROOT/lib/runtime.sh"
. "$ROOT/lib/topology.sh"
. "$ROOT/lib/webui-status.sh"
. "$ROOT/lib/webui-control.sh"

[ "$(cpulist_to_mask '0-2,4')" = 17 ]
[ "$(state_value "$ROOT/missing-frequency-state" disabled)" = disabled ]
load_configuration_values
assign_configuration_value frequency_percent=82
[ "$CFG_FREQUENCY_PERCENT" = 82 ]
if assign_configuration_value frequency_percent=5; then
  echo 'accepted=out-of-range-frequency-percent' >&2
  exit 1
fi
if assign_configuration_value unknown_key=1; then
  echo 'accepted=unknown-configuration-key' >&2
  exit 1
fi

echo validation=passed
