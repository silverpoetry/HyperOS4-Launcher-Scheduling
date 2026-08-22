#!/system/bin/sh

# Count only source-app runtime on CPUs excluded from background during the
# 250-750 ms interval after entering Recents on the Shennong test topology.

CASE_NAME=${1:-case}
SOURCE_PACKAGE=${2:-com.tencent.mm}
SOURCE_ACTIVITY=${3:-com.tencent.mm/.ui.LauncherUI}
OUT="/data/local/tmp/hyperos4-recents-performance-${CASE_NAME}.csv"
META="/data/local/tmp/hyperos4-recents-performance-${CASE_NAME}.meta"

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
  echo "before_cgroup=$(grep ':cpuset:' /proc/$SOURCE_PID/cgroup 2>/dev/null)"
} >"$META"
chmod 0644 "$META" 2>/dev/null

input keyevent KEYCODE_APP_SWITCH
sleep 0.25
echo "window_start_cgroup=$(grep ':cpuset:' /proc/$SOURCE_PID/cgroup 2>/dev/null)" >>"$META"
simpleperf stat -p "$SOURCE_PID" --cpu 2-4,7 -e task-clock --duration 0.5 --csv --per-core -o "$OUT"
chmod 0644 "$OUT" 2>/dev/null
echo "window_end_cgroup=$(grep ':cpuset:' /proc/$SOURCE_PID/cgroup 2>/dev/null)" >>"$META"

input keyevent KEYCODE_BACK
sleep 1
echo done >>"$META"
