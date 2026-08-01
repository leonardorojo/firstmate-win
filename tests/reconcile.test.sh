#!/usr/bin/env bash
# tests/reconcile.test.sh — terminal-state reconciliation and teardown
# eligibility. Runtime: WSL. Sandbox: /mnt/c/FirstmateWorktrees/TestLab.
#
# Coverage (16 PGM cases):
#   1.  spawned + Firstmate done:   -> STATE=done persisted
#   2.  spawned + Firstmate blocked:-> STATE=blocked persisted
#   3.  spawned + Firstmate failed: -> STATE=failed persisted
#   4.  .turn-ended without terminal status   -> STATE unchanged (not a source)
#   5.  report.md without terminal status     -> STATE unchanged (not a source)
#   6.  terminal status without .turn-ended   -> STATE=done (authoritative source)
#   7.  live window + done:              -> done; eligible after controlled close
#   8.  live window + blocked:           -> blocked; NOT eligible
#   9.  no window + terminal             -> eligible (no active agent)
#   10. contradictory data (source fails) -> fail-closed, STATE unchanged
#   11. missing status (source unknown)  -> STATE unchanged
#   12. reconciliation run twice         -> idempotent (identical conf)
#   13. corrupt conf                     -> status fails cleanly, no crash
#   14. missing meta                     -> source unknown none, STATE unchanged
#   15. clean worktree + terminal        -> eligible
#   16. dirty worktree + terminal        -> done persisted but NOT eligible
#
# Note: the "authoritative source" is simulated with a fake fm-crew-state.sh
# that answers from fake-answers/<id>; this tests the wrapper logic without
# depending on the real upstream script (its semantics are audited separately).

set -uo pipefail
cd "$(dirname "$0")" || exit 1
. ./harness.sh
. "$FMW_LIB_DIR/firstmate.sh"     # fmw_task_conf_set / fmw_firstmate_bin
. "$FMW_LIB_DIR/reconcile.sh"     # fmw_crew_state / fmw_task_reconcile / ...

fmw_test_setup_sandbox || { echo "FATAL: could not create the sandbox" >&2; exit 1; }
fmw_test_make_repo "$FMW_TESTLAB/repo"
fmw_test_make_profile recon
mkdir -p "$FMW_TESTLAB/wt"
fmw project add --name Recon \
  --windows-path "C:\\FirstmateWorktrees\\TestLab\\repo" \
  --worktree-root "C:\\FirstmateWorktrees\\TestLab\\wt" \
  --profile recon >/dev/null 2>&1 \
  || { echo "FATAL: could not register the Recon project" >&2; exit 1; }

# --- fake fm-crew-state.sh (simulated authoritative source) ---
cat > "$FMW_FIRSTMATE_HOME/bin/fm-crew-state.sh" <<'FAKE'
#!/usr/bin/env bash
id="${1:-}"
ans="${FMW_FIRSTMATE_HOME}/fake-answers/${id}"
[ -f "$ans" ] || { echo "state: unknown · source: none · no metadata for ${id}"; exit 0; }
if grep -qx 'FAIL' "$ans"; then echo "state: unknown · source: none · fake failure" >&2; exit 3; fi
cat "$ans"
FAKE
chmod +x "$FMW_FIRSTMATE_HOME/bin/fm-crew-state.sh"
mkdir -p "$FMW_FIRSTMATE_HOME/fake-answers" "$FMW_FIRSTMATE_HOME/data"

# --- helpers --------------------------------------------------------------
fake_answer() { printf '%s\n' "$2" > "$FMW_FIRSTMATE_HOME/fake-answers/$1"; }
touch_turn_end() { : > "$FMW_FIRSTMATE_HOME/state/$1.turn-ended"; }
write_report()   { mkdir -p "$FMW_FIRSTMATE_HOME/data/$1"; printf 'report\n' > "$FMW_FIRSTMATE_HOME/data/$1/report.md"; }
write_busy()     { printf 'v1 gen=1 seq=7 state=%s source=pi-ext event=agent-settled ts=1785531227\n' "$2" > "$FMW_FIRSTMATE_HOME/state/$1.busy-state"; }

# new_task <id> — prepares the real task (worktree + conf) and leaves it spawned
new_task() {
  fmw task prepare --project Recon --id "$1" >/dev/null 2>&1 || return 1
  fmw_task_conf_set "$1" "STATE='spawned'" || return 1
}

