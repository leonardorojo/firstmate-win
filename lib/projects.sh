# lib/projects.sh — Windows project registry (config/projects/<name>.conf)
#
# A project = a Git repository whose main checkout lives on Windows
# (/mnt/<drive>/), visible from WSL, with a dedicated Windows worktree root.
#
# The registry stores the 4 paths (windows/wsl x repo/worktree-root) so the
# rest of the wrapper never needs to convert paths by hand.

# fmw_project_add --name N --windows-path P --worktree-root R [--profile P]
fmw_project_add() {
  local name="" wp="" wr="" profile="" wsl_repo wsl_root wroot
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)          name="$2";    shift 2 ;;
      --windows-path)  wp="$2";      shift 2 ;;
      --worktree-root) wr="$2";      shift 2 ;;
      --profile)       profile="$2"; shift 2 ;;
      *) fmw_die "unknown argument: $1";;
    esac
  done
  { [ -n "$name" ] && [ -n "$wp" ] && [ -n "$wr" ]; } \
    || fmw_die "usage: fmw project add --name N --windows-path P --worktree-root R [--profile P]"

  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] \
    || fmw_die "invalid project name (no spaces or slashes): $name"
  [ -f "$FMW_PROJECTS_DIR/$name.conf" ] && fmw_die "project already registered: $name"

  # Windows -> WSL path conversion (wslpath is the only source of truth)
  wsl_repo="$(fmw_path_canonical "$(fmw_path_to_wsl "$wp")")" \
    || fmw_die "could not convert repo Windows path: $wp"
  wsl_root="$(fmw_path_canonical "$(fmw_path_to_wsl "$wr")")" \
    || fmw_die "could not convert worktree root Windows path: $wr"

  fmw_path_validate_repository "$wsl_repo"    || fmw_die "invalid repository: $wsl_repo"
  fmw_path_validate_worktree_root "$wsl_root" || fmw_die "invalid worktree root: $wsl_root"
  fmw_path_is_under "$wsl_root" "/mnt/c" || fmw_log "warning: worktree root outside /mnt/c (supported but not the default)"

  [ "$(basename "$wsl_root")" = "$name" ] \
    || fmw_log "warning: worktree root does not end with the project name (expected: .../$name)"

  [ -n "$profile" ] || profile="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  [ -f "$FMW_PROFILES_DIR/$profile.sh" ] \
    || fmw_die "profile not found: profiles/$profile.sh (create it before registering the project)"

  wroot="$(fmw_path_to_windows "$wsl_root")"
  local win_repo win_root
  win_repo="$(fmw_path_to_windows "$wsl_repo")"
  win_root="$(fmw_path_to_windows "$wsl_root")"
  fmw_conf_write_atomic "$FMW_PROJECTS_DIR/$name.conf" \
    "PROJECT_NAME='$name'" \
    "PROJECT_WINDOWS_PATH='$win_repo'" \
    "PROJECT_WSL_PATH='$wsl_repo'" \
    "PROJECT_WORKTREE_WINDOWS_ROOT='$win_root'" \
    "PROJECT_WORKTREE_WSL_ROOT='$wsl_root'" \
    "PROJECT_PROFILE='$profile'" \
    "REGISTERED_AT='$(fmw_now_utc)'" \
    || fmw_die "could not write $FMW_PROJECTS_DIR/$name.conf"

  echo "registered: $name (profile=$profile)"
  echo "  windows_path=$win_repo"
  echo "  wsl_path=$wsl_repo"
  echo "  windows_worktree_root=$win_root"
  echo "  wsl_worktree_root=$wsl_root"
}

