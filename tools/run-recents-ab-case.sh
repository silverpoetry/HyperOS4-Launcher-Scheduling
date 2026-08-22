#!/system/bin/sh

# One short Recents A/B case. Run as root. The sampler moves itself to the
# device-defined background groups and terminates after the transition.

CASE_NAME=${1:-case}
SOURCE_PACKAGE=${2:-com.miui.weather2}
SOURCE_ACTIVITY=${3:-com.miui.weather2/.ActivityWeatherMain}
OUT="/data/local/tmp/hyperos4-recents-ab-${CASE_NAME}.txt"

echo $$ >/dev/cpuset/background/cgroup.procs 2>/dev/null
echo $$ >/dev/cpuctl/background/cgroup.procs 2>/dev/null

: >"$OUT"
chmod 0644 "$OUT" 2>/dev/null
exec >>"$OUT" 2>&1

group_path() {
  local pid="$1"
  local controller="$2"
  local controllers path
  GROUP_RESULT=gone
  [ -r "/proc/$pid/cgroup" ] || return
  while IFS=: read -r _ controllers path; do
    case ",$controllers," in
      *",$controller,"*)
        GROUP_RESULT="$path"
        return
        ;;
    esac
  done <"/proc/$pid/cgroup"
}

process_ticks() {
  local pid="$1"
  local line rest
  TICK_RESULT=0
  [ -r "/proc/$pid/stat" ] || return
  IFS= read -r line <"/proc/$pid/stat"
  rest=${line#*) }
  set -- $rest
  TICK_RESULT=$((${12:-0} + ${13:-0}))
}

snapshot() {
  local label="$1"
  local uptime source_ticks launcher_ticks systemui_ticks wallpaper_ticks sf_ticks
  IFS=' ' read -r uptime _ </proc/uptime
  process_ticks "$SOURCE_PID"; source_ticks=$TICK_RESULT
  process_ticks "$LAUNCHER_PID"; launcher_ticks=$TICK_RESULT
  process_ticks "$SYSTEMUI_PID"; systemui_ticks=$TICK_RESULT
  process_ticks "$WALLPAPER_PID"; wallpaper_ticks=$TICK_RESULT
  process_ticks "$SF_PID"; sf_ticks=$TICK_RESULT
  group_path "$SOURCE_PID" cpuset; source_cpuset=$GROUP_RESULT
  group_path "$WALLPAPER_PID" cpuset; wallpaper_cpuset=$GROUP_RESULT
  printf 'sample label=%s uptime=%s source_ticks=%s launcher_ticks=%s systemui_ticks=%s wallpaper_ticks=%s sf_ticks=%s source_cpuset=%s wallpaper_cpuset=%s\n' \
    "$label" "$uptime" "$source_ticks" "$launcher_ticks" "$systemui_ticks" \
    "$wallpaper_ticks" "$sf_ticks" "$source_cpuset" "$wallpaper_cpuset"
}

watch_groups() {
  local old current uptime i
  echo $$ >/dev/cpuset/background/cgroup.procs 2>/dev/null
  echo $$ >/dev/cpuctl/background/cgroup.procs 2>/dev/null
  old=
  i=0
  while [ "$i" -lt 55 ]; do
    IFS=' ' read -r uptime _ </proc/uptime
    group_path "$SOURCE_PID" cpuset; source_group=$GROUP_RESULT
    group_path "$WALLPAPER_PID" cpuset; wallpaper_group=$GROUP_RESULT
    current="$source_group $wallpaper_group"
    if [ "$current" != "$old" ]; then
      printf 'cgroup uptime=%s source=%s wallpaper=%s\n' "$uptime" "$source_group" "$wallpaper_group"
      old=$current
    fi
    sleep 0.05
    i=$((i + 1))
  done
}

echo "case=$CASE_NAME"
echo "module_state=$(cat /data/adb/modules/hyperos4_recents_source_app_yield/state 2>/dev/null)"
echo "background_cpus=$(cat /dev/cpuset/background/cpus 2>/dev/null)"

am start -W -n "$SOURCE_ACTIVITY" >/dev/null 2>&1
sleep 3

SOURCE_PID=$(pidof "$SOURCE_PACKAGE" 2>/dev/null | cut -d' ' -f1)
LAUNCHER_PID=$(pidof com.miui.home 2>/dev/null | cut -d' ' -f1)
SYSTEMUI_PID=$(pidof com.android.systemui 2>/dev/null | cut -d' ' -f1)
WALLPAPER_PID=$(pidof com.miui.miwallpaper 2>/dev/null | cut -d' ' -f1)
SF_PID=$(pidof surfaceflinger 2>/dev/null | cut -d' ' -f1)

echo "pids source=$SOURCE_PID launcher=$LAUNCHER_PID systemui=$SYSTEMUI_PID wallpaper=$WALLPAPER_PID sf=$SF_PID"

snapshot before
group_path "$SOURCE_PID" cpuset
if [ "$GROUP_RESULT" != "/top-app" ]; then
  echo "ERROR source is not top-app before Recents: $GROUP_RESULT"
  exit 2
fi
watch_groups &
WATCH_PID=$!
input keyevent KEYCODE_APP_SWITCH
snapshot input_done
sleep 0.25
snapshot plus_250ms
sleep 0.25
snapshot plus_500ms
sleep 0.50
snapshot plus_1000ms
sleep 0.50
snapshot plus_1500ms
wait "$WATCH_PID"
snapshot end

input keyevent KEYCODE_BACK
sleep 1
snapshot resumed
echo done
