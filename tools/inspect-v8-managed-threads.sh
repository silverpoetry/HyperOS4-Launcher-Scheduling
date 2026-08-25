#!/system/bin/sh

set -eu

if [ "${1:-}" = enter ]; then
  size="$(dumpsys window displays 2>/dev/null |
    sed -n 's/.*DisplayFrames w=\([0-9][0-9]*\) h=\([0-9][0-9]*\).*/\1x\2/p' |
    head -n 1)"
  width=${size%x*}
  height=${size#*x}
  input touchscreen swipe "$((width / 2))" "$((height - 32))" \
    "$((width / 2))" "$((height / 2))" 650 &
  sleep 0.35
fi

inspect_process() {
  process=$1
  pid="$(pidof "$process" | awk '{print $1}')"
  [ -n "$pid" ] || return 0
  echo "[$process pid=$pid]"
  for task in "/proc/$pid/task"/*; do
    tid=${task##*/}
    name="$(cat "$task/comm" 2>/dev/null || true)"
    case "$process:$name" in
      com.miui.home:1.raster|com.miui.home:1.ui|com.miui.home:rt-launcher-mai|com.miui.home:IplrVkResMgr|com.miui.home:IplrVkFenceWait|\
      com.android.systemui:com.android.systemui|com.android.systemui:RenderThread|com.android.systemui:wmshell.main|com.android.systemui:GPU\ completion|com.android.systemui:RE\ Completion|\
      com.android.systemui:HeapTaskDaemon|com.android.systemui:FinalizerDaemon|com.android.systemui:FinalizerWatchd*|com.android.systemui:ReferenceQueueD*|com.android.systemui:Jit\ thread\ pool|com.android.systemui:Profile\ Saver|\
      system_server:android.anim|system_server:android.display|system_server:TaskSnapshot*)
        allowed="$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' "$task/status")"
        cpuset="$(awk -F: '$2 == "cpuset" {print $3}' "$task/cgroup")"
        printf 'tid=%s name=%s allowed=%s cpuset=%s\n' "$tid" "$name" "$allowed" "$cpuset"
        ;;
    esac
  done
}

inspect_process com.miui.home
inspect_process com.android.systemui
inspect_process system_server
