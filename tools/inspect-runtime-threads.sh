#!/system/bin/sh

set -eu

for process in launcher-logwatch source-guard; do
  pid="$(pidof "$process" | cut -d' ' -f1)"
  [ -n "$pid" ] || continue
  for task in /proc/"$pid"/task/*; do
    tid=${task##*/}
    name="$(cat "$task/comm")"
    nice="$(awk '{print $19}' "$task/stat")"
    allowed="$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' "$task/status")"
    printf 'process=%s tid=%s name=%s nice=%s cpus=%s\n' \
      "$process" "$tid" "$name" "$nice" "$allowed"
  done
done
