# tests/multirepo.test.sh — multi-repository isolation
#   Verifies that two registered projects can run tasks concurrently with
#   full per-project isolation: independent worktrees, branches, metadata,
#   spawned state, reconciliation and teardown. Everything runs against the
#   disposable sandbox; the wrapper code must be project-agnostic.
. "$(dirname "$0")/harness.sh"

fmw_test_setup_sandbox
fmw_test_make_repo "$FMW_TESTLAB/repo-a"
fmw_test_make_repo "$FMW_TESTLAB/repo-b"
fmw_test_make_profile "pa"
fmw_test_make_profile "pb"
mkdir -p "$FMW_TESTLAB/wt-a" "$FMW_TESTLAB/wt-b"

# --- fake firstmate scripts (record invocations) ---
mkdir -p "$FMW_FIRSTMATE_HOME/bin" "$FMW_FIRSTMATE_HOME/state" "$FMW_FIRSTMATE_HOME/data"
for s in fm-brief.sh fm-spawn.sh fm-send.sh; do
  cat > "$FMW_FIRSTMATE_HOME/bin/$s" <<EOF
#!/usr/bin/env bash
echo "$s \$*" >> "$FMW_FIRSTMATE_HOME/calls.log"
exit 0
EOF
  chmod +x "$FMW_FIRSTMATE_HOME/bin/$s"
done
# fake fm-crew-state.sh: answers from fake-answers/<id>
cat > "$FMW_FIRSTMATE_HOME/bin/fm-crew-state.sh" <<'FAKE'
#!/usr/bin/env bash
id="${1:-}"
ans="${FMW_FIRSTMATE_HOME}/fake-answers/${id}"
[ -f "$ans" ] || { echo "state: unknown · source: none · no metadata for ${id}"; exit 0; }
cat "$ans"
FAKE
chmod +x "$FMW_FIRSTMATE_HOME/bin/fm-crew-state.sh"
mkdir -p "$FMW_FIRSTMATE_HOME/fake-answers"

# --- register two projects ---
fmw project add --name ProjA \
  --windows-path "C:\\FirstmateWorktrees\\TestLab\\repo-a" \
  --worktree-root "C:\\FirstmateWorktrees\\TestLab\\wt-a" \
  --profile pa >/dev/null 2>&1 \
  || { echo "   FATAL: could not register ProjA"; exit 1; }
fmw project add --name ProjB \
  --windows-path "C:\\FirstmateWorktrees\\TestLab\\repo-b" \
  --worktree-root "C:\\FirstmateWorktrees\\TestLab\\wt-b" \
  --profile pb >/dev/null 2>&1 \
  || { echo "   FATAL: could not register ProjB"; exit 1; }

t_begin "multirepo: two projects registered independently"

list_out=$(fmw project list)
echo "$list_out" | grep -q "ProjA" && t_ok "list contains ProjA" || t_fail "ProjA missing"
echo "$list_out" | grep -q "ProjB" && t_ok "list contains ProjB" || t_fail "ProjB missing"

t_begin "multirepo: simultaneous prepare (one task per project)"

prep_a=$(fmw task prepare --project ProjA --id task-a 2>&1) || { t_fail "prepare task-a: $prep_a"; }
prep_b=$(fmw task prepare --project ProjB --id task-b 2>&1) || { t_fail "prepare task-b: $prep_b"; }
t_assert_true test -d "$FMW_TESTLAB/wt-a/task-a"
t_assert_true test -d "$FMW_TESTLAB/wt-b/task-b"
t_assert_false test -d "$FMW_TESTLAB/wt-a/task-b" # task-b not under ProjA root
t_assert_false test -d "$FMW_TESTLAB/wt-b/task-a" # task-a not under ProjB root

# branches live in the correct repositories
git -C "$FMW_TESTLAB/repo-a" rev-parse --verify refs/heads/firstmate/task-a >/dev/null 2>&1 \
  && t_ok "branch firstmate/task-a in repo-a" || t_fail "branch task-a missing in repo-a"
