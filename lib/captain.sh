# lib/captain.sh — Herdr/Pi captain launch guidance and read-only operations.
#
# This adapter deliberately does not own Firstmate lifecycle.  Firstmate's
# session-start script, Pi extensions, lock, and watcher remain authoritative.

FMW_CAPTAIN_MIN_HERDR_PROTOCOL=14
FMW_CAPTAIN_DEFAULT_GUARD_GRACE=300

fmw_captain_shell_quote() { printf '%q' "$1"; }

fmw_captain_pid_alive() {
  case "${1:-}" in ''|*[!0-9]*|0) return 1 ;; esac
  kill -0 "$1" 2>/dev/null
}

fmw_captain_pid_command() {
  local pid="$1" cmd
  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  [ -n "$cmd" ] || cmd="unknown"
  printf '%s' "${cmd:0:240}"
}

fmw_captain_pid_is_current() {
  local target="$1" pid ppid
  case "$target" in ''|*[!0-9]*) return 1 ;; esac
  pid="${BASHPID:-$$}"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$pid" = "$target" ] && return 0
    [ "$pid" -gt 1 ] 2>/dev/null || break
    ppid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null || true)"
    case "$ppid" in ''|*[!0-9]*|1) break ;; esac
    pid="$ppid"
  done
  return 1
}

fmw_captain_process_fm_home() {
  local pid="$1" value
  value="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^FM_HOME=//p' | head -1 || true)"
  printf '%s' "$value"
}

fmw_captain_herdr_probe() {
  FMW_CAPTAIN_HERDR_OK=0
  FMW_CAPTAIN_HERDR_REASON=""
  FMW_CAPTAIN_HERDR_VERSION="unknown"
  FMW_CAPTAIN_HERDR_PROTOCOL="unknown"
  FMW_CAPTAIN_HERDR_SESSION="${HERDR_SESSION:-default}"
  FMW_CAPTAIN_HERDR_SOCKET="${HERDR_SOCKET_PATH:-}"
  FMW_CAPTAIN_HERDR_RUNNING="stopped"

  if [ "${HERDR_ENV:-}" != 1 ]; then
    FMW_CAPTAIN_HERDR_REASON="terminal is not Herdr-managed (HERDR_ENV=1 is absent)"
    return 1
  fi
  local name
  for name in HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID; do
    if [ -z "${!name:-}" ]; then
      FMW_CAPTAIN_HERDR_REASON="${name} is missing from the Herdr-managed terminal"
      return 1
    fi
  done
  if [ ! -e "$HERDR_SOCKET_PATH" ]; then
    FMW_CAPTAIN_HERDR_REASON="Herdr socket is absent: $HERDR_SOCKET_PATH"
    return 1
  fi
  if ! command -v herdr >/dev/null 2>&1; then
    FMW_CAPTAIN_HERDR_REASON="Herdr CLI is missing from PATH"
    return 1
  fi
  FMW_CAPTAIN_HERDR_VERSION="$(herdr --version 2>/dev/null || true)"
  local status_json sessions_json protocol version running socket
  status_json="$(herdr status --json 2>/dev/null || true)"
  if [ -z "$status_json" ] || ! command -v jq >/dev/null 2>&1; then
    FMW_CAPTAIN_HERDR_REASON="could not read Herdr status JSON with jq"
    return 1
  fi
  protocol="$(printf '%s' "$status_json" | jq -r '.client.protocol // empty' 2>/dev/null || true)"
  version="$(printf '%s' "$status_json" | jq -r '.client.version // empty' 2>/dev/null || true)"
  [ -n "$version" ] && FMW_CAPTAIN_HERDR_VERSION="$version"
  FMW_CAPTAIN_HERDR_PROTOCOL="${protocol:-unknown}"
  case "$protocol" in
    ''|*[!0-9]*) FMW_CAPTAIN_HERDR_REASON="Herdr status did not report a numeric client protocol"; return 1 ;;
  esac
  if [ "$protocol" -lt "$FMW_CAPTAIN_MIN_HERDR_PROTOCOL" ]; then
    FMW_CAPTAIN_HERDR_REASON="Herdr protocol $protocol is below the supported minimum $FMW_CAPTAIN_MIN_HERDR_PROTOCOL"
    return 1
  fi
  sessions_json="$(herdr session list --json 2>/dev/null || true)"
  running="$(printf '%s' "$sessions_json" | jq -r --arg session "$FMW_CAPTAIN_HERDR_SESSION" '.sessions[]? | select(.name == $session) | (.running // false)' 2>/dev/null | head -1 || true)"
  socket="$(printf '%s' "$sessions_json" | jq -r --arg session "$FMW_CAPTAIN_HERDR_SESSION" '.sessions[]? | select(.name == $session) | (.socket_path // empty)' 2>/dev/null | head -1 || true)"
  if [ "$running" != true ] || [ -z "$socket" ]; then
    FMW_CAPTAIN_HERDR_REASON="Herdr session '$FMW_CAPTAIN_HERDR_SESSION' is not running or has no socket identity"
    return 1
  fi
  if [ "$socket" != "$HERDR_SOCKET_PATH" ]; then
    FMW_CAPTAIN_HERDR_REASON="Herdr socket does not match the current terminal identity"
    return 1
  fi
  FMW_CAPTAIN_HERDR_RUNNING=running
  FMW_CAPTAIN_HERDR_OK=1
  return 0
}

