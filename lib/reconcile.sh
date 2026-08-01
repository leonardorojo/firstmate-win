# lib/reconcile.sh — terminal-state reconciliation and teardown eligibility
#
# State model (Design C — hybrid, decided in docs/architecture.md):
#
#   PERSISTED  (STATE in state/tasks/<id>.conf) = worktree lifecycle:
#       prepared -> spawned -> {done|blocked|failed} -> torn-down
#     Only RELIABLE terminal states (done, blocked, failed) are persisted,
#     and only when fm-crew-state.sh (the authoritative source) confirms them.
#
#   OPERATIVE  (dynamic, recomputed on every `fmw task status`) = the agent's
#     current situation according to Firstmate:
#       working | parked | done | blocked | paused | failed | unknown
#     Transient states (working, parked, paused, idle, unknown) are NEVER
#     persisted: they would churn the conf on every call and mix the
#     operative situation with lifecycle/ownership metadata.
#
#   SINGLE authoritative source: Firstmate's fm-crew-state.sh. The status-log
#   alone is NOT current state (it is an append-only event log):
#   fm-crew-state reconciles it against run-step and pane busy, and returns
#   unknown if the pane is dead or unreadable even when the last log line is
#   `done:`. That is why we delegate instead of reimplementing local rules
#   (zero drift risk and zero false positives).
#
#   Fail-closed rules:
#     - Source missing, failure, unparseable output or unknown state =>
#       STATE stays unchanged and the task is NOT teardown-eligible.
#     - .turn-ended and report.md NEVER mark done by themselves: they are
#       complementary evidence that the status shows, not a state source.
#     - `blocked` is a terminal verb but RECOVERABLE (the captain can unblock
#       with steering): reconciliation re-evaluates on every status and will
#       overwrite blocked -> done when the crew finishes.
#     - Idempotent: re-running over an already reconciled conf changes nothing.
#     - Reconciliation does NOT touch windows, processes, worktrees or the
#       Firstmate upstream: it only reads fm-crew-state.sh and writes the conf.

# fmw_crew_state <id> — authoritative operative state from Firstmate.
#   Invokes the official reader fm-crew-state.sh (fail-closed on any failure).
#   Prints "state|source|detail"; rc=0. rc=1 without output if it cannot
#   be determined.
fmw_crew_state() {
  local id="$1" bin out line state source detail
  bin="$(fmw_firstmate_bin fm-crew-state.sh)" || {
    fmw_log "fm-crew-state.sh is not in $FMW_FIRSTMATE_HOME/bin"
    return 1
  }
  out="$(timeout 15 bash "$bin" "$id" 2>/dev/null)" || {
    fmw_log "fm-crew-state.sh failed for '$id' (rc=$?)"
    return 1
  }
  line="$(printf '%s\n' "$out" | head -n 1)"
  case "$line" in
    state:\ *) ;;
    *)
      fmw_log "unexpected fm-crew-state.sh output for '$id': '${line}'"
      return 1
      ;;
  esac
  line="${line#state: }"
  state="${line%% *}"
  case "$state" in
    working|parked|done|blocked|paused|failed|unknown) ;;
    *)
      fmw_log "unrecognized state from fm-crew-state.sh: '$state'"
      return 1
      ;;
  esac
  line="${line#*source: }"
  source="${line%% *}"
  [ -n "$source" ] || source="none"
  detail="${line#* }"
  detail="${detail#· }"
  printf '%s|%s|%s\n' "$state" "$source" "$detail"
}

# fmw_busy_state_value <id> — state of the Firstmate busy-state file.
#   Prints busy|idle|missing|malformed (rc 0/1).
fmw_busy_state_value() {
  local f="$FMW_FIRSTMATE_HOME/state/$1.busy-state" val
  [ -f "$f" ] || { echo "missing"; return 1; }
  val="$(sed -n 's/.*state=\([A-Za-z]*\).*/\1/p' "$f" | head -n 1)"
  [ -n "$val" ] || { echo "malformed"; return 1; }
  echo "$val"
}

# fmw_task_reconcile <id> — persist the authoritative terminal state.
#   Idempotent: if STATE already matches or there is no evidence, nothing is
#   written. Only acts on prepared|spawned lifecycles (never torn-down or
#   already-persisted terminal states). Refreshes the conf globals at the end
#   when it persisted. rc=0 even when nothing changed; rc=1 when there is no
#   authoritative evidence (fail-closed, STATE untouched).
fmw_task_reconcile() {
  local id="$1" cs state source detail
  fmw_task_load "$id" || return 1
  case "$STATE" in
    prepared|spawned) ;;
    done|blocked|failed|abandoned)
      fmw_log "reconciliation: $id already terminal (STATE=$STATE); no change"
      return 0
      ;;
    torn-down)
      fmw_log "reconciliation: $id already torn down; no change"
      return 0
      ;;
    *)
      fmw_log "reconciliation: $id has unmanaged STATE ('$STATE'); no change"
      return 0
      ;;
  esac
  cs="$(fmw_crew_state "$id")" || {
    fmw_log "reconciliation: $id without authoritative evidence (fail-closed; STATE stays '$STATE')"
    return 1
  }
  IFS='|' read -r state source detail <<< "$cs"
  case "$state" in
    done|blocked|failed)
      if [ "$STATE" != "$state" ]; then
        fmw_task_conf_set "$id" "STATE='$state'" || return 1
        fmw_log "reconciliation: $id STATE '$STATE' -> '$state' (source: $source)"
        fmw_task_load "$id" || true   # refresh STATE for the caller
      else
        fmw_log "reconciliation: $id already persisted as '$state' (source: $source); no change"
      fi
      ;;
    *)
      fmw_log "reconciliation: $id operative state '$state' (not terminal); STATE stays '$STATE'"
      ;;
  esac
  return 0
}

# fmw_task_teardown_elegible <id> — may teardown proceed without risk?
#   Prints "yes (reason)" (rc=0) or "no: reason" (rc=1). Fail-closed:
#   - only STATE=done|abandoned are eligible (blocked/failed require review,
#     not teardown; abandoned = explicit operator authorization);
#   - worktree present and clean;
#   - no fm-<id> window, or a window whose busy-state is idle
#     (in that case teardown requires a prior controlled close; a busy
#     agent or a missing/unreadable busy-state blocks eligibility).
fmw_task_teardown_elegible() {
  local id="$1" busy
  fmw_task_load "$id" || { echo "no: task not loadable"; return 1; }
  [ "$STATE" = "done" ] || [ "$STATE" = "abandoned" ] || {
    echo "no: STATE=$STATE (eligible only with STATE=done or STATE=abandoned)"
    return 1
  }
  [ -d "$WORKTREE_WSL_PATH" ] || {
    echo "no: worktree missing ($WORKTREE_WSL_PATH)"
    return 1
  }
  if [ -n "$(git -C "$WORKTREE_WSL_PATH" status --porcelain 2>/dev/null)" ]; then
    echo "no: worktree has local changes"
    return 1
  fi
  if fmw_safety_agent_window_exists "$id"; then
    busy="$(fmw_busy_state_value "$id" || true)"
    case "$busy" in
      idle)
        echo "yes (clean worktree; requires controlled close of the fm-$id window)"
        return 0
        ;;
      busy)
        echo "no: agent busy (busy-state=busy)"
        return 1
        ;;
      *)
        echo "no: active window without verifiable idle state (busy-state=$busy)"
        return 1
        ;;
    esac
  fi
  echo "yes (clean worktree; no active agent)"
}
