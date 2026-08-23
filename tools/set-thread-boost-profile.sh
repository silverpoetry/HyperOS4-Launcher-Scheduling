#!/system/bin/sh

set -eu

placement="$1"
case "$placement" in
  1|2) ;;
  *) echo "usage: $0 1|2" >&2; exit 2 ;;
esac

printf '%s\n' "$placement" \
  >/data/adb/modules/hyperos4_recents_source_app_yield/launcher-placement
