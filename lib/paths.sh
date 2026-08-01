# lib/paths.sh — Windows <-> WSL path contract
#
# PGM contract functions:
#   fmw_path_to_wsl / fmw_path_to_windows / fmw_path_is_windows_mounted
#   fmw_path_is_under / fmw_path_canonical
#   fmw_path_validate_repository / fmw_path_validate_worktree_root
#
# Rules:
#   - use wslpath -u/-w; never concatenate Windows paths by hand
#   - canonicalize with realpath -m (works for not-yet-created paths)
#   - normalize the drive letter to lowercase (/mnt/C -> /mnt/c)
#   - reject worktrees under the native WSL filesystem (/home /tmp /var /root)

# fmw_path_canonical <path> — canonicalize and normalize drive to lowercase
fmw_path_canonical() {
  realpath -m "$1" 2>/dev/null | sed -E 's|^/mnt/([A-Z])|/mnt/\L\1|'
}

# fmw_path_to_wsl <windows-path> — C:\foo or C:/foo -> /mnt/c/foo
fmw_path_to_wsl() { wslpath -u "$1"; }

# fmw_path_to_windows <wsl-path> — /mnt/c/foo -> C:\foo
fmw_path_to_windows() { wslpath -w "$1"; }

# fmw_path_is_windows_mounted <path> — true if it resolves under /mnt/<drive>/
fmw_path_is_windows_mounted() {
  [[ "$(fmw_path_canonical "$1")" == /mnt/[a-z]/* ]]
}

# fmw_path_is_under <path> <root> — true if path == root or path is under root
fmw_path_is_under() {
  local p r
  p="$(fmw_path_canonical "$1")" || return 1
  r="$(fmw_path_canonical "$2")" || return 1
  [[ "$p" == "$r" || "$p" == "$r"/* ]]
}

# fmw_path_reject_native_wsl <path> — reject paths on the native WSL filesystem
fmw_path_reject_native_wsl() {
  case "$(fmw_path_canonical "$1")" in
    /home/*|/tmp/*|/var/*|/root/*)
      fmw_log "forbidden path (native WSL filesystem, not /mnt): $1"
      return 1;;
  esac
  return 0
}

# fmw_task_id_valid <id> — PGM task ID convention
#   ^[a-z0-9][a-z0-9-]{0,62}$  (no spaces, /, \, .., shell characters)
fmw_task_id_valid() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]
}

# fmw_path_validate_repository <repo-wsl-path>
#   Validates: exists; is a readable Git repo; physically on Windows (/mnt).
fmw_path_validate_repository() {
  local repo="$1"
  [ -d "$repo" ] || { fmw_log "repository not found: $repo"; return 1; }
  fmw_path_is_windows_mounted "$repo" \
    || { fmw_log "repository must live under /mnt/<drive>/ (got: $repo)"; return 1; }
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { fmw_log "not a git work tree: $repo"; return 1; }
  git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1 \
    || { fmw_log "git cannot read the repository: $repo"; return 1; }
  return 0
}

# fmw_path_validate_worktree_root <root-wsl-path>
#   Validates: exists; on Windows (/mnt); not on the native WSL filesystem.
fmw_path_validate_worktree_root() {
  local root="$1"
  [ -d "$root" ] || { fmw_log "worktree root does not exist: $root"; return 1; }
  fmw_path_is_windows_mounted "$root" \
    || { fmw_log "worktree root must live under /mnt/<drive>/ (got: $root)"; return 1; }
  fmw_path_reject_native_wsl "$root" || return 1
  return 0
}

# fmw_path_validate_worktree_target <wt-path> <root-wsl-path> <task-id>
#   Fail-closed validation of a worktree path BEFORE creating it:
#     - the path must NOT exist (collision)
#     - it must be strictly under the allowed root
#     - the final component must match the task id exactly
#     - it must not be the main checkout of any registered repo
fmw_path_validate_worktree_target() {
  local wt="$1" root="$2" id="$3"
  fmw_path_reject_native_wsl "$root" \
    || { fmw_log "forbidden root (native WSL filesystem): $root"; return 1; }
  [ -e "$wt" ] && { fmw_log "worktree path already exists: $wt"; return 1; }
  fmw_path_is_under "$wt" "$root" \
    || { fmw_log "worktree outside the allowed root: $wt !< $root"; return 1; }
  [ "$(basename "$(fmw_path_canonical "$wt")")" = "$id" ] \
    || { fmw_log "worktree must end with the task id ($id): $wt"; return 1; }
  # the path must not match the toplevel of any registered repo
  local pconf repo
  for pconf in "$FMW_PROJECTS_DIR"/*.conf; do
    [ -f "$pconf" ] || continue
    fmw_conf_load "$pconf" "${FMW_PROJECT_CONF_KEYS[@]}" || continue
    repo="$(fmw_path_canonical "$PROJECT_WSL_PATH")"
    [ "$(fmw_path_canonical "$wt")" = "$repo" ] \
      && { fmw_log "worktree cannot be the main checkout of $PROJECT_NAME"; return 1; }
  done
  return 0
}