git -C "$FMW_TESTLAB/repo-b" rev-parse --verify refs/heads/firstmate/task-b >/dev/null 2>&1 \
  && t_ok "branch firstmate/task-b in repo-b" || t_fail "branch task-b missing in repo-b"

# confs carry the right project
if fmw_conf_load "$FMW_TASKS_DIR/task-a.conf" "${FMW_TASK_CONF_KEYS[@]}"; then
  t_assert_eq "$PROJECT_NAME" "ProjA" "task-a -> ProjA"
  t_assert_eq "$WORKTREE_WSL_PATH" "$FMW_TESTLAB/wt-a/task-a" "task-a worktree path"
else
  t_fail "could not load task-a conf"
fi
if fmw_conf_load "$FMW_TASKS_DIR/task-b.conf" "${FMW_TASK_CONF_KEYS[@]}"; then
  t_assert_eq "$PROJECT_NAME" "ProjB" "task-b -> ProjB"
  t_assert_eq "$WORKTREE_WSL_PATH" "$FMW_TESTLAB/wt-b/task-b" "task-b worktree path"
else
  t_fail "could not load task-b conf"
fi

t_begin "multirepo: brief + spawn use each project's repository"

rm -f "$FMW_FIRSTMATE_HOME/calls.log"
fmw task brief task-a --scout
fmw task brief task-b --scout
calls="$(cat "$FMW_FIRSTMATE_HOME/calls.log" 2>/dev/null)"
echo "$calls" | grep -q "fm-brief.sh task-a repo-a --scout" \
  && t_ok "brief task-a -> repo-a" || t_fail "brief task-a wrong: $calls"
echo "$calls" | grep -q "fm-brief.sh task-b repo-b --scout" \
  && t_ok "brief task-b -> repo-b" || t_fail "brief task-b wrong: $calls"

# simulate firstmate meta per task, then spawn
printf 'window=fm-task-a\nendpoint_task_id=task-a\nbackend=tmux\n' > "$FMW_FIRSTMATE_HOME/state/task-a.meta"
printf 'window=fm-task-b\nendpoint_task_id=task-b\nbackend=tmux\n' > "$FMW_FIRSTMATE_HOME/state/task-b.meta"
rm -f "$FMW_FIRSTMATE_HOME/calls.log"
fmw task spawn task-a --scout --harness pi >/dev/null 2>&1
fmw task spawn task-b --scout --harness pi >/dev/null 2>&1
calls="$(cat "$FMW_FIRSTMATE_HOME/calls.log" 2>/dev/null)"
echo "$calls" | grep -q "fm-spawn.sh task-a /mnt/c/FirstmateWorktrees/TestLab/repo-a --scout --harness pi" \
  && t_ok "spawn task-a -> repo-a" || t_fail "spawn task-a wrong: $calls"
echo "$calls" | grep -q "fm-spawn.sh task-b /mnt/c/FirstmateWorktrees/TestLab/repo-b --scout --harness pi" \
  && t_ok "spawn task-b -> repo-b" || t_fail "spawn task-b wrong: $calls"

fmw_conf_load "$FMW_TASKS_DIR/task-a.conf" "${FMW_TASK_CONF_KEYS[@]}"
t_assert_eq "$STATE" "spawned" "task-a spawned"
t_assert_eq "$FIRSTMATE_ENDPOINT" "fm-task-a" "task-a endpoint"
fmw_conf_load "$FMW_TASKS_DIR/task-b.conf" "${FMW_TASK_CONF_KEYS[@]}"
t_assert_eq "$STATE" "spawned" "task-b spawned"
t_assert_eq "$FIRSTMATE_ENDPOINT" "fm-task-b" "task-b endpoint"

t_begin "multirepo: no metadata cross-contamination"