# status_out <id> — CLI output (stdout+stderr)
status_out() {
  fmw task status "$1" 2>&1
}

# --- cases -----------------------------------------------------------------

# 1+15: spawned + done, clean worktree, no window, no turn-ended (also 6 and 9)
t_begin "1: spawned + done -> STATE=done persisted (clean worktree, no window; 6 and 9)"
new_task recon-done || { t_fail "prepare recon-done"; }
fake_answer recon-done "state: done · source: status-log · final SCOUT report"
write_report recon-done
out="$(status_out recon-done)"
echo "$out" | grep -q '^STATE=done$' && t_ok "STATE=done in the status" || t_fail "STATE=done missing: $(echo "$out" | grep '^STATE=')"
echo "$out" | grep -q '^fm_state=done$' && t_ok "fm_state=done" || t_fail "fm_state"
echo "$out" | grep -q '^fm_state_source=status-log$' && t_ok "fm_state_source=status-log" || t_fail "fm_state_source"
echo "$out" | grep -q '^fm_turn_ended=no$' && t_ok "6: done without .turn-ended (authoritative source)" || t_fail "unexpected turn_ended"
echo "$out" | grep -q '^fm_report=yes$' && t_ok "fm_report=yes" || t_fail "fm_report"
echo "$out" | grep -q '^fm_teardown_elegible=yes (clean worktree; no active agent)$' \
  && t_ok "9+15: eligible (no agent, clean worktree)" || t_fail "eligibility: $(echo "$out" | grep '^fm_teardown_elegible=')"
fmw_task_load recon-done
t_assert_eq "$STATE" "done" "1: conf persisted with STATE=done"

# 12: idempotency (second run)
t_begin "12: reconciliation twice -> idempotent"
cp "$FMW_TASKS_DIR/recon-done.conf" "$FMW_TESTLAB/conf.before"
out2="$(status_out recon-done)"
cmp -s "$FMW_TASKS_DIR/recon-done.conf" "$FMW_TESTLAB/conf.before" \
  && t_ok "second run did not alter the conf" || t_fail "the conf changed on the 2nd run"
echo "$out2" | grep -q "already terminal (STATE=done)" && t_ok "idempotent log (no transition)" || t_fail "no idempotent message"

# 2: blocked
t_begin "2: spawned + blocked -> STATE=blocked, NOT eligible"
new_task recon-blocked || { t_fail "prepare recon-blocked"; }
fake_answer recon-blocked "state: blocked · source: status-log · tasks-axi not on PATH"
out="$(status_out recon-blocked)"
echo "$out" | grep -q '^STATE=blocked$' && t_ok "STATE=blocked persisted" || t_fail "STATE: $(echo "$out" | grep '^STATE=')"
echo "$out" | grep -q '^fm_teardown_elegible=no: STATE=blocked (eligible only with STATE=done or STATE=abandoned)$' \
  && t_ok "blocked not eligible" || t_fail "eligibility: $(echo "$out" | grep '^fm_teardown_elegible=')"

# 3: failed
t_begin "3: spawned + failed -> STATE=failed, NOT eligible"
new_task recon-failed || { t_fail "prepare recon-failed"; }
fake_answer recon-failed "state: failed · source: status-log · build failed"
out="$(status_out recon-failed)"
echo "$out" | grep -q '^STATE=failed$' && t_ok "STATE=failed persisted" || t_fail "STATE: $(echo "$out" | grep '^STATE=')"
echo "$out" | grep -q '^fm_teardown_elegible=no: STATE=failed (eligible only with STATE=done or STATE=abandoned)$' \
  && t_ok "failed not eligible" || t_fail "eligibility: $(echo "$out" | grep '^fm_teardown_elegible=')"

# 4: .turn-ended without terminal state
t_begin "4: .turn-ended without terminal status -> STATE unchanged"
new_task recon-turnend || { t_fail "prepare recon-turnend"; }
touch_turn_end recon-turnend
fake_answer recon-turnend "state: working · source: pane · harness busy (pi-ext)"
out="$(status_out recon-turnend)"
echo "$out" | grep -q '^STATE=spawned$' && t_ok "STATE stays spawned (turn-ended is not a source)" || t_fail "STATE: $(echo "$out" | grep '^STATE=')"
echo "$out" | grep -q '^fm_turn_ended=yes$' && t_ok "turn-ended shown as evidence" || t_fail "fm_turn_ended"