fmw_captain_extensions() {
  local root="$FMW_CFG_FIRSTMATE_ROOT"
  FMW_CAPTAIN_WATCH_EXTENSION="$root/.pi/extensions/fm-primary-pi-watch.ts"
  FMW_CAPTAIN_GUARD_EXTENSION="$root/.pi/extensions/fm-primary-turnend-guard.ts"
  FMW_CAPTAIN_EXTENSIONS_OK=1
  [ -f "$FMW_CAPTAIN_WATCH_EXTENSION" ] || FMW_CAPTAIN_EXTENSIONS_OK=0
  [ -f "$FMW_CAPTAIN_GUARD_EXTENSION" ] || FMW_CAPTAIN_EXTENSIONS_OK=0
}

fmw_captain_lock_inspect() {
  local home="$FMW_CFG_FM_HOME" lock="$FMW_CFG_FM_HOME/state/.lock" pid
  FMW_CAPTAIN_LOCK_STATE=missing
  FMW_CAPTAIN_LOCK_PID=""
  FMW_CAPTAIN_LOCK_COMMAND=""
  [ -e "$lock" ] || return 0
  if [ ! -f "$lock" ] || [ -L "$lock" ]; then
    FMW_CAPTAIN_LOCK_STATE=malformed
    return 0
  fi
  pid="$(cat "$lock" 2>/dev/null || true)"
  FMW_CAPTAIN_LOCK_PID="$pid"
  case "$pid" in ''|*[!0-9]*|0)
    FMW_CAPTAIN_LOCK_STATE=malformed
    return 0
    ;;
  esac
  if fmw_captain_pid_alive "$pid"; then
    FMW_CAPTAIN_LOCK_COMMAND="$(fmw_captain_pid_command "$pid")"
    if fmw_captain_pid_is_current "$pid"; then
      FMW_CAPTAIN_LOCK_STATE=owned
    else
      FMW_CAPTAIN_LOCK_STATE=other
    fi
  else
    FMW_CAPTAIN_LOCK_STATE=stale
  fi
}

fmw_captain_watcher_inspect() {
  local home="$FMW_CFG_FM_HOME" state="$FMW_CFG_FM_HOME/state" lock="$FMW_CFG_FM_HOME/state/.watch.lock"
  local pid beat home_record watcher_path now mtime age grace
  FMW_CAPTAIN_WATCHER_STATE=absent
  FMW_CAPTAIN_WATCHER_PID=""
  FMW_CAPTAIN_WATCHER_AGE="unknown"
  FMW_CAPTAIN_WATCHER_HOME=""
  [ -d "$lock" ] || return 0
  pid="$(cat "$lock/pid" 2>/dev/null || true)"
  beat="$state/.last-watcher-beat"
  home_record="$(cat "$lock/fm-home" 2>/dev/null || true)"
  watcher_path="$(cat "$lock/watcher-path" 2>/dev/null || true)"
  FMW_CAPTAIN_WATCHER_PID="$pid"
  FMW_CAPTAIN_WATCHER_HOME="$home_record"
  if [ "$home_record" != "$home" ] || [ -n "$watcher_path" ] && [ "$watcher_path" != "$FMW_CFG_FIRSTMATE_ROOT/bin/fm-watch.sh" ]; then
    FMW_CAPTAIN_WATCHER_STATE=mismatch
    return 0
  fi
  if ! fmw_captain_pid_alive "$pid"; then
    FMW_CAPTAIN_WATCHER_STATE=stale
    return 0
  fi
  [ -e "$beat" ] || { FMW_CAPTAIN_WATCHER_STATE=stale; return 0; }
  now="$(date +%s)"; mtime="$(stat -c %Y "$beat" 2>/dev/null || true)"
  case "$mtime" in ''|*[!0-9]*) FMW_CAPTAIN_WATCHER_STATE=stale; return 0 ;; esac
  age=$((now - mtime)); [ "$age" -ge 0 ] || age=0
  grace="${FM_GUARD_GRACE:-$FMW_CAPTAIN_DEFAULT_GUARD_GRACE}"
  case "$grace" in ''|*[!0-9]*) grace=$FMW_CAPTAIN_DEFAULT_GUARD_GRACE ;; esac
  FMW_CAPTAIN_WATCHER_AGE="$age"
  if [ "$age" -le "$grace" ]; then FMW_CAPTAIN_WATCHER_STATE=fresh; else FMW_CAPTAIN_WATCHER_STATE=stale; fi
}

