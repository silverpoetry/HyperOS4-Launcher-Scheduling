#!/system/bin/sh

MODDIR=/data/adb/modules/hyperos4_recents_source_app_yield
. "$MODDIR/lib/config.sh"
. "$MODDIR/lib/runtime.sh"
. "$MODDIR/lib/topology.sh"
. "$MODDIR/lib/launcher-policy.sh"

launcher_pid="$(pidof com.miui.home 2>/dev/null)"
launcher_pid=${launcher_pid%% *}
derive_launcher_masks
echo "launcher_pid=$launcher_pid"
echo "mode=$(cat "$MODDIR/launcher-mode" 2>/dev/null)"
echo "masks all=$THREAD_ALL_MASK perf=$THREAD_PERF_MASK mid=$THREAD_MID_MASK little=$THREAD_LITTLE_MASK"

for task in /proc/"$launcher_pid"/task/*; do
  [ -r "$task/comm" ] || continue
  tid=${task##*/}
  IFS= read -r name <"$task/comm"
  case "$name" in
    1.raster|1.ui|rt-launcher-mai|IplrVkResMgr|IplrVkFenceWait)
      affinity="$($TASKSET -p "$tid" 2>/dev/null)"
      clamp="$($UCLAMPSET -p "$tid" 2>/dev/null)"
      echo "thread tid=$tid name=$name affinity=${affinity##*: } clamp=${clamp##*util_clamp: }"
      ;;
  esac
done

echo "module_processes:"
ps -A -o PID,PPID,ARGS 2>/dev/null |
  grep hyperos4_recents_source_app_yield |
  grep -v grep
