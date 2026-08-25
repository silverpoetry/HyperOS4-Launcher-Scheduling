#!/system/bin/sh

set -u
module=/data/adb/modules/hyperos4_recents_source_app_yield
runtime=/dev/.hyperos4-launcher-scheduling
config=/data/adb/hyperos4-launcher-scheduling

echo '[processes]'
ps -A -o PID,PPID,ARGS | while read -r pid ppid args; do
  case "$args" in
    *"$module/service.sh"*|*launcher-logwatch*|*source-guard*daemon*)
      printf '%s %s %s\n' "$pid" "$ppid" "$args"
      ;;
  esac
done

echo '[coordinator]'
[ -r "$runtime/coordinator.status" ] && cat "$runtime/coordinator.status" || echo missing

echo '[source-guard]'
[ -r "$runtime/source-guard.status" ] && cat "$runtime/source-guard.status" || echo missing

echo '[runtime-config]'
[ -r "$runtime/coordinator.config" ] && cat "$runtime/coordinator.config" || echo missing

echo '[persistent-config]'
for name in state schema-version visual-quiet-ms reassert-interval-ms \
  source-placement source-nice-suppression launcher-placement raster-placement \
  systemui-critical-placement system-server-critical-placement \
  system-server-snapshot-placement; do
  value=""
  [ -r "$config/$name" ] && IFS= read -r value <"$config/$name"
  printf '%s=%s\n' "$name" "$value"
done

echo '[obsolete-runtime]'
for path in launcher-threadctl systemui-threadctl; do
  [ -e "$module/bin/$path" ] && echo "present=$path" || echo "absent=$path"
done

echo '[log-tail]'
tail -n 40 /data/local/tmp/hyperos4-launcher-scheduling.log 2>/dev/null
