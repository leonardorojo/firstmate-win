# tests/project-registry.test.sh — project registry + config parser
. "$(dirname "$0")/harness.sh"

fmw_test_setup_sandbox
fmw_test_make_repo "$FMW_TESTLAB/repo"
fmw_test_make_profile "testproj"

t_begin "config: parser allowlist"

fmw_conf_write_atomic "$FMW_SANDBOX/ok.conf" "A='1'" "B='hello world'" "C='x'"
t_assert_file "$FMW_SANDBOX/ok.conf" "atomic write creates the file"

# valid load
A="" B=""
if fmw_conf_load "$FMW_SANDBOX/ok.conf" A B C; then
  t_assert_eq "$A" "1"          "loads key A"
  t_assert_eq "$B" "hello world" "loads key B with spaces"
else
  t_fail "fmw_conf_load should accept allowlist keys"
fi

# key outside the allowlist -> rejection
printf 'BAD='\''x'\''\n' > "$FMW_SANDBOX/mal.conf"
t_assert_false fmw_conf_load "$FMW_SANDBOX/mal.conf" A B

# invalid line -> rejection
printf 'this is not a conf\n' > "$FMW_SANDBOX/mal2.conf"
t_assert_false fmw_conf_load "$FMW_SANDBOX/mal2.conf" A B

# missing file -> rejection
t_assert_false fmw_conf_load "$FMW_SANDBOX/nope.conf" A B

t_begin "project: add"

mkdir -p "$FMW_TESTLAB/wt-root"
out=$(fmw project add --name TestProj --windows-path "C:\\FirstmateWorktrees\\TestLab\\repo" --worktree-root "C:\\FirstmateWorktrees\\TestLab\\wt-root" --profile testproj 2>&1) || { t_fail "project add failed: $out"; }
t_assert_file "$FMW_PROJECTS_DIR/TestProj.conf" "project conf created"

if fmw_conf_load "$FMW_PROJECTS_DIR/TestProj.conf" "${FMW_PROJECT_CONF_KEYS[@]}"; then
  t_assert_eq "$PROJECT_WSL_PATH"                "/mnt/c/FirstmateWorktrees/TestLab/repo"    "PROJECT_WSL_PATH"
  t_assert_eq "$PROJECT_WINDOWS_PATH"            "C:\\FirstmateWorktrees\\TestLab\\repo"     "PROJECT_WINDOWS_PATH"
  t_assert_eq "$PROJECT_WORKTREE_WSL_ROOT"       "/mnt/c/FirstmateWorktrees/TestLab/wt-root" "PROJECT_WORKTREE_WSL_ROOT"
  t_assert_eq "$PROJECT_WORKTREE_WINDOWS_ROOT"   "C:\\FirstmateWorktrees\\TestLab\\wt-root"  "PROJECT_WORKTREE_WINDOWS_ROOT"
  t_assert_eq "$PROJECT_PROFILE"                 "testproj"                                   "PROJECT_PROFILE"
else
  t_fail "could not reload the project conf"
fi

# duplicate registration -> rejection
t_assert_false fmw project add --name TestProj --windows-path "C:\\FirstmateWorktrees\\TestLab\\repo" --worktree-root "C:\\FirstmateWorktrees\\TestLab\\wt-root" --profile testproj

# invalid name -> rejection
t_assert_false fmw project add --name "Bad Name" --windows-path "C:\\x" --worktree-root "C:\\y" --profile testproj
t_assert_false fmw project add --name "bad/name" --windows-path "C:\\x" --worktree-root "C:\\y" --profile testproj

# nonexistent repo -> rejection
t_assert_false fmw project add --name NoRepo --windows-path "C:\\FirstmateWorktrees\\TestLab\\nope" --worktree-root "C:\\FirstmateWorktrees\\TestLab\\wt-root" --profile testproj

# worktree root on the native WSL filesystem -> rejection
t_assert_false fmw project add --name BadRoot --windows-path "C:\\FirstmateWorktrees\\TestLab\\repo" --worktree-root "C:\\tmp\\wt" --profile testproj

t_begin "project: list / show / validate"

t_assert_true fmw project list
list_out=$(fmw project list)
echo "$list_out" | grep -q TestProj && t_ok "list contains TestProj" || t_fail "list does not contain TestProj"

show_out=$(fmw project show TestProj 2>&1)
echo "$show_out" | grep -q "PROJECT_WSL_PATH=/mnt/c/FirstmateWorktrees/TestLab/repo" && t_ok "show prints paths" || t_fail "show does not print paths"

validate_out=$(fmw project validate TestProj 2>&1) && t_ok "project validate OK" || { t_fail "project validate failed: $validate_out"; }
echo "$validate_out" | grep -q "PowerShell interop" && t_ok "validate reports interop (SKIP in tests)" || t_fail "validate does not report interop"

t_begin "project: resolve by path"

t_assert_eq "$(fmw_project_resolve TestProj)" "TestProj" "resolve by name"
t_assert_eq "$(fmw_project_resolve /mnt/c/FirstmateWorktrees/TestLab/repo)" "TestProj" "resolve by repo path"
t_assert_eq "$(fmw_project_resolve /mnt/c/FirstmateWorktrees/TestLab/wt-root/task1)" "TestProj" "resolve by worktree path"

t_summary