# 5: report.md without terminal state
t_begin "5: report.md without terminal status -> STATE unchanged"
new_task recon-report || { t_fail "prepare recon-report"; }
write_report recon-report
fake_answer recon-report "state: parked · source: status-log · needs-decision: approve scope"
out="$(status_out recon-report)"
echo "$out" | grep -q '^STATE=spawned$' && t_ok "STATE stays spawned (report.md is not a source)" || t_fail "STATE: $(echo "$out" | grep '^STATE=')"
echo "$out" | grep -q '^fm_state=parked$' && t_ok "operative parked shown without persisting" || t_fail "fm_state: $(echo "$out" | grep '^fm_state=')"

# 7: live window + done (idle agent)
t_begin "7: live window + done -> done persisted; eligible after controlled close"
new_task recon-win-done || { t_fail "prepare recon-win-done"; }
write_busy recon-win-done idle
fake_answer recon-win-done "state: done · source: status-log · final SCOUT report"
tmux new-session -d -s fmw-rec >/dev/null 2>&1
tmux new-window -t fmw-rec -n fm-recon-win-done >/dev/null 2>&1
out="$(status_out recon-win-done)"
echo "$out" | grep -q '^STATE=done$' && t_ok "STATE=done with live window (idle)" || t_fail "STATE: $(echo "$out" | grep '^STATE=')"
echo "$out" | grep -q '^fm_window=active (fm-recon-win-done in tmux)$' && t_ok "window detected" || t_fail "fm_window"
echo "$out" | grep -q '^fm_agent_busy=idle$' && t_ok "busy-state idle" || t_fail "fm_agent_busy"
echo "$out" | grep -q '^fm_teardown_elegible=yes (clean worktree; requires controlled close of the fm-recon-win-done window)$' \
  && t_ok "eligible with controlled close" || t_fail "eligibility: $(echo "$out" | grep '^fm_teardown_elegible=')"

# 8: live window + blocked
t_begin "8: live window + blocked -> blocked, NOT eligible"
new_task recon-win-blocked || { t_fail "prepare recon-win-blocked"; }
write_busy recon-win-blocked idle
fake_answer recon-win-blocked "state: blocked · source: status-log · waiting for captain"
tmux new-window -t fmw-rec -n fm-recon-win-blocked >/dev/null 2>&1
out="$(status_out recon-win-blocked)"
echo "$out" | grep -q '^STATE=blocked$' && t_ok "STATE=blocked with live window" || t_fail "STATE: $(echo "$out" | grep '^STATE=')"
echo "$out" | grep -q '^fm_teardown_elegible=no: STATE=blocked (eligible only with STATE=done or STATE=abandoned)$' \
  && t_ok "not eligible (blocked)" || t_fail "eligibility: $(echo "$out" | grep '^fm_teardown_elegible=')"

# 7b: live window + done + busy-state busy -> NOT eligible (fail-closed)
t_begin "7b: live window + done but busy-state=busy -> NOT eligible"
new_task recon-win-busy || { t_fail "prepare recon-win-busy"; }
write_busy recon-win-busy busy
fake_answer recon-win-busy "state: done · source: status-log · final report"
tmux new-window -t fmw-rec -n fm-recon-win-busy >/dev/null 2>&1
out="$(status_out recon-win-busy)"
echo "$out" | grep -q '^fm_teardown_elegible=no: agent busy (busy-state=busy)$' \
  && t_ok "fail-closed with busy agent" || t_fail "eligibility: $(echo "$out" | grep '^fm_teardown_elegible=')"

# 7c: live window + done + missing busy-state -> NOT eligible (fail-closed)
t_begin "7c: live window + done without busy-state -> NOT eligible (fail-closed)"
new_task recon-win-nobusy || { t_fail "prepare recon-win-nobusy"; }
fake_answer recon-win-nobusy "state: done · source: status-log · final report"
tmux new-window -t fmw-rec -n fm-recon-win-nobusy >/dev/null 2>&1
out="$(status_out recon-win-nobusy)"
echo "$out" | grep -q '^fm_teardown_elegible=no: active window without verifiable idle state (busy-state=missing)$' \
  && t_ok "fail-closed without busy-state" || t_fail "eligibility: $(echo "$out" | grep '^fm_teardown_elegible=')"