fmw_captain_shared_home_check() {
  FMW_CAPTAIN_HOME_CONSISTENCY=unknown
  if [ "$FMW_CAPTAIN_LOCK_STATE" = owned ] || [ "$FMW_CAPTAIN_LOCK_STATE" = other ]; then
    local captain_home watcher_home
    captain_home="$(fmw_captain_process_fm_home "$FMW_CAPTAIN_LOCK_PID")"
    watcher_home="$FMW_CAPTAIN_WATCHER_HOME"
    if [ -n "$captain_home" ] && [ "$captain_home" != "$FMW_CFG_FM_HOME" ]; then
      FMW_CAPTAIN_HOME_CONSISTENCY=mismatch
    elif [ "$FMW_CAPTAIN_WATCHER_STATE" = mismatch ]; then
      FMW_CAPTAIN_HOME_CONSISTENCY=mismatch
    elif [ -n "$watcher_home" ] && [ "$watcher_home" != "$FMW_CFG_FM_HOME" ]; then
      FMW_CAPTAIN_HOME_CONSISTENCY=mismatch
    else
      FMW_CAPTAIN_HOME_CONSISTENCY=consistent
    fi
  fi
}

fmw_captain_config_resolve() {
  fmw_config_resolve "$@" || return 1
  [ -n "$FMW_CFG_FIRSTMATE_ROOT" ] || return 1
  [ -n "$FMW_CFG_FM_HOME" ] || return 1
}

fmw_captain_status() {
  fmw_captain_config_resolve "$@" || {
    printf 'STATE: MISCONFIGURED\nREASON: invalid portable configuration\n'
    return 1
  }
  local herdr_ok=0
  fmw_captain_herdr_probe || herdr_ok=1
  fmw_captain_extensions
  fmw_captain_lock_inspect
  fmw_captain_watcher_inspect
  fmw_captain_shared_home_check
  printf 'STATE: evaluating\n'
  printf 'Herdr server: %s\n' "$FMW_CAPTAIN_HERDR_RUNNING"
  printf 'Herdr version: %s\n' "$FMW_CAPTAIN_HERDR_VERSION"
  printf 'Herdr protocol: %s\n' "$FMW_CAPTAIN_HERDR_PROTOCOL"
  printf 'Herdr socket: %s\n' "${HERDR_SOCKET_PATH:-<absent>}"
  printf 'Terminal: %s\n' "$([ "$herdr_ok" = 0 ] && printf 'Herdr-managed' || printf 'not Herdr-managed or inconsistent')"
  printf 'Herdr pane/tab/workspace: %s / %s / %s\n' "${HERDR_PANE_ID:-<absent>}" "${HERDR_TAB_ID:-<absent>}" "${HERDR_WORKSPACE_ID:-<absent>}"
  printf 'Herdr session: %s\n' "${FMW_CAPTAIN_HERDR_SESSION:-default}"
  printf 'FM_HOME: %s\n' "$FMW_CFG_FM_HOME"
  printf 'Captain lock: %s%s\n' "$FMW_CAPTAIN_LOCK_STATE" "${FMW_CAPTAIN_LOCK_PID:+ (pid $FMW_CAPTAIN_LOCK_PID)}"
  [ -z "$FMW_CAPTAIN_LOCK_COMMAND" ] || printf 'Captain process: %s\n' "$FMW_CAPTAIN_LOCK_COMMAND"
  printf 'FM_HOME consistency: %s\n' "$FMW_CAPTAIN_HOME_CONSISTENCY"
  printf 'Watcher: %s%s\n' "$FMW_CAPTAIN_WATCHER_STATE" "${FMW_CAPTAIN_WATCHER_PID:+ (pid $FMW_CAPTAIN_WATCHER_PID)}"
  printf 'Watcher beacon: %s\n' "${FMW_CAPTAIN_WATCHER_AGE:-unknown}"
  printf 'Pi watcher extension: %s\n' "$([ "$FMW_CAPTAIN_EXTENSIONS_OK" = 1 ] && printf 'available' || printf 'missing')"
  printf 'Pi turn-end extension: %s\n' "$([ -f "$FMW_CAPTAIN_GUARD_EXTENSION" ] && printf 'available' || printf 'missing')"
  if [ "$herdr_ok" -ne 0 ]; then
    printf 'STATE: MISCONFIGURED\nREASON: %s\n' "$FMW_CAPTAIN_HERDR_REASON"
    return 1
  fi
  if [ "$FMW_CAPTAIN_EXTENSIONS_OK" -ne 1 ]; then
    printf 'STATE: MISCONFIGURED\nREASON: official Pi extensions are missing under FIRSTMATE_ROOT\n'
    return 1
  fi
  case "$FMW_CAPTAIN_LOCK_STATE" in
    other) printf 'STATE: LOCKED_BY_OTHER\nREASON: live lock holder pid %s; do not delete the lock\n' "$FMW_CAPTAIN_LOCK_PID"; return 1 ;;
    stale|malformed) printf 'STATE: READ_ONLY\nREASON: lock is %s; inspect and resolve it without deleting it automatically\n' "$FMW_CAPTAIN_LOCK_STATE"; return 1 ;;
    missing) printf 'STATE: NOT_RUNNING\nREASON: no captain lock is present\n'; return 0 ;;
  esac
  if [ "$FMW_CAPTAIN_HOME_CONSISTENCY" = mismatch ]; then
    printf 'STATE: MISCONFIGURED\nREASON: supervisor/captain/watcher FM_HOME values disagree\n'
    return 1
  fi
  if [ "$FMW_CAPTAIN_WATCHER_STATE" != fresh ]; then
    printf 'STATE: WATCHER_STALE\nREASON: active captain has no fresh watcher beacon; use the official Pi repair path\n'
    return 1
  fi
  printf 'STATE: READY\nREASON: one captain lock and a fresh watcher share FM_HOME\n'
  return 0
}

