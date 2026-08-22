#!/system/bin/sh

# Measure one source application's CPU time per core around a Recents entry.
# The 2 s counter window starts 200 ms before KEYCODE_APP_SWITCH.

CASE_NAME=${1:-case}
SOURCE_PACKAGE=${2:-com.tencent.mm}
SOURCE_ACTIVITY=${3:-com.tencent.mm/.ui.LauncherUI}
OUT="/data/local/tmp/hyperos4-recents-simpleperf-${CASE_NAME}.csv"
META="/data/local/tmp/hyperos4-recents-simpleperf-${CASE_NAME}.meta"

echo $$ >/dev/cpuset/background/cgroup.procs 2>/dev/null
echo $$ >/dev/cpuctl/background/cgroup.procs 2>/dev/null

am start -W -n "$SOURCE_ACTIVITY" >/dev/null 2>&1
sleep 3
SOURCE_PID=$(pidof "$SOURCE_PACKAGE" 2>/dev/null | cut -d' ' -f1)

{
  echo "case=$CASE_NAME"
  echo "module_state=$(cat /data/adb/modules/hyperos4_recents_source_app_yield/state 2>/dev/null)"
  echo "source_pid=$SOURCE_PID"
  echo "background_cpus=$(cat /dev/cpuset/background/cpus 2>/dev/null)"
  echo "foreground_cpus=$(cat /dev/cpuset/foreground/cpus 2>/dev/null)"
  echo "top_app_cpus=$(cat /dev/cpuset/top-app/cpus 2>/dev/null)"
  echo "before_cgroup=$(grep ':cpuset:' /proc/$SOURCE_PID/cgroup 2>/dev/null)"
} >"$META"
chmod 0644 "$META" 2>/dev/null

simpleperf stat -p "$SOURCE_PID" -e task-clock --duration 2 --csv --per-core -o "$OUT" &
PERF_PID=$!
sleep 0.20
input keyevent KEYCODE_APP_SWITCH
wait "$PERF_PID"
chmod 0644 "$OUT" 2>/dev/null

echo "after_cgroup=$(grep ':cpuset:' /proc/$SOURCE_PID/cgroup 2>/dev/null)" >>"$META"
input keyevent KEYCODE_BACK
sleep 1
echo done >>"$META"
