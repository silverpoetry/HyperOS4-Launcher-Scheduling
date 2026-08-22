#!/system/bin/sh

set -eu

output="$1"
duration="$2"
shift 2
snapshot="${output}.start"
: >"$snapshot"

for pid in "$@"; do
  [ -r "/proc/$pid/stat" ] || continue
  ticks="$(awk '{print $14 + $15}' "/proc/$pid/stat")"
  printf '%s %s\n' "$pid" "$ticks" >>"$snapshot"
done

sleep "$duration"
: >"$output"
while read -r pid start_ticks; do
  [ -r "/proc/$pid/stat" ] || continue
  end_ticks="$(awk '{print $14 + $15}' "/proc/$pid/stat")"
  printf '%s %s\n' "$pid" "$((end_ticks - start_ticks))" >>"$output"
done <"$snapshot"
rm -f "$snapshot"
