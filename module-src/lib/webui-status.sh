#!/system/bin/sh

emit() {
  local key="$1"
  shift
  printf '%s=%s\n' "$key" "$*"
}

state_value() {
  local default="${2:-enabled}"
  read_first_line "$1"
  case "$READ_VALUE" in enabled|disabled) ;; *) READ_VALUE="$default" ;; esac
  printf '%s' "$READ_VALUE"
}

number_value() {
  read_first_line "$1"
  case "$READ_VALUE" in ''|*[!0-9]*) READ_VALUE="$2" ;; esac
  printf '%s' "$READ_VALUE"
}

module_version() {
  local line
  [ -r "$MODDIR/module.prop" ] || return 0
  while IFS= read -r line; do
    case "$line" in version=*) printf '%s' "${line#version=}"; return 0 ;; esac
  done <"$MODDIR/module.prop"
}

read_allowed_list() {
  local key value rest
  [ -r "$1" ] || return 0
  while read -r key value rest; do
    [ "$key" = Cpus_allowed_list: ] && { printf '%s' "$value"; return 0; }
  done <"$1"
}

print_frequency_status() {
  local active=0 key value
  if config_enabled "$FREQ_POLICY_FILE" && [ -r "$COORDINATOR_STATUS" ]; then
    while IFS='=' read -r key value; do
      [ "$key" = policy_active ] && active="$value"
    done <"$COORDINATOR_STATUS"
  fi
  emit frequency_active "$active"
}

print_cluster_frequencies() {
  local policy name related compact token current minimum maximum hardware governor rows record
  rows=""
  for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -r "$policy/related_cpus" ] || continue
    IFS= read -r related <"$policy/related_cpus"
    compact=""
    for token in $related; do compact="${compact}${compact:+,}$token"; done
    current=""; minimum=""; maximum=""; hardware=""; governor=""
    [ -r "$policy/scaling_cur_freq" ] && IFS= read -r current <"$policy/scaling_cur_freq"
    [ -r "$policy/scaling_min_freq" ] && IFS= read -r minimum <"$policy/scaling_min_freq"
    [ -r "$policy/scaling_max_freq" ] && IFS= read -r maximum <"$policy/scaling_max_freq"
    [ -r "$policy/cpuinfo_max_freq" ] && IFS= read -r hardware <"$policy/cpuinfo_max_freq"
    [ -r "$policy/scaling_governor" ] && IFS= read -r governor <"$policy/scaling_governor"
    name=${policy##*/}
    record="$name|$compact|$current|$minimum|$maximum|$hardware|$governor"
    rows="${rows}${rows:+;}$record"
  done
  emit frequency_clusters "$rows"
}