# 10: contradictory data — the source fails (fail-closed)
t_begin "10: source fails (.turn-ended + report.md present) -> STATE unchanged"
new_task recon-conflict || { t_fail "prepare recon-conflict"; }
touch_turn_end recon-conflict
write_report recon-conflict
fake_answer recon-conflict "FAIL"
out="$(status_out recon-conflict)"
echo "$out" | grep -q '^STATE=spawned$' && t_ok "fail-closed: STATE unchanged despite turn-ended+report" || t_fail "STATE: $(echo "$out" | grep '^STATE=')"
echo "$out" | grep -q '^fm_state=unknown (source unavailable)$' && t_ok "operative state unknown" || t_fail "fm_state"
echo "$out" | grep -q '^fm_teardown_elegible=no: STATE=spawned (eligible only with STATE=done or STATE=abandoned)$' \
  && t_ok "not eligible" || t_fail "eligibility: $(echo "$out" | grep '^fm_teardown_elegible=')"

# 11: missing status -> source unknown
t_begin "11: no status file (source unknown) -> STATE unchanged"
new_task recon-nostatus || { t_fail "prepare recon-nostatus"; }
# no fake-answers => the fake answers unknown none (no metadata)
out="$(status_out recon-nostatus)"
echo "$out" | grep -q '^STATE=spawned$' && t_ok "STATE unchanged with unknown" || t_fail "STATE: $(echo "$out" | grep '^STATE=')"
echo "$out" | grep -q '^fm_state=unknown$' && t_ok "fm_state=unknown" || t_fail "fm_state: $(echo "$out" | grep '^fm_state=')"
echo "$out" | grep -q '^fm_teardown_elegible=no: STATE=spawned (eligible only with STATE=done or STATE=abandoned)$' \
  && t_ok "not eligible" || t_fail "eligibility"

# 13: corrupt conf
t_begin "13: corrupt conf -> status fails cleanly, no crash"
new_task recon-corrupt || { t_fail "prepare recon-corrupt"; }
printf 'garbage\nnot=valid\n' > "$FMW_TASKS_DIR/recon-corrupt.conf"
if fmw task status recon-corrupt >/dev/null 2>"$FMW_TESTLAB/corrupt.err"; then
  t_fail "status with corrupt conf should fail"
else
  grep -q 'corrupt task config' "$FMW_TESTLAB/corrupt.err" \
    && t_ok "clean failure: 'corrupt task config'" || t_fail "message: $(cat "$FMW_TESTLAB/corrupt.err")"
fi

# 14: missing meta
t_begin "14: no Firstmate meta (source unknown none) -> STATE unchanged"
new_task recon-nometa || { t_fail "prepare recon-nometa"; }
fake_answer recon-nometa "state: unknown · source: none · no metadata for recon-nometa"
out="$(status_out recon-nometa)"
echo "$out" | grep -q '^STATE=spawned$' && t_ok "STATE unchanged without meta" || t_fail "STATE: $(echo "$out" | grep '^STATE=')"
echo "$out" | grep -q '^fm_meta=missing (task not spawned)$' && t_ok "fm_meta=missing reported" || t_fail "fm_meta: $(echo "$out" | grep '^fm_meta=')"
echo "$out" | grep -q '^fm_state=unknown$' && t_ok "fm_state=unknown" || t_fail "fm_state"

# 16: dirty worktree + terminal
t_begin "16: dirty worktree + done -> done persisted but NOT eligible"
new_task recon-dirty || { t_fail "prepare recon-dirty"; }
fake_answer recon-dirty "state: done · source: status-log · final report"
git -C "$FMW_TESTLAB/wt/recon-dirty" config user.email "fmw-test@local"
git -C "$FMW_TESTLAB/wt/recon-dirty" config user.name "fmw-test"
printf 'local change\n' > "$FMW_TESTLAB/wt/recon-dirty/dirty.txt"
out="$(status_out recon-dirty)"
echo "$out" | grep -q '^STATE=done$' && t_ok "STATE=done persisted (dirty does not block the state)" || t_fail "STATE: $(echo "$out" | grep '^STATE=')"
echo "$out" | grep -q '^fm_teardown_elegible=no: worktree has local changes$' \
  && t_ok "NOT eligible with dirty worktree" || t_fail "eligibility: $(echo "$out" | grep '^fm_teardown_elegible=')"

# --- cleanup ---------------------------------------------------------------
tmux kill-server 2>/dev/null || true   # only the isolated test socket
fmw_test_cleanup
t_summary
