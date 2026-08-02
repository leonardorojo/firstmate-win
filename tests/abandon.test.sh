# tests/abandon.test.sh — fmw task abandon: explicit orphaned-task transition
#   Regression matrix for the fail-closed 'abandoned' state:
#     1. clean orphan + explicit authorization -> eligible, teardown works
#     2. live window               -> refused
#     3. live agent (busy-state)   -> refused
#     4. dirty worktree            -> refused
#     5. HEAD != BASE_REF          -> refused
#     6. contradictory metadata    -> refused (operative state not unknown)
#     7. no explicit authorization -> teardown of a spawned task is refused
#     8. idempotent                -> abandon twice is a no-op
. "$(dirname "$0")/harness.sh"
. "$FMW_LIB_DIR/firstmate.sh"   # fmw_task_conf_set (not loaded by the harness)
. "$FMW_LIB_DIR/reconcile.sh"   # fmw_task_reconcile / teardown eligibility

fmw_test_setup_sandbox
fmw_test_assert_sandboxed
fmw_test_make_repo "$FMW_TESTLAB/repo"
fmw_test_make_profile "abnd"
mkdir -p "$FMW_TESTLAB/wt"
fmw project add --name Abnd \
  --windows-path "C:\\FirstmateWorktrees\\TestLab\\repo" \
  --worktree-root "C:\\FirstmateWorktrees\\TestLab\\wt" \
  --profile abnd >/dev/null 2>&1 \
  || { echo "   FATAL: could not register Abnd"; exit 1; }

# --- fake crew-state: unknown unless a fake-answer exists ---
mkdir -p "$FMW_FIRSTMATE_HOME/bin" "$FMW_FIRSTMATE_HOME/state" "$FMW_FIRSTMATE_HOME/data"
cat > "$FMW_FIRSTMATE_HOME/bin/fm-crew-state.sh" <<'FAKE'
#!/usr/bin/env bash
id="${1:-}"
ans="${FMW_FIRSTMATE_HOME}/fake-answers/${id}"
[ -f "$ans" ] && { cat "$ans"; exit 0; }
echo "state: unknown · source: none · no metadata for ${id}"
FAKE
chmod +x "$FMW_FIRSTMATE_HOME/bin/fm-crew-state.sh"
mkdir -p "$FMW_FIRSTMATE_HOME/fake-answers"

fake_answer() { printf '%s\n' "$2" > "$FMW_FIRSTMATE_HOME/fake-answers/$1"; }
base_ref() { git -C "$FMW_TESTLAB/repo" rev-parse HEAD; }
new_task() {
  fmw task prepare --project Abnd --id "$1" >/dev/null 2>&1 || return 1
  fmw_task_conf_set "$1" "STATE='spawned'" || return 1
}

# --- 1. clean orphan + explicit authorization -> eligible, teardown works ---
t_begin "1: clean orphan + authorization -> abandoned, eligible, teardown OK"
new_task ab-orphan || { t_fail "prepare ab-orphan"; }
t_assert_false fmw_safety_agent_window_exists ab-orphan
fmw task abandon ab-orphan --reason "resilience test" >/dev/null 2>&1 \
  && t_ok "abandon accepted" || t_fail "abandon refused for a clean orphan"
grep -q "^STATE='abandoned'$" "$FMW_TASKS_DIR/ab-orphan.conf" && t_ok "STATE=abandoned persisted" || t_fail "STATE not persisted"
grep -q "^ABANDONED_AT=" "$FMW_TASKS_DIR/ab-orphan.conf" && t_ok "ABANDONED_AT persisted" || t_fail "ABANDONED_AT missing"
grep -q "^ABANDON_REASON='resilience test'$" "$FMW_TASKS_DIR/ab-orphan.conf" && t_ok "ABANDON_REASON persisted" || t_fail "ABANDON_REASON missing"
fmw_task_teardown_elegible ab-orphan >/dev/null 2>&1 \
  && t_ok "teardown eligible after abandon" || t_fail "not eligible after abandon"
if fmw task teardown ab-orphan >/dev/null 2>&1; then
  t_ok "teardown OK (worktree removed)"
else
  t_fail "teardown refused after abandon"
fi
t_assert_false test -d "$FMW_TESTLAB/wt/ab-orphan"  # worktree removed
git -C "$FMW_TESTLAB/repo" rev-parse --verify refs/heads/firstmate/ab-orphan >/dev/null 2>&1 \
  && t_ok "branch kept" || t_fail "branch missing"
grep -q "^STATE='torn-down'$" "$FMW_ARCHIVE_DIR/ab-orphan.conf" 2>/dev/null \
  && t_ok "archived torn-down" || t_fail "archive missing/incomplete"
grep -q "^ABANDON_REASON='resilience test'$" "$FMW_ARCHIVE_DIR/ab-orphan.conf" 2>/dev/null \
  && t_ok "archive carries the abandon trace" || t_fail "archive lost the abandon trace"

