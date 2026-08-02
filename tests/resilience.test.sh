# tests/resilience.test.sh — partial-state resilience matrix
#   Every scenario forces an inconsistent/partial state and asserts the
#   wrapper detects it, explains the evidence, fails closed, never deletes
#   resources and never invents state (no done: without an authoritative
#   source, no teardown without ownership).
#
#   Covered partial states:
#     1. metadata without worktree     6. missing Firstmate meta
#     2. worktree without metadata     7. contradictory status (source fails)
#     3. missing agent window          8. terminal task with live window
#     4. dead agent process            9. active task with stale status
#     5. abandoned lock
. "$(dirname "$0")/harness.sh"
. "$FMW_LIB_DIR/firstmate.sh"   # fmw_task_conf_set (not loaded by the harness)

fmw_test_setup_sandbox
fmw_test_assert_sandboxed
fmw_test_make_repo "$FMW_TESTLAB/repo"
fmw_test_make_profile "resil"
mkdir -p "$FMW_TESTLAB/wt"
fmw project add --name Resil \
  --windows-path "C:\\FirstmateWorktrees\\TestLab\\repo" \
  --worktree-root "C:\\FirstmateWorktrees\\TestLab\\wt" \
  --profile resil >/dev/null 2>&1 \
  || { echo "   FATAL: could not register Resil"; exit 1; }

# --- fake firstmate: crew-state answers from fake-answers/<id> ---
mkdir -p "$FMW_FIRSTMATE_HOME/bin" "$FMW_FIRSTMATE_HOME/state" "$FMW_FIRSTMATE_HOME/data"
cat > "$FMW_FIRSTMATE_HOME/bin/fm-crew-state.sh" <<'FAKE'
#!/usr/bin/env bash
id="${1:-}"
ans="${FMW_FIRSTMATE_HOME}/fake-answers/${id}"
[ -f "$ans" ] || { echo "state: unknown · source: none · no metadata for ${id}"; exit 0; }
if grep -qx 'FAIL' "$ans"; then echo "state: unknown · source: none · fake failure" >&2; exit 3; fi
cat "$ans"
FAKE
chmod +x "$FMW_FIRSTMATE_HOME/bin/fm-crew-state.sh"
mkdir -p "$FMW_FIRSTMATE_HOME/fake-answers"

fake_answer() { printf '%s\n' "$2" > "$FMW_FIRSTMATE_HOME/fake-answers/$1"; }
new_task() {
  fmw task prepare --project Resil --id "$1" >/dev/null 2>&1 || return 1
  fmw_task_conf_set "$1" "STATE='spawned'" || return 1
}
status_out() { fmw task status "$1" 2>&1; }

# --- 1. metadata without worktree ---
t_begin "1: metadata without worktree -> detected, STATE intact, teardown refuses"
new_task res-nodir || { t_fail "prepare res-nodir"; }
git -C "$FMW_TESTLAB/repo" worktree remove "$FMW_TESTLAB/wt/res-nodir" 2>/dev/null || true
rm -rf "$FMW_TESTLAB/wt/res-nodir"
out="$(status_out res-nodir)"
echo "$out" | grep -q '^STATE=spawned$' && t_ok "STATE intact (no invented done)" || t_fail "STATE: $(echo "$out" | grep '^STATE=')"
if fmw task teardown res-nodir >/dev/null 2>&1; then
  t_fail "teardown should refuse without a worktree"
else
  t_ok "teardown refuses (worktree missing)"
fi
[ -f "$FMW_TASKS_DIR/res-nodir.conf" ] && t_ok "metadata preserved" || t_fail "metadata deleted"

# --- 2. worktree without metadata ---
t_begin "2: worktree without metadata -> not registered, never touched"
git -C "$FMW_TESTLAB/repo" worktree add -b firstmate/orphan-wt "$FMW_TESTLAB/wt/orphan-wt" >/dev/null 2>&1
if fmw task status orphan-wt >/dev/null 2>&1; then
  t_fail "status should fail for an unregistered task"
else
  t_ok "status fails clean (task not registered)"
fi
t_assert_false fmw task teardown orphan-wt
t_assert_true test -d "$FMW_TESTLAB/wt/orphan-wt"  # orphan worktree untouched

# --- 3. missing agent window (spawned, no window) ---
t_begin "3: missing agent window -> reported, fail-closed"
new_task res-nowin || { t_fail "prepare res-nowin"; }
fake_answer res-nowin "state: unknown · source: none · no metadata"
out="$(status_out res-nowin)"
echo "$out" | grep -q '^fm_window=no tmux window$' && t_ok "window absence reported" || t_fail "fm_window: $(echo "$out" | grep '^fm_window=')"
echo "$out" | grep -q '^STATE=spawned$' && t_ok "STATE intact without window" || t_fail "STATE changed"

