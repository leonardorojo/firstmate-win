# lib/worktrees.sh — Windows worktree lifecycle
#
# Lifecycle owner: WSL git (create/remove/prune/validate).
# Ownership: state/tasks/<task-id>.conf (atomic write, allowlist).
# Teardown: fail-closed (see lib/safety.sh).

# fmw_task_prepare --project P --id T [--branch B]
#   Creates the worktree <root>/<T> with branch firstmate/<T> and records metadata.
fmw_task_prepare() {
  local project="" id="" branch="" wt base_ref
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) project="$2"; shift 2 ;;
      --id)      id="$2";      shift 2 ;;
      --branch)  branch="$2";  shift 2 ;;
      *) fmw_die "unknown argument: $1";;
    esac
  done
  { [ -n "$project" ] && [ -n "$id" ]; } || fmw_die "usage: fmw task prepare --project P --id T [--branch B]"

  fmw_task_id_valid "$id" || fmw_die "invalid task ID (^[a-z0-9][a-z0-9-]{0,62}$): $id"

  local pconf="$FMW_PROJECTS_DIR/$project.conf"
  [ -f "$pconf" ] || fmw_die "project not registered: $project"
  [ -f "$FMW_TASKS_DIR/$id.conf" ] && fmw_die "task '$id' already exists (state/tasks/$id.conf) — task ID collision"

  fmw_conf_load "$pconf" "${FMW_PROJECT_CONF_KEYS[@]}" || fmw_die "corrupt project config: $pconf"
  fmw_path_validate_repository "$PROJECT_WSL_PATH"    || fmw_die "invalid repository: $PROJECT_WSL_PATH"
  fmw_path_validate_worktree_root "$PROJECT_WORKTREE_WSL_ROOT" || fmw_die "invalid worktree root"

  [ -n "$branch" ] || branch="firstmate/$id"
  [[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,200}$ ]] || fmw_die "invalid branch: $branch"
  git -C "$PROJECT_WSL_PATH" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1 \
    && fmw_die "branch already exists: $branch (collision)"

  wt="$PROJECT_WORKTREE_WSL_ROOT/$id"
  fmw_path_validate_worktree_target "$wt" "$PROJECT_WORKTREE_WSL_ROOT" "$id" || fmw_die "invalid worktree target"

  fmw_lock_task "$id" || fmw_die "could not acquire the task lock"

  base_ref="$(git -C "$PROJECT_WSL_PATH" rev-parse HEAD)" \
    || { fmw_unlock_task; fmw_die "could not read HEAD of $PROJECT_WSL_PATH"; }

  git -C "$PROJECT_WSL_PATH" worktree add -b "$branch" "$wt" \
    || { fmw_unlock_task; fmw_die "git worktree add failed (corrupt worktree metadata?)"; }

  fmw_safety_worktree_registered "$PROJECT_WSL_PATH" "$wt" "$branch" || {
    git -C "$PROJECT_WSL_PATH" worktree remove "$wt" 2>/dev/null || true
    fmw_unlock_task
    fmw_die "post-creation verification failed; worktree removed"
  }

  fmw_conf_write_atomic "$FMW_TASKS_DIR/$id.conf" \
    "TASK_ID='$id'" \
    "PROJECT_NAME='$project'" \
    "REPOSITORY_WSL_PATH='$PROJECT_WSL_PATH'" \
    "REPOSITORY_WINDOWS_PATH='$PROJECT_WINDOWS_PATH'" \
    "WORKTREE_WSL_PATH='$wt'" \
    "WORKTREE_WINDOWS_PATH='$(fmw_path_to_windows "$wt")'" \
    "WORKTREE_ROOT='$PROJECT_WORKTREE_WSL_ROOT'" \
    "BRANCH='$branch'" \
    "BASE_REF='$base_ref'" \
    "CREATED_AT='$(fmw_now_utc)'" \
    "CREATED_BY_FMW='yes'" \
    "STATE='prepared'" \
    || {
      git -C "$PROJECT_WSL_PATH" worktree remove "$wt" 2>/dev/null || true
      fmw_unlock_task
      fmw_die "could not write metadata; worktree removed"
    }
  fmw_unlock_task

  echo "branch=$branch"
  echo "wsl_path=$wt"
  echo "windows_path=$(fmw_path_to_windows "$wt")"
  echo "base_ref=$base_ref"
  echo "state=prepared"
}

# fmw_task_load <id> — load the config of a registered task
fmw_task_load() {
  local id="$1"
  [ -f "$FMW_TASKS_DIR/$id.conf" ] || { fmw_log "task not registered: $id (state/tasks/$id.conf)"; return 1; }
  fmw_conf_load "$FMW_TASKS_DIR/$id.conf" "${FMW_TASK_CONF_KEYS[@]}" || { fmw_log "corrupt task config: $id"; return 1; }
}