# each task's metadata must never reference the other task's id
grep -c "task-b" "$FMW_TASKS_DIR/task-a.conf" 2>/dev/null | grep -q "^0$" \
  && t_ok "task-a conf clean" || t_fail "task-a conf references task-b"
grep -c "task-a" "$FMW_TASKS_DIR/task-b.conf" 2>/dev/null | grep -q "^0$" \
  && t_ok "task-b conf clean" || t_fail "task-b conf references task-a"
grep -c "task-b" "$FMW_FIRSTMATE_HOME/state/task-a.meta" 2>/dev/null | grep -q "^0$" \
  && t_ok "task-a meta clean" || t_fail "task-a meta references task-b"
grep -c "task-a" "$FMW_FIRSTMATE_HOME/state/task-b.meta" 2>/dev/null | grep -q "^0$" \
  && t_ok "task-b meta clean" || t_fail "task-b meta references task-a"

t_begin "multirepo: per-project reconciliation and eligibility"

printf 'state: done · source: status-log · ProjA report\n' > "$FMW_FIRSTMATE_HOME/fake-answers/task-a"
printf 'state: done · source: status-log · ProjB report\n' > "$FMW_FIRSTMATE_HOME/fake-answers/task-b"
mkdir -p "$FMW_FIRSTMATE_HOME/data/task-a" "$FMW_FIRSTMATE_HOME/data/task-b"
printf 'report A\n' > "$FMW_FIRSTMATE_HOME/data/task-a/report.md"
printf 'report B\n' > "$FMW_FIRSTMATE_HOME/data/task-b/report.md"

fmw task status task-a >/dev/null 2>&1
fmw task status task-b >/dev/null 2>&1
fmw_conf_load "$FMW_TASKS_DIR/task-a.conf" "${FMW_TASK_CONF_KEYS[@]}"
t_assert_eq "$STATE" "done" "task-a reconciled to done"
fmw_conf_load "$FMW_TASKS_DIR/task-b.conf" "${FMW_TASK_CONF_KEYS[@]}"
t_assert_eq "$STATE" "done" "task-b reconciled to done"

out_a=$(fmw task status task-a 2>&1)
out_b=$(fmw task status task-b 2>&1)
echo "$out_a" | grep -q "^PROJECT_NAME=ProjA$" && t_ok "status task-a shows ProjA" || t_fail "status task-a project"
echo "$out_b" | grep -q "^PROJECT_NAME=ProjB$" && t_ok "status task-b shows ProjB" || t_fail "status task-b project"
echo "$out_a" | grep -q "ProjB report" && t_fail "status task-a leaks ProjB" || t_ok "status task-a clean"
echo "$out_b" | grep -q "ProjA report" && t_fail "status task-b leaks ProjA" || t_ok "status task-b clean"

t_begin "multirepo: independent teardown"

fmw task teardown task-a >/dev/null 2>&1 && t_ok "teardown task-a OK" || t_fail "teardown task-a failed"
t_assert_false test -d "$FMW_TESTLAB/wt-a/task-a" # task-a worktree removed
t_assert_true  test -d "$FMW_TESTLAB/wt-b/task-b" # task-b worktree untouched
git -C "$FMW_TESTLAB/repo-a" rev-parse --verify refs/heads/firstmate/task-a >/dev/null 2>&1 \
  && t_ok "branch task-a kept" || t_fail "branch task-a deleted"

fmw task teardown task-b >/dev/null 2>&1 && t_ok "teardown task-b OK" || t_fail "teardown task-b failed"
t_assert_false test -d "$FMW_TESTLAB/wt-b/task-b" # task-b worktree removed

# both main checkouts stay clean
[ -z "$(git -C "$FMW_TESTLAB/repo-a" status --porcelain)" ] \
  && t_ok "repo-a main checkout clean" || t_fail "repo-a dirty"
[ -z "$(git -C "$FMW_TESTLAB/repo-b" status --porcelain)" ] \
  && t_ok "repo-b main checkout clean" || t_fail "repo-b dirty"

t_summary
