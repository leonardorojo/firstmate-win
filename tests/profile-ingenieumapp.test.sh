# tests/profile-ingenieumapp.test.sh — IngenieumApp profile integration
#   Verifies that fmw_profile_build reproduces EXACTLY the official flow of
#   the repo README (nuget restore + dotnet build -c Debug -p:Platform="Any CPU")
#   with Windows tools (stub .exe that record the invocation),
#   and the ladder without nuget.exe (packages/ present -> skip; clean -> error).
#
#   It does NOT compile the real repo: it validates the profile contract.

. "$(dirname "$0")/harness.sh"

fmw_test_setup_sandbox
fmw_test_make_repo "$FMW_TESTLAB/repo"

# --- Windows tool stubs (bash scripts with .exe suffix) -------------------
FAKETOOLS="$FMW_TESTLAB/fake-tools"
export FAKETOOLS   # the stubs (subshells) write their log with this variable
mkdir -p "$FAKETOOLS"
cat > "$FAKETOOLS/dotnet.exe" <<EOF
#!/usr/bin/env bash
echo "dotnet \$*" >> "$FAKETOOLS/calls.log"
[ "\${FAKE_DOTNET_FAIL:-0}" = 1 ] && exit 3
exit 0
EOF
cat > "$FAKETOOLS/nuget.exe" <<'EOF'
#!/usr/bin/env bash
echo "nuget $*" >> "$FAKETOOLS/calls.log"
exit 0
EOF
cat > "$FAKETOOLS/vstest.console.exe" <<'EOF'
#!/usr/bin/env bash
echo "vstest $*" >> "$FAKETOOLS/calls.log"
exit 0
EOF
chmod +x "$FAKETOOLS"/*

# --- context equivalent to fmw_profile_load -------------------------------
FMW_PROJECT_WSL_PATH="$FMW_TESTLAB/repo"
FMW_PROJECT_WINDOWS_PATH="C:\\FirstmateWorktrees\\TestLab\\repo"
FMW_TASK_ID="prof-test"
FMW_TASK_WORKTREE="$FMW_TESTLAB/wt/prof-test"
FMW_TASK_WORKTREE_WINDOWS="C:\\FirstmateWorktrees\\TestLab\\wt\\prof-test"
export FMW_PROJECT_WSL_PATH FMW_PROJECT_WINDOWS_PATH \
       FMW_TASK_ID FMW_TASK_WORKTREE FMW_TASK_WORKTREE_WINDOWS

# fake repo: sln at the root (validate requirement)
touch "$FMW_TESTLAB/repo/IngenieumApp.sln"
# task worktree: build target dir (no sln or packages: clean)
mkdir -p "$FMW_TESTLAB/wt/prof-test"

INGENIEUMAPP_DOTNET_WIN="$(fmw_path_to_windows "$FAKETOOLS/dotnet.exe")"
INGENIEUMAPP_NUGET_WIN="$(fmw_path_to_windows "$FAKETOOLS/nuget.exe")"
INGENIEUMAPP_VSTEST_WIN="$(fmw_path_to_windows "$FAKETOOLS/vstest.console.exe")"
export INGENIEUMAPP_DOTNET_WIN INGENIEUMAPP_NUGET_WIN INGENIEUMAPP_VSTEST_WIN

# REAL wrapper profile (not the sandbox stub)
. "$FMW_HOME/profiles/ingenieumapp.sh"

t_begin "validate: OK with dotnet.exe and sln present"

fmw_profile_validate && t_ok "validate rc=0" || t_fail "validate failed"

t_begin "build: reproduces the README flow (nuget restore BEFORE dotnet build) over the worktree"

rm -f "$FAKETOOLS/calls.log"
fmw_profile_build && t_ok "build rc=0" || t_fail "build rc=$?"
calls="$(cat "$FAKETOOLS/calls.log" 2>/dev/null)"
grep -Fq "nuget restore C:\\FirstmateWorktrees\\TestLab\\wt\\prof-test\\IngenieumApp.sln" <<<"$calls" \
  && t_ok "nuget restore with the worktree sln" || { echo "$calls"; t_fail "nuget restore wrong"; }
grep -Fq "dotnet build C:\\FirstmateWorktrees\\TestLab\\wt\\prof-test\\IngenieumApp.sln -c Debug -p:Platform=Any CPU" <<<"$calls" \
  && t_ok "dotnet build with -c Debug -p:Platform=\"Any CPU\" (README flow)" || { echo "$calls"; t_fail "dotnet build wrong"; }
n1="$(grep -n "nuget restore" <<<"$calls" | head -1 | cut -d: -f1)"
n2="$(grep -n "dotnet build" <<<"$calls" | head -1 | cut -d: -f1)"
[ -n "$n1" ] && [ -n "$n2" ] && [ "$n1" -lt "$n2" ] \
  && t_ok "restore precedes build" || t_fail "restore/build order reversed"

t_begin "build without nuget.exe but with packages/ already restored: skips restore and compiles"

mkdir -p "$FMW_TESTLAB/wt/prof-test/packages/Some.Pkg"
rm -f "$FAKETOOLS/calls.log"
out="$(INGENIEUMAPP_NUGET_WIN=none fmw_profile_build 2>&1)"
rc=$?
[ "$rc" = 0 ] && t_ok "build rc=0 without nuget" || t_fail "build rc=$rc (out: $out)"
calls="$(cat "$FAKETOOLS/calls.log" 2>/dev/null)"
grep -q "nuget restore" <<<"$calls" && t_fail "should NOT call nuget" || t_ok "did not call nuget"
grep -Fq "dotnet build" <<<"$calls" && t_ok "still ran dotnet build" || t_fail "did not run dotnet build"
echo "$out" | grep -q "restore skipped" && t_ok "restore-skipped notice" || t_fail "missing restore-skipped notice"

t_begin "build without nuget.exe and without packages/ (clean checkout): clear failure"

rm -rf "$FMW_TESTLAB/wt/prof-test/packages"
rm -f "$FAKETOOLS/calls.log"
out="$(INGENIEUMAPP_NUGET_WIN=none fmw_profile_build 2>&1)"
rc=$?
[ "$rc" = 2 ] && t_ok "rc=2 (clean checkout without NuGet CLI)" || t_fail "rc=$rc (expected 2; out: $out)"
echo "$out" | grep -q "clean checkout without nuget.exe" && t_ok "actionable message" || t_fail "message not found: $out"

t_begin "build: the build exit code propagates"

rm -f "$FAKETOOLS/calls.log"
out="$(FAKE_DOTNET_FAIL=1 fmw_profile_build 2>&1)"
rc=$?
[ "$rc" = 3 ] && t_ok "rc=3 propagated from the build" || t_fail "rc=$rc (expected 3)"

t_begin "validate without nuget.exe: rc=0 with a warning (does not block)"

out="$(INGENIEUMAPP_NUGET_WIN=none fmw_profile_validate 2>&1)"
rc=$?
[ "$rc" = 0 ] && t_ok "validate rc=0 without nuget" || t_fail "validate rc=$rc"
echo "$out" | grep -q "warning: nuget.exe not detected" && t_ok "warning emitted" || t_fail "warning not emitted: $out"

t_begin "test: vstest with the real assembly path (net48) when it compiled"

mkdir -p "$FMW_TESTLAB/wt/prof-test/Testing/IA.Testing.NetFramework/bin/Debug/net48"
touch "$FMW_TESTLAB/wt/prof-test/Testing/IA.Testing.NetFramework/bin/Debug/net48/IA.Testing.NetFramework.dll"
rm -f "$FAKETOOLS/calls.log"
fmw_profile_test && t_ok "test rc=0" || t_fail "test rc=$?"
calls="$(cat "$FAKETOOLS/calls.log" 2>/dev/null)"
grep -Fq "vstest C:\\FirstmateWorktrees\\TestLab\\wt\\prof-test\\Testing\\IA.Testing.NetFramework\\bin\\Debug\\net48\\IA.Testing.NetFramework.dll" <<<"$calls" \
  && t_ok "vstest with bin/Debug/net48 path" || { echo "$calls"; t_fail "vstest wrong"; }

t_begin "test without assembly: build OK and notice, rc=0"

rm -rf "$FMW_TESTLAB/wt/prof-test/Testing"
rm -f "$FAKETOOLS/calls.log"
out="$(fmw_profile_test 2>&1)"
rc=$?
[ "$rc" = 0 ] && t_ok "test rc=0 without assembly" || t_fail "test rc=$rc"
echo "$out" | grep -q "no test assembly" && t_ok "missing-assembly notice" || t_fail "notice not emitted: $out"

t_summary
