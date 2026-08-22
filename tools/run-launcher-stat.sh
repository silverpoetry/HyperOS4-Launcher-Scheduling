#!/system/bin/sh

set -eu
output="$1"
launcher_pid="$(pidof com.miui.home 2>/dev/null)"
launcher_pid=${launcher_pid%% *}
tids=""

echo $$ >/dev/cpuset/background/cgroup.procs 2>/dev/null || true
echo $$ >/dev/cpuctl/background/cgroup.procs 2>/dev/null || true

for task in /proc/"$launcher_pid"/task/*; do
  [ -r "$task/comm" ] || continue
  tid=${task##*/}
  IFS= read -r name <"$task/comm"
  case "$name" in
    1.raster|1.ui|rt-launcher-mai|IplrVkResMgr|IplrVkFenceWait)
      if [ -n "$tids" ]; then tids="$tids,$tid"; else tids="$tid"; fi
      ;;
  esac
done

[ -n "$tids" ]
simpleperf stat -t "$tids" --cpu 0-7 -e task-clock --per-core --per-thread --csv \
  --duration 2 -o "$output"