# --- 4. dead agent process (source unknown => pane dead/unreadable) ---
t_begin "4: dead agent process -> source unknown, STATE intact"
new_task res-dead || { t_fail "prepare res-dead"; }
fake_answer res-dead "state: unknown · source: none · pane dead or unreadable"
out="$(status_out res-dead)"
echo "$out" | grep -q '^fm_state=unknown$' && t_ok "operative state unknown" || t_fail "fm_state: $(echo "$out" | grep '^fm_state=')"
echo "$out" | grep -q '^STATE=spawned$' && t_ok "STATE intact (no invented done)" || t_fail "STATE invented"
[ -d "$FMW_TESTLAB/wt/res-dead" ] && t_ok "worktree preserved" || t_fail "worktree deleted"

# --- 5. abandoned lock (flock is fd-based; an orphan file must not block) ---
t_begin "5: abandoned lock file -> flock still acquirable (fd-based)"
: > "$FMW_LOCKS_DIR/res-lock.lock"
fmw task prepare --project Resil --id res-locktask >/dev/null 2>&1 \
  && t_ok "prepare proceeds despite orphan lock file" || t_fail "prepare blocked by orphan lock"
[ -f "$FMW_TASKS_DIR/res-locktask.conf" ] && t_ok "conf written" || t_fail "conf missing"

# --- 6. missing Firstmate meta ---
t_begin "6: missing Firstmate meta -> source unknown none, STATE intact"
new_task res-nometa || { t_fail "prepare res-nometa"; }
rm -f "$FMW_FIRSTMATE_HOME/state/res-nometa.meta"
out="$(status_out res-nometa)"
echo "$out" | grep -q '^fm_meta=missing' && t_ok "meta absence reported" || t_fail "fm_meta: $(echo "$out" | grep '^fm_meta=')"
echo "$out" | grep -q '^STATE=spawned$' && t_ok "STATE intact" || t_fail "STATE changed"

# --- 7. contradictory status (source fails) ---
t_begin "7: contradictory status -> fail-closed, STATE intact"
new_task res-conflict || { t_fail "prepare res-conflict"; }
: > "$FMW_FIRSTMATE_HOME/state/res-conflict.turn-ended"
mkdir -p "$FMW_FIRSTMATE_HOME/data/res-conflict"
printf 'report\n' > "$FMW_FIRSTMATE_HOME/data/res-conflict/report.md"
fake_answer res-conflict "FAIL"
out="$(status_out res-conflict)"
echo "$out" | grep -q '^STATE=spawned$' && t_ok "STATE intact despite turn-ended+report (no source)" || t_fail "STATE invented"
echo "$out" | grep -q '^fm_state=unknown (source unavailable)$' && t_ok "unknown explained" || t_fail "fm_state: $(echo "$out" | grep '^fm_state=')"

# --- 8. terminal task with live window ---
t_begin "8: terminal task with live window -> teardown refuses (active agent)"
new_task res-win || { t_fail "prepare res-win"; }
printf 'v1 gen=1 seq=1 state=idle source=pi-ext event=agent-settled ts=1\n' > "$FMW_FIRSTMATE_HOME/state/res-win.busy-state"
fake_answer res-win "state: done · source: status-log · final report"
tmux new-session -d -s fmw-res >/dev/null 2>&1
tmux new-window -t fmw-res -n fm-res-win >/dev/null 2>&1
out="$(status_out res-win)"
echo "$out" | grep -q '^STATE=done$' && t_ok "done persisted (source authoritative)" || t_fail "STATE: $(echo "$out" | grep '^STATE=')"
if fmw task teardown res-win >/dev/null 2>&1; then
  t_fail "teardown should refuse with a live window"
else
  t_ok "teardown refuses with live window (controlled close required)"
fi
[ -d "$FMW_TESTLAB/wt/res-win" ] && t_ok "worktree preserved" || t_fail "worktree deleted"

# --- 9. active task with stale status (log says done: but source says busy) ---
t_begin "9: active task with stale status -> status-log is not a source"
new_task res-stale || { t_fail "prepare res-stale"; }
mkdir -p "$FMW_FIRSTMATE_HOME/state"
printf 'working: still analyzing\n' > "$FMW_FIRSTMATE_HOME/state/res-stale.status"
printf 'done: finished\n' >> "$FMW_FIRSTMATE_HOME/state/res-stale.status"
fake_answer res-stale "state: working · source: pane · harness busy (pi-ext)"
out="$(status_out res-stale)"
echo "$out" | grep -q '^STATE=spawned$' && t_ok "STATE intact (stale done: line not trusted)" || t_fail "STATE invented from stale log"
echo "$out" | grep -q '^fm_state=working$' && t_ok "operative state reflects the source" || t_fail "fm_state: $(echo "$out" | grep '^fm_state=')"

tmux kill-server >/dev/null 2>&1 || true
fmw_test_cleanup
t_summary
