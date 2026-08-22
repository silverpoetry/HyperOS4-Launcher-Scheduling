#!/system/bin/sh

set -eu

profile="$1"
case "$profile" in
  1|2) ;;
  *) echo "usage: $0 1|2" >&2; exit 2 ;;
esac

printf '%s\n' "$profile" \
  >/data/adb/modules/hyperos4_recents_source_app_yield/thread-boost-profile