print_status() {
  local mode daemon_pid daemon_alive launcher_pid topology coordinator_online=0 corrections=0 transition_serial
  local all_mask perf_mask mid_mask little_mask render_mask prime_mask secondary_mask background_mask little_spare_mask
  local source_pid source_uid source_name
  local guard_active=0 guard_tasks=0 guard_reassertions=0 key value

  read_first_line "$MODE_FILE"; mode="$READ_VALUE"; [ -n "$mode" ] || mode=unknown
  transition_serial="$(number_value "$SERIAL_FILE" 0)"
  daemon_pid=""; find_active_service_pid && daemon_pid="$ACTIVE_SERVICE_PID"
  daemon_alive=0; [ -n "$daemon_pid" ] && daemon_alive=1
  launcher_pid="$(pidof com.miui.home 2>/dev/null)"; launcher_pid=${launcher_pid%% *}
  read_first_line "$THREAD_TOPOLOGY_FILE"; topology="$READ_VALUE"
  read -r all_mask perf_mask mid_mask little_mask render_mask prime_mask secondary_mask background_mask little_spare_mask <<EOF
$topology
EOF
  [ -n "$all_mask" ] || all_mask=-
  [ -n "$perf_mask" ] || perf_mask=-
  [ -n "$mid_mask" ] || mid_mask=-
  [ -n "$little_mask" ] || little_mask=-
  [ -n "$render_mask" ] || render_mask=-
  [ -n "$prime_mask" ] || prime_mask=-
  [ -n "$secondary_mask" ] || secondary_mask=-
  [ -n "$background_mask" ] || background_mask=-
  [ -n "$little_spare_mask" ] || little_spare_mask=-
  source_pid=""; source_uid=""; source_name=""
  [ -r "$SOURCE_FILE" ] && read -r source_pid source_uid source_name <"$SOURCE_FILE"
  if [ -r "$SOURCE_GUARD_STATUS" ]; then
    while IFS='=' read -r key value; do
      case "$key" in
        pid) source_pid="$value" ;;
        uid) source_uid="$value" ;;
        package) source_name="$value" ;;
        active) guard_active="$value" ;;
        tasks) guard_tasks="$value" ;;
        reassertions) guard_reassertions="$value" ;;
      esac
    done <"$SOURCE_GUARD_STATUS"
  fi
  if [ -r "$COORDINATOR_STATUS" ]; then
    while IFS='=' read -r key value; do
      case "$key" in
        online) coordinator_online="$value" ;;
        phase) mode="$value" ;;
        sequence) transition_serial="$value" ;;
        corrections) corrections="$value" ;;
      esac
    done <"$COORDINATOR_STATUS"
  fi

  emit version "$(module_version)"
  emit author 'silverpoetry'
  emit master_policy "$(state_value "$ENABLE_FILE")"
  emit source_policy "$(state_value "$SOURCE_POLICY_FILE")"
  emit source_placement "$(number_value "$SOURCE_PLACEMENT_FILE" 7)"
  emit source_nice_suppression "$(number_value "$SOURCE_NICE_SUPPRESSION_FILE" 40)"
  emit auxiliary_policy "$(state_value "$AUX_POLICY_FILE")"
  emit launcher_policy "$(state_value "$THREAD_POLICY_STATE_FILE")"
  emit systemui_policy "$(state_value "$SYSTEMUI_POLICY_STATE_FILE")"
  emit system_server_policy "$(state_value "$SYSTEM_SERVER_POLICY_STATE_FILE")"
  emit frequency_policy "$(state_value "$FREQ_POLICY_FILE" disabled)"
  emit frequency_percent "$(number_value "$FREQ_PERCENT_FILE" 78)"
  emit app_completion_timeout_ms "$(number_value "$APP_COMPLETION_TIMEOUT_FILE" 2000)"
  emit visual_quiet_ms "$(number_value "$VISUAL_QUIET_TIMEOUT_FILE" 450)"
  emit reassert_interval_ms "$(number_value "$POLICY_REASSERT_INTERVAL_FILE" 20)"
  emit launcher_placement "$(number_value "$THREAD_PLACEMENT_FILE" 2)"
  emit raster_placement "$(number_value "$THREAD_RASTER_PLACEMENT_FILE" 4)"
  emit resmgr_placement "$(number_value "$THREAD_RESMGR_PLACEMENT_FILE" 2)"
  emit fence_placement "$(number_value "$THREAD_FENCE_PLACEMENT_FILE" 2)"
  emit systemui_critical_placement "$(number_value "$SYSTEMUI_CRITICAL_PLACEMENT_FILE" 2)"
  emit systemui_maintenance_placement "$(number_value "$SYSTEMUI_MAINTENANCE_PLACEMENT_FILE" 6)"
  emit system_server_critical_placement "$(number_value "$SYSTEM_SERVER_CRITICAL_PLACEMENT_FILE" 2)"
  emit system_server_snapshot_placement "$(number_value "$SYSTEM_SERVER_SNAPSHOT_PLACEMENT_FILE" 6)"
  emit uclamp_raster "$(number_value "$THREAD_RASTER_UCLAMP_FILE" 928)"
  emit uclamp_ui "$(number_value "$THREAD_UI_UCLAMP_FILE" 768)"
  emit uclamp_rust "$(number_value "$THREAD_RUST_UCLAMP_FILE" 512)"
  emit uclamp_resmgr "$(number_value "$THREAD_RESMGR_UCLAMP_FILE" 384)"
  emit mode "$mode"
  emit transition_serial "$transition_serial"
  emit coordinator_online "$coordinator_online"
  emit policy_corrections "$corrections"
  emit daemon_pid "$daemon_pid"
  emit daemon_alive "$daemon_alive"
  emit launcher_pid "$launcher_pid"
  emit all_mask "$all_mask"
  emit perf_mask "$perf_mask"
  emit mid_mask "$mid_mask"
  emit little_mask "$little_mask"
  emit render_mask "$render_mask"
  emit prime_mask "$prime_mask"
  emit secondary_mask "$secondary_mask"
  emit background_mask "$background_mask"
  emit little_spare_mask "$little_spare_mask"
  emit source_pid "$source_pid"
  emit source_uid "$source_uid"
  emit source_name "$source_name"
  emit source_guard_active "$guard_active"
  emit source_guard_tasks "$guard_tasks"
  emit source_guard_reassertions "$guard_reassertions"
  print_frequency_status
  print_cluster_frequencies
}

print_device_info() {
  local source_pid source_uid source_name key value
  source_pid=""; source_uid=""; source_name=""
  [ -r "$SOURCE_FILE" ] && read -r source_pid source_uid source_name <"$SOURCE_FILE"
  if [ -r "$SOURCE_GUARD_STATUS" ]; then
    while IFS='=' read -r key value; do
      [ "$key" = pid ] && source_pid="$value"
    done <"$SOURCE_GUARD_STATUS"
  fi
  emit device "$(getprop ro.product.device)"
  emit model "$(getprop ro.product.model)"
  emit os "$(getprop ro.mi.os.version.name)"
  emit android "$(getprop ro.build.version.release)"
  emit kernel "$(uname -r 2>/dev/null)"
  emit selinux "$(getenforce 2>/dev/null)"
  emit watcher_pids "$(pidof launcher-logwatch 2>/dev/null)"
  emit source_cpuset "$(read_proc_controller "$source_pid" cpuset)"
  emit source_cpuctl "$(read_proc_controller "$source_pid" cpu)"
  emit source_allowed "$(read_allowed_list "/proc/$source_pid/status")"
}

