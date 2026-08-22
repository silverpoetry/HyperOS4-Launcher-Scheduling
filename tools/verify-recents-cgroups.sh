#!/system/bin/sh

# Short, self-terminating functional check for the module. It records the
# source app and live wallpaper controller paths before, during, and after one
# Recents transition. No trace service or background sampler is left running.

OUT=/data/local/tmp/hyperos4-recents-cgroup-check.txt
SOURCE_PACKAGE=${1:-com.android.settings}

group_path() {
  local pid="$1"
  local controller="$2"
  local controllers path
  [ -r "/proc/$pid/cgroup" ] || {
    printf 'gone'
    return
  }
  while IFS=: read -r _ controllers path; do
    case ",$controllers," in
      *",$controller,"*)
        printf '%s' "$path"
        return
        ;;
    esac
  done <"/proc/$pid/cgroup"
  printf 'unknown'
}

sample() {
  local label="$1"
  printf '%s uptime=%s source_cpuset=%s source_cpu=%s wallpaper_cpuset=%s wallpaper_cpu=%s\n' \
    "$label" "$(cut -d' ' -f1 /proc/uptime)" \
    "$(group_path "$SOURCE_PID" cpuset)" "$(group_path "$SOURCE_PID" cpu)" \
    "$(group_path "$WALLPAPER_PID" cpuset)" "$(group_path "$WALLPAPER_PID" cpu)"
}

: >"$OUT"
exec >>"$OUT" 2>&1

echo "background_cpus=$(cat /dev/cpuset/background/cpus 2>/dev/null)"
echo "foreground_cpus=$(cat /dev/cpuset/foreground/cpus 2>/dev/null)"
echo "top_app_cpus=$(cat /dev/cpuset/top-app/cpus 2>/dev/null)"

am start -W -a android.settings.SETTINGS >/dev/null 2>&1
sleep 1
SOURCE_PID=$(pidof "$SOURCE_PACKAGE" 2>/dev/null | cut -d' ' -f1)
WALLPAPER_PID=$(pidof com.miui.miwallpaper 2>/dev/null | cut -d' ' -f1)

echo "source_package=$SOURCE_PACKAGE source_pid=$SOURCE_PID wallpaper_pid=$WALLPAPER_PID"
sample before
DISPLAY_SIZE=$(wm size | tail -n 1)
DISPLAY_SIZE=${DISPLAY_SIZE##*: }
DISPLAY_WIDTH=${DISPLAY_SIZE%x*}
DISPLAY_HEIGHT=${DISPLAY_SIZE#*x}
GESTURE_X=$((DISPLAY_WIDTH / 2))
GESTURE_FROM=$((DISPLAY_HEIGHT - 20))
GESTURE_TO=$((DISPLAY_HEIGHT * 5 / 8))
echo "gesture=${GESTURE_X},${GESTURE_FROM}->${GESTURE_X},${GESTURE_TO}"
input swipe "$GESTURE_X" "$GESTURE_FROM" "$GESTURE_X" "$GESTURE_TO" 500

i=0
while [ "$i" -lt 24 ]; do
  sample "recents_$i"
  sleep 0.05
  i=$((i + 1))
done

input keyevent KEYCODE_BACK
sleep 1
sample after_back
echo done
