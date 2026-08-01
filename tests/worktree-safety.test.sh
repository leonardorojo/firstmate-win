# tests/worktree-safety.test.sh — fail-closed worktree lifecycle
. "$(dirname "$0")/harness.sh"

fmw_test_setup_sandbox
fmw_test_make_repo "$FMW_TESTLAB/repo"
fmw_test_make_profile "wtproj"

WTROOT="$FMW_TESTLAB/wt-root2"
mkdir -p "$WTROOT"

fmw project add --name WtProj \
  --windows-path "C:\\FirstmateWorktrees\\TestLab\\repo" \
  --worktree-root "C:\\FirstmateWorktrees\\TestLab\\wt-root2" \
  --profile wtproj >/dev/null 2>&1 \
  || { echo "   FATAL: could not register WtProj"; exit 1; }

t_begin "task: prepare"

prep_out=$(fmw task prepare --project WtProj --id alpha-audit 2>&1) \
  || { t_fail "prepare failed: $prep_out"; }
echo "$prep_out" | grep -q "branch=firstmate/alpha-audit" && t_ok "branch firstmate/alpha-audit" || t_fail "wrong branch: $prep_out"
echo "$prep_out" | grep -q "wsl_path=$WTROOT/alpha-audit" && t_ok "correct wsl_path" || t_fail "wrong wsl_path: $prep_out"
t_assert_file "$FMW_TASKS_DIR/alpha-audit.conf" "task metadata created"
t_assert_true test -d "$WTROOT/alpha-audit"

# git registers it with the expected branch
t_assert_true fmw_safety_worktree_registered "$FMW_TESTLAB/repo" "$WTROOT/alpha-audit" "firstmate/alpha-audit"

# correct conf
if fmw_conf_load "$FMW_TASKS_DIR/alpha-audit.conf" "${FMW_TASK_CONF_KEYS[@]}"; then
  t_assert_eq "$TASK_ID" "alpha-audit"             "TASK_ID"
  t_assert_eq "$PROJECT_NAME" "WtProj"             "PROJECT_NAME"
  t_assert_eq "$STATE" "prepared"                  "STATE=prepared"
  t_assert_eq "$WORKTREE_WSL_PATH" "$WTROOT/alpha-audit" "WORKTREE_WSL_PATH"
  t_assert_eq "$WORKTREE_WINDOWS_PATH" "C:\\FirstmateWorktrees\\TestLab\\wt-root2\\alpha-audit" "WORKTREE_WINDOWS_PATH"
  t_assert_eq "$BRANCH" "firstmate/alpha-audit"    "BRANCH"
else
  t_fail "could not reload the task conf"
fi

t_begin "task: prepare — collisions and validations"

t_assert_false fmw task prepare --project WtProj --id alpha-audit          # duplicate task id
t_assert_false fmw task prepare --project WtProj --id "BAD ID"             # invalid id (space)
t_assert_false fmw task prepare --project WtProj --id "../../escape"       # malicious id
t_assert_false fmw task prepare --project NoExiste --id task-ok            # nonexistent project

# existing branch -> collision
git -C "$FMW_TESTLAB/repo" branch taken-branch >/dev/null 2>&1
t_assert_false fmw task prepare --project WtProj --id beta-branch --branch taken-branch

t_begin "task: show / list / status"

show_out=$(fmw task show alpha-audit 2>&1)
echo "$show_out" | grep -q "STATE=prepared" && t_ok "show: STATE" || t_fail "show does not print STATE"
echo "$show_out" | grep -q "git_branch=firstmate/alpha-audit" && t_ok "show: git_branch" || t_fail "show does not print git_branch"

list_out=$(fmw task list 2>&1)
echo "$list_out" | grep -q "alpha-audit" && t_ok "list contains alpha-audit" || t_fail "list does not contain alpha-audit"

status_out=$(fmw task status alpha-audit 2>&1)
echo "$status_out" | grep -q "fm_meta=missing" && t_ok "status: no firstmate meta (yet)" || t_fail "unexpected status meta"

t_begin "task: fail-closed teardown"

# teardown of a nonexistent task -> rejection
t_assert_false fmw task teardown ghost-task

# dirty worktree -> rejection without --force
printf 'local change\n' > "$WTROOT/alpha-audit/base.txt"
t_assert_false fmw task teardown alpha-audit
t_assert_true test -d "$WTROOT/alpha-audit"

# active agent (tmux window fm-<id>) -> rejection
if command -v tmux >/dev/null 2>&1; then
  tmux new-session -d -s fmw-testsess -n fm-alpha-audit 2>/dev/null
  t_assert_false fmw task teardown alpha-audit
  t_assert_true test -d "$WTROOT/alpha-audit"
  tmux kill-session -t fmw-testsess 2>/dev/null || true
fi

# clean teardown (after reverting the change) -> OK, branch kept.
# The task is still prepared; teardown now requires an explicit terminal
# state, so the orphaned-task transition (abandon) must come first.
git -C "$WTROOT/alpha-audit" checkout -- base.txt 2>/dev/null
ab_out=$(fmw task abandon alpha-audit --reason "test" 2>&1) && t_ok "abandon (explicit transition) OK" || t_fail "abandon failed: $ab_out"
td_out=$(fmw task teardown alpha-audit 2>&1) && t_ok "clean teardown OK" || t_fail "clean teardown failed: $td_out"
echo "$td_out" | grep -q "branch kept" && t_ok "reports branch kept" || t_fail "does not report the branch"
t_assert_false test -d "$WTROOT/alpha-audit" "worktree removed"
t_assert_file "$FMW_ARCHIVE_DIR/alpha-audit.conf" "metadata archived (ownership preserved)"
t_assert_false test -f "$FMW_TASKS_DIR/alpha-audit.conf" "task out of active tasks"

# the branch still exists (branches are never deleted without authorization)
git -C "$FMW_TESTLAB/repo" rev-parse --verify refs/heads/firstmate/alpha-audit >/dev/null 2>&1 \
  && t_ok "branch firstmate/alpha-audit kept" || t_fail "branch deleted (should not)"

# teardown of an already torn-down task -> rejection
t_assert_false fmw task teardown alpha-audit

t_begin "task: teardown with --force (explicit authorization)"

fmw task prepare --project WtProj --id gamma-dirty >/dev/null 2>&1 || t_fail "prepare gamma-dirty"
printf 'dirty\n' > "$WTROOT/gamma-dirty/base.txt"
force_out=$(fmw task teardown gamma-dirty --force 2>&1) && t_ok "teardown --force OK" || t_fail "teardown --force failed: $force_out"
t_assert_false test -d "$WTROOT/gamma-dirty" "worktree removed with --force"

t_begin "task: prepare/teardown do not touch the main checkout"

if [ -z "$(git -C "$FMW_TESTLAB/repo" status --porcelain)" ]; then
  t_ok "main checkout clean"
else
  t_fail "main checkout dirty: $(git -C "$FMW_TESTLAB/repo" status --porcelain)"
fi

t_summary