read_proc_controller() {
  local pid="$1" controller="$2" hierarchy controllers path
  [ -r "/proc/$pid/cgroup" ] || return 0
  while IFS=: read -r hierarchy controllers path; do
    case ",$controllers," in *",$controller,"*) printf '%s' "$path"; return 0 ;; esac
  done <"/proc/$pid/cgroup"
}

print_launcher_threads() {
  local launcher_pid task tid name allowed uclamp_min uclamp_max
  launcher_pid="$(pidof com.miui.home 2>/dev/null)"; launcher_pid=${launcher_pid%% *}
  [ -n "$launcher_pid" ] && [ -d "/proc/$launcher_pid/task" ] || return 0
  for task in /proc/"$launcher_pid"/task/*; do
    [ -r "$task/comm" ] || continue
    tid=${task##*/}; IFS= read -r name <"$task/comm"
    case "$name" in 1.raster|1.ui|rt-launcher-mai|IplrVkResMgr|IplrVkFenceWait) ;; *) continue ;; esac
    allowed="$(read_allowed_list "$task/status")"
    uclamp_min="$(awk '/^[[:space:]]*uclamp\.min[[:space:]]*:/ { print $3; exit }' "$task/sched" 2>/dev/null)"
    uclamp_max="$(awk '/^[[:space:]]*uclamp\.max[[:space:]]*:/ { print $3; exit }' "$task/sched" 2>/dev/null)"
    [ -n "$uclamp_min" ] || uclamp_min=-; [ -n "$uclamp_max" ] || uclamp_max=-
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$tid" "$allowed" "$uclamp_min" "$uclamp_max"
  done

  local systemui_pid
  systemui_pid="$(pidof com.android.systemui 2>/dev/null)"; systemui_pid=${systemui_pid%% *}
  [ -n "$systemui_pid" ] && [ -d "/proc/$systemui_pid/task" ] || return 0
  for task in /proc/"$systemui_pid"/task/*; do
    [ -r "$task/comm" ] || continue
    tid=${task##*/}; IFS= read -r name <"$task/comm"
    if [ "$tid" = "$systemui_pid" ]; then
      name=SystemUI/main
    else
      case "$name" in
        RenderThread|wmshell.main|"GPU completion"|"RE Completion"|HeapTaskDaemon|FinalizerDaemon|FinalizerWatchd*|ReferenceQueueD*|"Jit thread pool"|"Profile Saver")
          name="SystemUI/$name"
          ;;
        *) continue ;;
      esac
    fi
    allowed="$(read_allowed_list "$task/status")"
    uclamp_min="$(awk '/^[[:space:]]*uclamp\.min[[:space:]]*:/ { print $3; exit }' "$task/sched" 2>/dev/null)"
    uclamp_max="$(awk '/^[[:space:]]*uclamp\.max[[:space:]]*:/ { print $3; exit }' "$task/sched" 2>/dev/null)"
    [ -n "$uclamp_min" ] || uclamp_min=-; [ -n "$uclamp_max" ] || uclamp_max=-
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$tid" "$allowed" "$uclamp_min" "$uclamp_max"
  done

  local system_server_pid
  system_server_pid="$(pidof system_server 2>/dev/null)"; system_server_pid=${system_server_pid%% *}
  [ -n "$system_server_pid" ] && [ -d "/proc/$system_server_pid/task" ] || return 0
  for task in /proc/"$system_server_pid"/task/*; do
    [ -r "$task/comm" ] || continue
    tid=${task##*/}; IFS= read -r name <"$task/comm"
    case "$name" in android.anim|android.display|TaskSnapshotPers*) ;; *) continue ;; esac
    allowed="$(read_allowed_list "$task/status")"
    uclamp_min="$(awk '/^[[:space:]]*uclamp\.min[[:space:]]*:/ { print $3; exit }' "$task/sched" 2>/dev/null)"
    uclamp_max="$(awk '/^[[:space:]]*uclamp\.max[[:space:]]*:/ { print $3; exit }' "$task/sched" 2>/dev/null)"
    [ -n "$uclamp_min" ] || uclamp_min=-; [ -n "$uclamp_max" ] || uclamp_max=-
    printf 'system_server/%s\t%s\t%s\t%s\t%s\n' "$name" "$tid" "$allowed" "$uclamp_min" "$uclamp_max"
  done
}

print_logs() {
  local count="$1"
  case "$count" in ''|*[!0-9]*) count=100 ;; esac
  [ "$count" -le 200 ] || count=200
  tail -n "$count" "$LOG_FILE" 2>/dev/null
}
