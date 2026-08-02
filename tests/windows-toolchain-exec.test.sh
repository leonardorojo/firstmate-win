# tests/windows-toolchain-exec.test.sh — portable Windows tool execution
. "$(dirname "$0")/harness.sh"

fmw_test_setup_sandbox

CWD="$FMW_TESTLAB/Windows Project with spaces"
FAKE_BIN="$FMW_TESTLAB/fake Windows bin"
FAKE_DOTNET="$FAKE_BIN/dotnet.exe"
FAKE_MSBUILD="$FAKE_BIN/MS Build.exe"
FAKE_PS="$FAKE_BIN/powershell.exe"
RUN_LOG="$FMW_TESTLAB/tool-run.log"
mkdir -p "$CWD" "$FAKE_BIN"

cat > "$FAKE_DOTNET" <<'EOF'
#!/bin/sh
printf 'cwd=%s\n' "$PWD" >> "${RUN_LOG:?}"
printf 'arg-count=%s\n' "$#" >> "${RUN_LOG:?}"
for arg in "$@"; do printf 'arg=<%s>\n' "$arg" >> "${RUN_LOG:?}"; done
case " ${*:-} " in
  *' --stderr '*) printf 'fake-stderr\n' >&2 ;;
esac
case " ${*:-} " in
  *' --exit1 '*) exit 1 ;;
  *' --exit7 '*) exit 7 ;;
esac
printf 'fake-stdout\n'
EOF
cat > "$FAKE_MSBUILD" <<'EOF'
#!/bin/sh
printf 'msbuild-stdout\n'
EOF
cat > "$FAKE_PS" <<'EOF'
#!/bin/sh
printf 'powershell-args=%s\n' "$#" >> "${RUN_LOG:?}"
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-Command" ]; then shift; printf 'powershell-script=%s\n' "$1" >> "${RUN_LOG:?}"; break; fi
  shift
done
printf 'powershell-stdout\n'
grep -q -- '--exit7' "$RUN_LOG" && { printf 'powershell-stderr\n' >&2; exit 7; }
EOF
chmod +x "$FAKE_DOTNET" "$FAKE_MSBUILD" "$FAKE_PS"
export RUN_LOG PATH="$FAKE_BIN:$PATH"

run_cli() {
  local -a options=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --report) options+=(--report); shift ;;
      --backend) options+=(--backend "$2"); shift 2 ;;
      --) shift; break ;;
      *) return 2 ;;
    esac
  done
  fmw win exec --cwd "$CWD" --windows-dotnet "$FAKE_DOTNET" "${options[@]}" -- dotnet.exe "$@"
}

# 1-4: cwd validation and conversion.
t_begin "win exec: cwd and executable resolution"
t_assert_true fmw_win_validate_cwd "$CWD"
t_assert_eq "$FMW_WIN_CWD_WSL" "$CWD" "valid WSL cwd accepted"
t_assert_eq "$FMW_WIN_CWD_WINDOWS" "C:\\FirstmateWorktrees\\TestLab\\Windows Project with spaces" "cwd converted with wslpath"
t_assert_false fmw_win_validate_cwd "$FMW_TESTLAB/does-not-exist"
t_assert_false fmw_win_validate_cwd "/home/leo"
fmw_config_resolve --windows-dotnet "$FAKE_DOTNET"; t_assert_eq "$(fmw_win_resolve_executable dotnet.exe)" "$FAKE_DOTNET" "dotnet.exe resolved from portable config"
t_assert_eq "$(fmw_win_resolve_executable "$FAKE_DOTNET")" "$FAKE_DOTNET" "absolute WSL executable accepted"
win_dotnet="$(wslpath -w "$FAKE_DOTNET")"
out="$(fmw win exec --cwd "$CWD" -- "$win_dotnet" --version)"; rc=$?
t_assert_eq "$rc" 0 "absolute Windows executable accepted"
t_assert_eq "$out" "fake-stdout" "absolute Windows executable runs"
if fmw win exec --cwd "$CWD" -- "$FAKE_BIN/missing.exe" >/dev/null 2>&1; then
  t_fail "missing executable unexpectedly ran"
else
  t_ok "missing executable is reported"
fi