# fmw_task_show <id> — metadata + git state of the worktree
fmw_task_show() {
  local id="$1"
  fmw_task_load "$id" || return 1
  echo "TASK_ID=$TASK_ID"
  echo "PROJECT_NAME=$PROJECT_NAME"
  echo "REPOSITORY_WSL_PATH=$REPOSITORY_WSL_PATH"
  echo "REPOSITORY_WINDOWS_PATH=$REPOSITORY_WINDOWS_PATH"
  echo "WORKTREE_WSL_PATH=$WORKTREE_WSL_PATH"
  echo "WORKTREE_WINDOWS_PATH=$WORKTREE_WINDOWS_PATH"
  echo "WORKTREE_ROOT=$WORKTREE_ROOT"
  echo "BRANCH=$BRANCH"
  echo "BASE_REF=$BASE_REF"
  echo "CREATED_AT=$CREATED_AT"
  echo "CREATED_BY_FMW=$CREATED_BY_FMW"
  echo "FIRSTMATE_TASK_ID=${FIRSTMATE_TASK_ID:-}"
  echo "FIRSTMATE_BACKEND=${FIRSTMATE_BACKEND:-}"
  echo "FIRSTMATE_ENDPOINT=${FIRSTMATE_ENDPOINT:-}"
  echo "STATE=$STATE"
  if [ -d "$WORKTREE_WSL_PATH" ]; then
    echo "git_head=$(git -C "$WORKTREE_WSL_PATH" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "git_branch=$(git -C "$WORKTREE_WSL_PATH" branch --show-current 2>/dev/null || echo unknown)"
  else
    echo "git_head=WORKTREE MISSING"
  fi
}

