#!/system/bin/sh

cache_pid_record() {
  local pid="$1" package="$2" uid key first rest
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "/proc/$pid/status" ] || return 1
  uid=""
  while read -r key first rest; do
    [ "$key" = Uid: ] && { uid="$first"; break; }
  done <"/proc/$pid/status"
  case "$uid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$uid" -ge 1000 ] || return 1
  printf '%s %s %s\n' "$pid" "$uid" "$package" >"$SOURCE_FILE.tmp" || return 1
  mv -f "$SOURCE_FILE.tmp" "$SOURCE_FILE"
  if config_enabled "$SOURCE_POLICY_FILE"; then
    source_guard_command arm "$pid" "$uid" "$package" >/dev/null 2>&1 || return 1
    log_state "source-armed pid=$pid uid=$uid package=$package"
  fi
}

bootstrap_current_source() {
  local resumed pid hint saved_pid saved_uid saved_package command
  read_first_line "$MODE_FILE"; hint="$READ_VALUE"
  resumed="$(dumpsys activity activities 2>/dev/null |
    sed -n 's/.*ResumedActivity:.* u[0-9][0-9]* \([^/ ]*\).*/\1/p' |
    head -n 1)"
  case "$resumed" in
    ''|com.miui.home|com.android.systemui)
      if [ "$hint" = recents ] && [ -r "$SOURCE_FILE" ]; then
        read -r saved_pid saved_uid saved_package <"$SOURCE_FILE"
        command=""
        [ -r "/proc/$saved_pid/cmdline" ] &&
          command="$(tr '\000' '\n' <"/proc/$saved_pid/cmdline" | head -n 1)"
        if [ -n "$saved_package" ] && [ "$command" = "$saved_package" ] &&
           cache_pid_record "$saved_pid" "$saved_package"; then
          printf 'recents\n' >"$MODE_FILE"
          return 0
        fi
      fi
      rm -f "$SOURCE_FILE" "$SOURCE_FILE.tmp"
      printf 'home\n' >"$MODE_FILE"
      return 0
      ;;
  esac
  pid="$(pidof "$resumed" 2>/dev/null)"
  pid=${pid%% *}
  cache_pid_record "$pid" "$resumed"
}
