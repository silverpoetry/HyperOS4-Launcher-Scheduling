#!/system/bin/sh

set -eu

pid="${1:?source PID is required}"
ctl=/data/adb/modules/hyperos4_recents_source_app_yield/bin/source-affinityctl
state=/data/local/tmp/source-affinity-direct-test.state

uid="$(awk '/^Uid:/ { print $2; exit }' "/proc/$pid/status")"
rm -f "$state" "$state.tmp" "$state.lock"

echo '[before]'
grep Cpus_allowed_list "/proc/$pid/status"
cat "/proc/$pid/cgroup"

echo '[yield]'
"$ctl" yield "$pid" "$uid" "$state"
grep Cpus_allowed_list "/proc/$pid/status"
cat "/proc/$pid/cgroup"

echo "$pid" >/dev/cpuset/top-app/cgroup.procs
echo "$pid" >/dev/cpuctl/top-app/cgroup.procs

echo '[restore]'
"$ctl" restore "$state"
grep Cpus_allowed_list "/proc/$pid/status"
cat "/proc/$pid/cgroup"

rm -f "$state.lock"
