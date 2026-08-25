#!/system/bin/sh

set -eu

runtime=/dev/.hyperos4-launcher-scheduling
duration=${1:-3}
output=${2:-/data/local/tmp/hyperos4-source-guard-sample.tsv}

pid="$(sed -n 's/^pid=//p' "$runtime/source-guard.status" | head -n 1)"
case "$pid" in
  ''|*[!0-9]*) echo 'source PID is unavailable' >&2; exit 2 ;;
esac

end=$(( $(cut -d. -f1 /proc/uptime) + duration ))
printf 'uptime\tcpuset\tcpuctl\tallowed\tnice\n' >"$output"
while [ "$(cut -d. -f1 /proc/uptime)" -lt "$end" ] &&
      [ -r "/proc/$pid/cgroup" ]; do
  cpuset=-
  cpuctl=-
  while IFS=: read -r hierarchy controllers path; do
    case ",$controllers," in
      *,cpuset,*) cpuset=$path ;;
      *,cpu,*) cpuctl=$path ;;
    esac
  done <"/proc/$pid/cgroup"
  allowed="$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' "/proc/$pid/status")"
  nice="$(ps -p "$pid" -o NI= 2>/dev/null | tr -d ' ')"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(cut -d' ' -f1 /proc/uptime)" \
    "$cpuset" "$cpuctl" "$allowed" "$nice" >>"$output"
  sleep 0.01
done