# fmw_task_list — active tasks (state/tasks/*.conf)
fmw_task_list() {
  local tconf found=0
  for tconf in "$FMW_TASKS_DIR"/*.conf; do
    [ -f "$tconf" ] || continue
    found=1
    if fmw_conf_load "$tconf" "${FMW_TASK_CONF_KEYS[@]}"; then
      printf '%-24s %-16s %-10s %s\n' "$TASK_ID" "$PROJECT_NAME" "$STATE" "$WORKTREE_WSL_PATH"
    else
      fmw_log "invalid config: $tconf"
    fi
  done
  [ "$found" = 1 ] || echo "(no prepared tasks)"
}

# fmw_task_status <id> — combined state: fmw meta + git + tmux window
#   (adds fm-crew-state.sh of Firstmate)
fmw_task_status() {
  local id="$1"
  local fm_meta="$FMW_FIRSTMATE_HOME/state/$id.meta"
  local cs state source detail busy elegible
  fmw_task_load "$id" || return 1
  # Reconcile the authoritative terminal state BEFORE showing.
  # If it fails (no evidence) the status continues and shows fail-closed.
  fmw_task_reconcile "$id" || true
  fmw_task_show "$id" || return 1
  echo "--- firstmate ---"
  if [ -f "$fm_meta" ]; then
    grep -E '^(window|endpoint_task_id|worktree|project|harness|model|kind|mode|backend|yolo)=' "$fm_meta" 2>/dev/null \
      | sed 's/^/fm_/' || true
    if [ -z "$(grep -E '^(window|endpoint_task_id|worktree|project|harness|model|kind|mode|backend|yolo)=' "$fm_meta" 2>/dev/null)" ]; then
      echo "fm_meta_presente=yes (unparsed format)"
    fi
  else
    echo "fm_meta=missing (task not spawned)"
  fi
  if fmw_safety_agent_window_exists "$id"; then
    echo "fm_window=active (fm-$id in tmux)"
  else
    echo "fm_window=no tmux window"
  fi
  echo "--- operative state (authoritative source: fm-crew-state.sh) ---"
  if cs="$(fmw_crew_state "$id" 2>/dev/null)"; then
    IFS='|' read -r state source detail <<< "$cs"
    echo "fm_state=$state"
    echo "fm_state_source=$source"
    echo "fm_state_detail=$detail"
  else
    echo "fm_state=unknown (source unavailable)"
    echo "fm_state_source=none"
    echo "fm_state_detail="
  fi
  busy="$(fmw_busy_state_value "$id" 2>/dev/null || true)"
  echo "fm_agent_busy=$busy"
  if [ -f "$FMW_FIRSTMATE_HOME/state/$id.turn-ended" ]; then
    echo "fm_turn_ended=yes"
  else
    echo "fm_turn_ended=no"
  fi
  if [ -f "$FMW_FIRSTMATE_HOME/data/$id/report.md" ]; then
    echo "fm_report=yes"
  else
    echo "fm_report=no"
  fi
  elegible="$(fmw_task_teardown_elegible "$id" 2>/dev/null || echo "no (eligibility check failed)")"
  echo "fm_teardown_elegible=$elegible"
}

# fmw_task_teardown <id> [--force]
#   Fail-closed chain: ownership + expected path + git + root + branch.
#   Does NOT discard changes unless --force is explicit. Keeps the branch.
fmw_task_teardown() {
  local id="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      -*) fmw_die "unknown argument: $1";;
      *) [ -z "$id" ] && id="$1" || fmw_die "too many arguments: $1"; shift ;;
    esac
  done
  [ -n "$id" ] || fmw_die "usage: fmw task teardown <id> [--force]"

  fmw_task_load "$id" || return 1
  [ "$STATE" != "torn-down" ] || { fmw_log "task already torn down: $id"; return 1; }

  # 1. there must be no active agent (tmux window fm-<id>)
  if fmw_safety_agent_window_exists "$id"; then
    fmw_die "active Firstmate agent for '$id' (window fm-$id in tmux). Close the session before teardown."
  fi

  # 2. expected path: exists, canonical, under the allowed root, matches conf
  local wt wt_canon root_canon
  wt_canon="$(fmw_path_canonical "$WORKTREE_WSL_PATH")"
  root_canon="$(fmw_path_canonical "$WORKTREE_ROOT")"
  [ -e "$wt_canon" ] || { fmw_log "worktree does not exist: $wt_canon (already removed?)"; return 1; }
  fmw_path_is_under "$wt_canon" "$root_canon" \
    || fmw_die "worktree outside the registered root: $wt_canon !< $root_canon"
  [ "$(basename "$wt_canon")" = "$id" ] || fmw_die "worktree basename does not match the task id"

  # 3. git: the worktree must be registered with exactly that branch
  fmw_safety_worktree_registered "$REPOSITORY_WSL_PATH" "$wt_canon" "$BRANCH" \
    || fmw_die "worktree/branch do not match `git worktree list --porcelain` — stop and review"

  # 4. local changes: do not discard unless --force is explicit
  if [ "$force" = 0 ]; then
    if [ -n "$(git -C "$wt_canon" status --porcelain 2>/dev/null)" ]; then
      fmw_die "the worktree has local changes. Review them (commit/stash/PR) and retry, or use --force to discard them explicitly."
    fi
  fi

  fmw_lock_task "$id" || fmw_die "could not acquire the task lock"

  local rc=0
  if [ "$force" = 1 ]; then
    git -C "$REPOSITORY_WSL_PATH" worktree remove --force "$wt_canon" || rc=1
  else
    git -C "$REPOSITORY_WSL_PATH" worktree remove "$wt_canon" || rc=1
  fi
  if [ "$rc" = 0 ]; then
    git -C "$REPOSITORY_WSL_PATH" worktree prune || true
    # archive metadata (do not delete): ownership preserved with STATE=torn-down
    local archived="$FMW_ARCHIVE_DIR/$id.conf"
    fmw_conf_write_atomic "$archived" \
      "TASK_ID='$id'" \
      "PROJECT_NAME='$PROJECT_NAME'" \
      "REPOSITORY_WSL_PATH='$REPOSITORY_WSL_PATH'" \
      "REPOSITORY_WINDOWS_PATH='$REPOSITORY_WINDOWS_PATH'" \
      "WORKTREE_WSL_PATH='$WORKTREE_WSL_PATH'" \
      "WORKTREE_WINDOWS_PATH='$WORKTREE_WINDOWS_PATH'" \
      "WORKTREE_ROOT='$WORKTREE_ROOT'" \
      "BRANCH='$BRANCH'" \
      "BASE_REF='$BASE_REF'" \
      "CREATED_AT='$CREATED_AT'" \
      "CREATED_BY_FMW='yes'" \
      "STATE='torn-down'" \
      "ARCHIVED_AT='$(fmw_now_utc)'" \
      || fmw_log "warning: could not archive metadata (state/archive/$id.conf)"
    rm -f "$FMW_TASKS_DIR/$id.conf"
    echo "teardown OK: worktree removed ($wt_canon)"
    echo "branch kept: $BRANCH (branches are never deleted without authorization)"
  else
    fmw_log "git worktree remove failed; check for remaining locks/resources"
  fi
  fmw_unlock_task
  return "$rc"
}