# 5-12: argument preservation and separated output.
t_begin "win exec: arguments, stdout, stderr, and exit codes"
rm -f "$RUN_LOG"
out="$(run_cli -- 'first arg' '' 'quoted "value"' '-leading' '$(touch /tmp/fmw-win-exec-no-eval)' 2>"$FMW_TESTLAB/err")"; rc=$?
t_assert_eq "$rc" 0 "exit code 0 preserved"
t_assert_eq "$out" "fake-stdout" "stdout preserved"
t_assert_eq "$(cat "$FMW_TESTLAB/err")" "" "stderr remains separate when empty"
grep -q 'arg=<first arg>' "$RUN_LOG" && t_ok "argument with spaces preserved" || t_fail "argument with spaces lost"
grep -q 'arg=<>' "$RUN_LOG" && t_ok "empty argument preserved" || t_fail "empty argument lost"
grep -q 'arg=<quoted "value">' "$RUN_LOG" && t_ok "quotes preserved as data" || t_fail "quotes were reinterpreted"
grep -q 'arg=<-leading>' "$RUN_LOG" && t_ok "leading dash preserved" || t_fail "leading dash was parsed"
[ ! -e /tmp/fmw-win-exec-no-eval ] && t_ok "no eval or command substitution" || t_fail "argument was evaluated"
if grep -Eq '^[[:space:]]*eval[[:space:]]' "$FMW_HOME/lib/windows.sh"; then t_fail "Windows executor contains eval"; else t_ok "Windows executor contains no eval"; fi
out="$(run_cli -- --stderr 2>"$FMW_TESTLAB/err")"; rc=$?
t_assert_eq "$rc" 0 "stderr-producing command exits zero"
t_assert_eq "$(cat "$FMW_TESTLAB/err")" "fake-stderr" "stderr preserved separately"
if run_cli -- --exit1 >/dev/null 2>&1; then t_fail "exit code 1 was swallowed"; else t_assert_eq "$?" 1 "exit code 1 propagated"; fi
if run_cli -- --exit7 >/dev/null 2>&1; then t_fail "exit code 7 was swallowed"; else t_assert_eq "$?" 7 "other exit code propagated"; fi

# 13-18: report, backend selection, and optional MSBuild.
t_begin "win exec: report and backend selection"
report="$(run_cli --report -- --version 2>"$FMW_TESTLAB/report")"; rc=$?
t_assert_eq "$rc" 0 "report mode preserves child exit"
t_assert_eq "$report" "fake-stdout" "report does not pollute stdout"
grep -q 'cwd-wsl=' "$FMW_TESTLAB/report" && t_ok "report includes WSL cwd" || t_fail "report missing WSL cwd"
grep -q 'cwd-windows=' "$FMW_TESTLAB/report" && t_ok "report includes Windows cwd" || t_fail "report missing Windows cwd"
grep -q 'backend=direct' "$FMW_TESTLAB/report" && t_ok "report identifies direct backend" || t_fail "report missing backend"
if fmw_win_resolve_executable msbuild.exe >/dev/null 2>&1; then t_fail "missing MSBuild resolved unexpectedly"; else t_ok "MSBuild remains optional when absent"; fi
fmw_config_resolve --windows-msbuild "$FAKE_MSBUILD"
t_assert_eq "$(fmw_win_resolve_executable MSBuild.exe)" "$FAKE_MSBUILD" "MSBuild configured path with spaces resolves"
out="$(fmw win exec --cwd "$CWD" --windows-msbuild "$FAKE_MSBUILD" -- MSBuild.exe)"; rc=$?
t_assert_eq "$rc" 0 "configured MSBuild executes"
t_assert_eq "$out" "msbuild-stdout" "configured MSBuild stdout preserved"

# 19-24: explicit PowerShell backend and compatibility.
t_begin "win exec: explicit PowerShell backend"
rm -f "$RUN_LOG"
out="$(run_cli --backend powershell -- --exit7 2>"$FMW_TESTLAB/ps-err")"; rc=$?
t_assert_eq "$rc" 7 "PowerShell backend propagates child result"
t_assert_eq "$out" "powershell-stdout" "PowerShell stdout preserved"
t_assert_eq "$(cat "$FMW_TESTLAB/ps-err")" "powershell-stderr" "PowerShell stderr preserved"
grep -Fq "Set-Location -LiteralPath 'C:\\FirstmateWorktrees\\TestLab\\Windows Project with spaces'" "$RUN_LOG" && t_ok "PowerShell receives converted cwd" || t_fail "PowerShell cwd conversion missing"
grep -q "'--exit7'" "$RUN_LOG" && t_ok "PowerShell receives quoted argument array" || t_fail "PowerShell argument quoting missing"
old_pwd="$PWD"
run_cli -- --version >/dev/null 2>&1
t_assert_eq "$PWD" "$old_pwd" "caller cwd is unchanged"
# Existing Windows helpers remain available without invoking a real tool.
type fmw_exec_powershell >/dev/null && t_ok "existing PowerShell helper remains available" || t_fail "PowerShell helper missing"
type fmw_exec_cmd >/dev/null && t_ok "existing CMD helper remains available" || t_fail "CMD helper missing"

t_summary