# --- 2. live window -> refused ---
t_begin "2: live window -> refused"
new_task ab-win || { t_fail "prepare ab-win"; }
tmux new-session -d -s fmw-ab >/dev/null 2>&1
tmux new-window -t fmw-ab -n fm-ab-win >/dev/null 2>&1
if fmw task abandon ab-win >/dev/null 2>&1; then
  t_fail "abandon accepted with a live window"
else
  t_ok "abandon refused with a live window"
fi
grep -q "^STATE='spawned'$" "$FMW_TASKS_DIR/ab-win.conf" && t_ok "STATE untouched" || t_fail "STATE changed"

# --- 3. live agent (busy-state busy) -> refused ---
t_begin "3: busy agent -> refused"
new_task ab-busy || { t_fail "prepare ab-busy"; }
printf 'v1 gen=1 seq=2 state=busy source=pi-ext event=agent-start ts=1\n' > "$FMW_FIRSTMATE_HOME/state/ab-busy.busy-state"
if fmw task abandon ab-busy >/dev/null 2>&1; then
  t_fail "abandon accepted with a busy agent"
else
  t_ok "abandon refused with a busy agent"
fi
grep -q "^STATE='spawned'$" "$FMW_TASKS_DIR/ab-busy.conf" && t_ok "STATE untouched" || t_fail "STATE changed"

# --- 4. dirty worktree -> refused ---
t_begin "4: dirty worktree -> refused"
new_task ab-dirty || { t_fail "prepare ab-dirty"; }
echo "dirty" > "$FMW_TESTLAB/wt/ab-dirty/pollution.txt"
if fmw task abandon ab-dirty >/dev/null 2>&1; then
  t_fail "abandon accepted with a dirty worktree"
else
  t_ok "abandon refused with a dirty worktree"
fi
grep -q "^STATE='spawned'$" "$FMW_TASKS_DIR/ab-dirty.conf" && t_ok "STATE untouched" || t_fail "STATE changed"

# --- 5. HEAD != BASE_REF -> refused ---
t_begin "5: HEAD != BASE_REF -> refused"
new_task ab-head || { t_fail "prepare ab-head"; }
git -C "$FMW_TESTLAB/wt/ab-head" -c user.email=t@t -c user.name=t commit --allow-empty -m drift >/dev/null 2>&1
if fmw task abandon ab-head >/dev/null 2>&1; then
  t_fail "abandon accepted with HEAD != BASE_REF"
else
  t_ok "abandon refused with HEAD != BASE_REF"
fi
grep -q "^STATE='spawned'$" "$FMW_TASKS_DIR/ab-head.conf" && t_ok "STATE untouched" || t_fail "STATE changed"

# --- 6. contradictory metadata (operative state not unknown) -> refused ---
t_begin "6: contradictory metadata -> refused"
new_task ab-live || { t_fail "prepare ab-live"; }
fake_answer ab-live "state: working · source: pane · harness busy (pi-ext)"
if fmw task abandon ab-live >/dev/null 2>&1; then
  t_fail "abandon accepted with a live operative state"
else
  t_ok "abandon refused (operative state working)"
fi
grep -q "^STATE='spawned'$" "$FMW_TASKS_DIR/ab-live.conf" && t_ok "STATE untouched" || t_fail "STATE changed"

# --- 7. no explicit authorization -> teardown of a spawned task is refused ---
t_begin "7: no authorization -> teardown of spawned refused"
new_task ab-noauth || { t_fail "prepare ab-noauth"; }
if fmw task teardown ab-noauth >/dev/null 2>&1; then
  t_fail "teardown accepted for a spawned task without abandon"
else
  t_ok "teardown refused (STATE=spawned; resolve first)"
fi
[ -d "$FMW_TESTLAB/wt/ab-noauth" ] && t_ok "worktree preserved" || t_fail "worktree removed"

# --- 8. idempotent ---
t_begin "8: idempotent"
new_task ab-again || { t_fail "prepare ab-again"; }
fmw task abandon ab-again --reason "first" >/dev/null 2>&1
first="$(grep '^ABANDONED_AT=' "$FMW_TASKS_DIR/ab-again.conf")"
if fmw task abandon ab-again --reason "second" >/dev/null 2>&1; then
  t_ok "second abandon is a no-op (rc=0)"
else
  t_fail "second abandon failed"
fi
second="$(grep '^ABANDONED_AT=' "$FMW_TASKS_DIR/ab-again.conf")"
[ "$first" = "$second" ] && t_ok "state unchanged by the second abandon" || t_fail "state changed on repeat"
grep -q "^ABANDON_REASON='first'$" "$FMW_TASKS_DIR/ab-again.conf" && t_ok "reason not overwritten" || t_fail "reason overwritten"

tmux kill-server >/dev/null 2>&1 || true
fmw_test_cleanup
t_summary
