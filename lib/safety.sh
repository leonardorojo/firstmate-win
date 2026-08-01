# lib/safety.sh — fail-closed guards and locking
#
# Fail-closed teardown: never remove a worktree just because its path was
# supplied by the user. To remove it, all of the following must match:
#   registered project, task ID, expected path, ownership record,
#   wrapper metadata, `git worktree list --porcelain` output,
#   allowed root, expected branch.

# fmw_lock_task <task-id> — exclusive per-task lock (flock, mkdir fallback)
#   Usage: fmw_lock_task "$id" ... fmw_unlock_task
fmw_lock_task() {
  local id="$1"
  mkdir -p "$FMW_LOCKS_DIR" || return 1
  if command -v flock >/dev/null 2>&1; then
    exec {FMW_LOCK_FD}>"$FMW_LOCKS_DIR/$id.lock" || return 1
    flock -n "$FMW_LOCK_FD" || { fmw_log "task '$id' locked by another operation (flock)"; return 1; }
  else
    local lockdir="$FMW_LOCKS_DIR/$id.lockdir" i=0
    while ! mkdir "$lockdir" 2>/dev/null; do
      i=$((i+1))
      [ "$i" -ge 50 ] && { fmw_log "task '$id' locked by another operation (mkdir)"; return 1; }
      sleep 0.1
    done
    FMW_LOCK_DIR_FALLBACK="$lockdir"
  fi
  return 0
}

# fmw_unlock_task — release the lock taken by fmw_lock_task
fmw_unlock_task() {
  if command -v flock >/dev/null 2>&1; then
    flock -u "$FMW_LOCK_FD" 2>/dev/null || true
    exec {FMW_LOCK_FD}>&- 2>/dev/null || true
  else
    [ -n "${FMW_LOCK_DIR_FALLBACK:-}" ] && rmdir "$FMW_LOCK_DIR_FALLBACK" 2>/dev/null || true
    FMW_LOCK_DIR_FALLBACK=""
  fi
  return 0
}

# fmw_safety_agent_window_exists <task-id>
#   true if a tmux window fm-<id> exists in ANY session (active agent).
fmw_safety_agent_window_exists() {
  local id="$1"
  command -v tmux >/dev/null 2>&1 || return 1
  tmux list-windows -a -F '#{window_name}' 2>/dev/null | grep -qx "fm-$id"
}

# fmw_safety_worktree_registered <repo> <wt-path> <branch>
#   Checks in the repo's `git worktree list --porcelain` that the worktree
#   exists with exactly that path and that branch. Git is the source of truth.
fmw_safety_worktree_registered() {
  local repo="$1" wt="$2" branch="$3"
  local cwt cbr ok=1
  cwt="$(fmw_path_canonical "$wt")"
  cbr="refs/heads/$branch"
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) [ "$(fmw_path_canonical "${line#worktree }")" = "$cwt" ] && { cwt=""; } ;;
      branch\ *)   [ "${line#branch }" = "$cbr" ] && { cbr=""; } ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
  [ -z "$cwt" ] || { fmw_log "worktree NOT registered in git: $wt"; ok=0; }
  [ -z "$cbr" ] || { fmw_log "branch does NOT match in git: $branch"; ok=0; }
  [ "$ok" = 1 ]
}
