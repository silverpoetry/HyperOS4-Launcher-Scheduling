#!/system/bin/sh

set -eu

pid="${1:?usage: test-source-guard-thread.sh PID}"
module=/data/adb/modules/hyperos4_recents_source_app_yield
guard="$module/bin/source-guard"
uid="$(stat -c %u "/proc/$pid")"
suppression="$(cat /data/adb/hyperos4-launcher-scheduling/source-nice-suppression 2>/dev/null || echo 40)"
if [ "$suppression" -ge 40 ]; then
  expected_nice=19
else
  expected_nice=$((suppression - 20))
fi
tid=

for task in "/proc/$pid/task/"*; do
  candidate="${task##*/}"
  if [ "$candidate" != "$pid" ]; then
    tid="$candidate"
    break
  fi
done

[ -n "$tid" ] || {
  echo "result=no-worker-thread"
  exit 2
}

restore() {
  "$guard" restore-top "$pid" >/dev/null 2>&1 || true
}
trap restore EXIT INT TERM

in_source_groups() {
  groups="$(cat "/proc/$pid/task/$tid/cgroup" 2>/dev/null)" || return 1
  case "$groups" in *":cpuset:/hyperos4-source"*) ;; *) return 1 ;; esac
  case "$groups" in *":cpu:/hyperos4-source"*) ;; *) return 1 ;; esac
}

wait_for_source() {
  attempts=0
  while [ "$attempts" -lt 500 ]; do
    in_source_groups && return 0
    attempts=$((attempts + 1))
    sleep 0.001
  done
  return 1
}

"$guard" arm "$pid" "$uid"
"$guard" activate "$pid" "$uid"
wait_for_source || {
  echo "result=activation-timeout pid=$pid tid=$tid"
  exit 3
}

printf '%s\n' "$tid" >/dev/cpuset/top-app/tasks
renice -n 0 -p "$tid" >/dev/null
printf '%s\n' "$tid" >/dev/cpuctl/top-app/tasks

attempts=0
while [ "$attempts" -lt 100 ]; do
  if in_source_groups; then
    observed_nice="$(ps -o TID,NI -T -p "$pid" | awk -v wanted="$tid" '$1 == wanted { print $2; exit }')"
    [ "$observed_nice" = "$expected_nice" ] || {
      echo "result=nice-mismatch pid=$pid tid=$tid expected=$expected_nice observed=$observed_nice"
      exit 5
    }
    echo "result=corrected pid=$pid tid=$tid nice=$observed_nice poll_iterations=$attempts"
    exit 0
  fi
  attempts=$((attempts + 1))
  sleep 0.001
done

echo "result=correction-timeout pid=$pid tid=$tid"
exit 4