# fmw_project_list — list registered projects
fmw_project_list() {
  local pconf name
  local found=0
  for pconf in "$FMW_PROJECTS_DIR"/*.conf; do
    [ -f "$pconf" ] || continue
    found=1
    if fmw_conf_load "$pconf" "${FMW_PROJECT_CONF_KEYS[@]}"; then
      printf '%-24s %-40s %s\n' "$PROJECT_NAME" "$PROJECT_WSL_PATH" "profile=$PROJECT_PROFILE"
    else
      fmw_log "invalid config: $pconf"
    fi
  done
  [ "$found" = 1 ] || echo "(no registered projects)"
}

# fmw_project_show <name> — show the full config of a project
fmw_project_show() {
  local name="$1" conf="$FMW_PROJECTS_DIR/$1.conf"
  [ -f "$conf" ] || fmw_die "project not registered: $name"
  fmw_conf_load "$conf" "${FMW_PROJECT_CONF_KEYS[@]}" || fmw_die "corrupt config: $conf"
  echo "PROJECT_NAME=$PROJECT_NAME"
  echo "PROJECT_WINDOWS_PATH=$PROJECT_WINDOWS_PATH"
  echo "PROJECT_WSL_PATH=$PROJECT_WSL_PATH"
  echo "PROJECT_WORKTREE_WINDOWS_ROOT=$PROJECT_WORKTREE_WINDOWS_ROOT"
  echo "PROJECT_WORKTREE_WSL_ROOT=$PROJECT_WORKTREE_WSL_ROOT"
  echo "PROJECT_PROFILE=$PROJECT_PROFILE"
  echo "REGISTERED_AT=$REGISTERED_AT"
}

# fmw_project_validate <name> — minimal PGM validations
#   exists / is a Git repo / accessible from WSL / physically on Windows /
#   worktree root on Windows / git can read it / worktree metadata not corrupt /
#   PowerShell interop works
fmw_project_validate() {
  local name="$1" conf="$FMW_PROJECTS_DIR/$1.conf" ok=1
  [ -f "$conf" ] || fmw_die "project not registered: $name"
  fmw_conf_load "$conf" "${FMW_PROJECT_CONF_KEYS[@]}" || fmw_die "corrupt config: $conf"

  local label
  check() { # check <label> <cmd...>
    label="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  [PASS] $label"; else echo "  [FAIL] $label"; ok=0; fi
  }

  echo "validating project: $name"
  check "directory exists"          test -d "$PROJECT_WSL_PATH"
  check "is a git work tree"        git -C "$PROJECT_WSL_PATH" rev-parse --is-inside-work-tree
  check "git can read it"           git -C "$PROJECT_WSL_PATH" rev-parse --show-toplevel
  check "path physically on Windows" fmw_path_is_windows_mounted "$PROJECT_WSL_PATH"
  check "worktree root on Windows"  fmw_path_is_windows_mounted "$PROJECT_WORKTREE_WSL_ROOT"
  check "worktree root exists"      test -d "$PROJECT_WORKTREE_WSL_ROOT"
  check "worktree metadata OK"      git -C "$PROJECT_WSL_PATH" worktree list --porcelain
  if [ "${FMW_SKIP_INTEROP_CHECK:-0}" = "1" ]; then
    echo "  [SKIP] PowerShell interop (FMW_SKIP_INTEROP_CHECK=1 — user-approved verification pending)"
  else
    check "PowerShell interop"      powershell.exe -NoProfile -Command '$true'
  fi
  check "profile present"           test -f "$FMW_PROFILES_DIR/$PROJECT_PROFILE.sh"
  if [ -f "$FMW_PROFILES_DIR/$PROJECT_PROFILE.sh" ]; then
    # same context contract as fmw_profile_load (build/test/open)
    export FMW_PROJECT_NAME="$PROJECT_NAME"
    export FMW_PROJECT_WSL_PATH="$PROJECT_WSL_PATH"
    export FMW_PROJECT_WINDOWS_PATH="$PROJECT_WINDOWS_PATH"
    unset FMW_TASK_ID FMW_TASK_WORKTREE_WSL FMW_TASK_WORKTREE_WINDOWS 2>/dev/null || true
    . "$FMW_PROFILES_DIR/$PROJECT_PROFILE.sh"
    check "profile validatable"     fmw_profile_validate
  else
    echo "  [FAIL] profile validatable (profile missing)"
    ok=0
  fi

  [ "$ok" = 1 ] && echo "  -> project OK" || echo "  -> project has failures"
  return $((ok ? 0 : 1))
}

# fmw_project_resolve <name-or-path>
#   Accepts a registered name or a WSL path inside a registered project
#   (for commands like fmw build/test run from a worktree).
fmw_project_resolve() {
  local arg="${1:-}" pconf candidate
  if [ -n "$arg" ] && [ -f "$FMW_PROJECTS_DIR/$arg.conf" ]; then
    fmw_conf_load "$FMW_PROJECTS_DIR/$arg.conf" "${FMW_PROJECT_CONF_KEYS[@]}" || return 1
    echo "$PROJECT_NAME"; return 0
  fi
  # path lookup: the argument or the cwd must be under a registered project
  candidate="$(fmw_path_canonical "${arg:-$PWD}")"
  for pconf in "$FMW_PROJECTS_DIR"/*.conf; do
    [ -f "$pconf" ] || continue
    fmw_conf_load "$pconf" "${FMW_PROJECT_CONF_KEYS[@]}" || continue
    if fmw_path_is_under "$candidate" "$PROJECT_WSL_PATH" \
       || fmw_path_is_under "$candidate" "$PROJECT_WORKTREE_WSL_ROOT"; then
      echo "$PROJECT_NAME"; return 0
    fi
  done
  fmw_die "could not resolve project (registered or under path): ${arg:-$PWD}"
}