fmw_captain_launch_command() {
  local root="$FMW_CFG_FIRSTMATE_ROOT" home="$FMW_CFG_FM_HOME" pi_bin="$1" inner
  inner="set -e
session_digest=\"\$(\"$root/bin/fm-session-start.sh\")\"
printf '%s\\n' \"\$session_digest\"
if printf '%s\\n' \"\$session_digest\" | grep -q 'READ-ONLY SESSION'; then
  printf '%s\\n' 'Captain was not started because Firstmate is read-only.' >&2
  exit 1
fi
exec $(fmw_captain_shell_quote "$pi_bin") -e $(fmw_captain_shell_quote "$FMW_CAPTAIN_GUARD_EXTENSION") -e $(fmw_captain_shell_quote "$FMW_CAPTAIN_WATCH_EXTENSION") \"Follow the Firstmate session-start digest. Call fm_watch_arm_pi once to start the first watcher cycle, then do not create tasks until supervision is healthy.\""
  printf 'cd -- %s\n' "$(fmw_captain_shell_quote "$root")"
  printf 'FM_HOME=%s FM_ROOT_OVERRIDE=%s bash -lc %s\n' "$(fmw_captain_shell_quote "$home")" "$(fmw_captain_shell_quote "$root")" "$(fmw_captain_shell_quote "$inner")"
}

fmw_captain() {
  local sub="${1:-}"
  if [ "$sub" = status ]; then
    shift
    fmw_captain_status "$@"
    return
  fi
  case "$sub" in
    ''|--*) ;;
    *) fmw_die "usage: fmw captain [status] [portable config options]" ;;
  esac
  fmw_captain_config_resolve "$@" || fmw_die "invalid portable configuration"
  fmw_captain_herdr_probe || fmw_die "$FMW_CAPTAIN_HERDR_REASON; open this command inside the intended Herdr pane"
  fmw_captain_extensions
  [ "$FMW_CAPTAIN_EXTENSIONS_OK" = 1 ] || fmw_die "official Pi extensions are missing under $FMW_CFG_FIRSTMATE_ROOT"
  fmw_captain_lock_inspect
  case "$FMW_CAPTAIN_LOCK_STATE" in
    owned) echo "Captain already active with lock pid $FMW_CAPTAIN_LOCK_PID; no restart requested."; return 0 ;;
    other) fmw_die "another live captain owns FM_HOME (pid $FMW_CAPTAIN_LOCK_PID); do not delete the lock or start a second captain" ;;
    stale|malformed) fmw_die "FM_HOME lock is $FMW_CAPTAIN_LOCK_STATE (pid ${FMW_CAPTAIN_LOCK_PID:-unknown}); inspect and resolve it without deleting it automatically" ;;
  esac
  local pi_bin
  pi_bin="$(command -v pi 2>/dev/null || true)"
  [ -n "$pi_bin" ] || fmw_die "Pi is missing from PATH; install or configure native Linux Pi before starting the captain"
  echo "No captain is running. Open the current Herdr pane and run this exact command; it does not start or stop Herdr:"
  fmw_captain_launch_command "$pi_bin"
  echo "The command inherits HERDR_* unchanged, uses one FM_HOME, runs official session-start, loads both official Pi extensions, and asks Pi to call fm_watch_arm_pi once."
  return 0
}
