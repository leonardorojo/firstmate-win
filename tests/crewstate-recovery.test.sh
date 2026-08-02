# tests/crewstate-recovery.test.sh — regression for the Sprint 7 crew-state
# corruption incident: a test fake overwrote the REAL ~/firstmate crew-state,
# so every reconciliation reported fm_state=unknown "no metadata for <id>"
# even for a finished agent (done: log + .turn-ended + report + live window).
#
#   Scenario (exactly the reported task): meta exists, status log ends with
#   done:, .turn-ended present, window alive, busy-state stale (busy).
#   1. corrupt source (the test stub)  -> fm_state=unknown, STATE intact
#   2. restored source (status-log reader) -> fm_state=done, STATE=done
. "$(dirname "$0")/harness.sh"
. "$FMW_LIB_DIR/firstmate.sh"   # fmw_task_conf_set
. "$FMW_LIB_DIR/reconcile.sh"   # fmw_task_reconcile / crew state

fmw_test_setup_sandbox
fmw_test_assert_sandboxed
fmw_test_make_repo "$FMW_TESTLAB/repo"
fmw_test_make_profile "csr"
mkdir -p "$FMW_TESTLAB/wt"
fmw project add --name Csr \
  --windows-path "C:\\FirstmateWorktrees\\TestLab\\repo" \
  --worktree-root "C:\\FirstmateWorktrees\\TestLab\\wt" \
  --profile csr >/dev/null 2>&1 \
  || { echo "   FATAL: could not register Csr"; exit 1; }

# --- the CORRUPT source: the 6-line test stub that overwrote the real one ---
mkdir -p "$FMW_FIRSTMATE_HOME/bin" "$FMW_FIRSTMATE_HOME/state" "$FMW_FIRSTMATE_HOME/data"
cat > "$FMW_FIRSTMATE_HOME/bin/fm-crew-state.sh" <<'CORRUPT'
#!/usr/bin/env bash
id="${1:-}"
ans="${FMW_FIRSTMATE_HOME}/fake-answers/${id}"
[ -f "$ans" ] || { echo "state: unknown · source: none · no metadata for ${id}"; exit 0; }
if grep -qx 'FAIL' "$ans"; then echo "state: unknown · source: none · fake failure" >&2; exit 3; fi
cat "$ans"
CORRUPT
chmod +x "$FMW_FIRSTMATE_HOME/bin/fm-crew-state.sh"

# --- the RESTORED source: emulates the real upstream crew-state for the
#     done-at-status-log case (what the original reports for a finished crew) ---
cat > "$FMW_FIRSTMATE_HOME/bin/fm-crew-state-restored.sh" <<'RESTORED'
#!/usr/bin/env bash
# minimal emulation of the upstream fm-crew-state.sh terminal mapping:
# a status log whose last line starts with done: is the terminal source
id="${1:-}"
log="$FMW_FIRSTMATE_HOME/state/${id}.status"   # FMW_FIRSTMATE_HOME/state in the sandbox
[ -f "$log" ] || { echo "state: unknown · source: none · no metadata for ${id}"; exit 0; }
last="$(tail -1 "$log")"
case "$last" in
  done:*)  echo "state: done · source: status-log · ${last#done: }" ;;
  blocked:*) echo "state: blocked · source: status-log · ${last#blocked: }" ;;
  failed:*) echo "state: failed · source: status-log · ${last#failed: }" ;;
  needs-decision:*) echo "state: blocked · source: status-log · ${last#needs-decision: }" ;;
  *) echo "state: working · source: status-log · ${last}" ;;
esac
RESTORED
chmod +x "$FMW_FIRSTMATE_HOME/bin/fm-crew-state-restored.sh"

# --- build the exact reported task state ---
fmw task prepare --project Csr --id cs-finished >/dev/null 2>&1 || { t_fail "prepare"; }
fmw_task_conf_set "cs-finished" "STATE='spawned'" || t_fail "conf_set"
# Firstmate-side metadata of a real spawn
cat > "$FMW_FIRSTMATE_HOME/state/cs-finished.meta" <<META
window=firstmate:fm-cs-finished
endpoint_task_id=cs-finished
worktree=$FMW_TESTLAB/wt/cs-finished
project=$FMW_TESTLAB/repo
harness=pi
kind=scout
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-cs-finished
model=default
busy_gen=g1.1
META
# status log ending in done: + turn-ended + stale busy-state + live window
printf 'working: inspecting\nworking: analyzing\ndone: report written; no code changes recommended\n' > "$FMW_FIRSTMATE_HOME/state/cs-finished.status"
: > "$FMW_FIRSTMATE_HOME/state/cs-finished.turn-ended"
printf 'v1 gen=g1.1 seq=2 state=busy source=pi-ext event=agent-start ts=1\n' > "$FMW_FIRSTMATE_HOME/state/cs-finished.busy-state"
mkdir -p "$FMW_FIRSTMATE_HOME/data/cs-finished"
printf '# report\n' > "$FMW_FIRSTMATE_HOME/data/cs-finished/report.md"
tmux new-session -d -s fmw-csr >/dev/null 2>&1
tmux new-window -t fmw-csr -n fm-cs-finished >/dev/null 2>&1

# --- 1. with the CORRUPT source: unknown, STATE intact, not invented done ---
t_begin "1: corrupt crew-state -> fm_state=unknown, STATE intact"
out="$(fmw task status cs-finished 2>&1)"
echo "$out" | grep -q '^fm_state=unknown$' && t_ok "fm_state=unknown (source corrupt)" || t_fail "fm_state: $(echo "$out" | grep '^fm_state=')"
echo "$out" | grep -q '^STATE=spawned$' && t_ok "STATE intact (no invented done)" || t_fail "STATE: $(echo "$out" | grep '^STATE=')"
echo "$out" | grep -q '^fm_report=yes$' && t_ok "report detected" || t_fail "report missing"
echo "$out" | grep -q '^fm_turn_ended=yes$' && t_ok "turn-ended detected" || t_fail "turn-ended missing"
echo "$out" | grep -q '^fm_teardown_elegible=no:' && t_ok "teardown not eligible (spawned)" || t_fail "eligibility wrong"

# --- 2. with the RESTORED source: done from the authoritative status log ---
t_begin "2: restored crew-state -> fm_state=done, STATE=done"
cp "$FMW_FIRSTMATE_HOME/bin/fm-crew-state-restored.sh" "$FMW_FIRSTMATE_HOME/bin/fm-crew-state.sh"
out="$(fmw task status cs-finished 2>&1)"
echo "$out" | grep -q '^fm_state=done$' && t_ok "fm_state=done (source status-log)" || t_fail "fm_state: $(echo "$out" | grep '^fm_state=')"
echo "$out" | grep -q '^STATE=done$' && t_ok "STATE reconciled to done" || t_fail "STATE: $(echo "$out" | grep '^STATE=')"
grep -q "^STATE='done'$" "$FMW_TASKS_DIR/cs-finished.conf" && t_ok "done persisted" || t_fail "done not persisted"
# live window + stale busy => still not teardown-eligible (controlled close first)
echo "$out" | grep -q '^fm_teardown_elegible=no:' && t_ok "not eligible yet (live window + busy)" || t_fail "eligibility: $(echo "$out" | grep '^fm_teardown_elegible=')"

# --- 3. idempotence of the reconciliation ---
t_begin "3: reconciliation idempotent"
out="$(fmw task status cs-finished 2>&1)"
echo "$out" | grep -q '^STATE=done$' && t_ok "second run keeps done" || t_fail "STATE regressed"

tmux kill-server >/dev/null 2>&1 || true
fmw_test_cleanup
t_summary
