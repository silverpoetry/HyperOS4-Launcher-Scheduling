#!/system/bin/sh

# Low-overhead sampler for one Android process. It intentionally reads only
# procfs and module state files, avoiding repeated dumpsys calls.

pid="$1"
seconds="${2:-30}"
output="${3:-/data/local/tmp/hyperos4-target-placement.tsv}"
module_dir=/data/adb/modules/hyperos4_recents_source_app_yield

case "$pid" in
  ''|*[!0-9]*) echo "usage: $0 PID [SECONDS] [OUTPUT]" >&2; exit 2 ;;
esac

read_uptime() {
  local now rest
  read -r now rest </proc/uptime
  printf '%s' "$now"
}

read_controller() {
  local controller="$1"
  local hierarchy controllers path
  while IFS=: read -r hierarchy controllers path; do
    case ",$controllers," in
      *",$controller,"*) printf '%s' "$path"; return 0 ;;
    esac
  done <"/proc/$pid/cgroup" 2>/dev/null
  printf '-'
}

read_allowed() {
  local key value rest
  while read -r key value rest; do
    [ "$key" = Cpus_allowed_list: ] && { printf '%s' "$value"; return 0; }
  done <"/proc/$pid/status" 2>/dev/null
  printf '-'
}

read_state() {
  local file="$1"
  local value
  value="$(cat "$file" 2>/dev/null)"
  [ -n "$value" ] || value=-
  printf '%s' "$value"
}

start="$(read_uptime)"
end="$(awk -v start="$start" -v seconds="$seconds" 'BEGIN { printf "%.2f", start + seconds }')"

printf 'uptime\tmode\tepoch\tcpuset\tcpuctl\tallowed\tsource\tpending\n' >"$output"
while [ -d "/proc/$pid" ]; do
  now="$(read_uptime)"
  awk -v now="$now" -v end="$end" 'BEGIN { exit !(now >= end) }' && break
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$now" \
    "$(read_state "$module_dir/launcher-mode")" \
    "$(read_state "$module_dir/policy.epoch")" \
    "$(read_controller cpuset)" \
    "$(read_controller cpu)" \
    "$(read_allowed)" \
    "$(read_state "$module_dir/source-app")" \
    "$(read_state "$module_dir/pending-source-app")" >>"$output"
  sleep 0.05
done

printf '# end=%s pid=%s alive=%s\n' "$(read_uptime)" "$pid" "$([ -d "/proc/$pid" ] && echo 1 || echo 0)" >>"$output"
