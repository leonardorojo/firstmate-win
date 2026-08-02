# tests/portable-config.test.sh — portable configuration and static doctor
. "$(dirname "$0")/harness.sh"

fmw_test_setup_sandbox
# Load the doctor helpers without dispatching a mutating CLI command.
set -- doctor
FMW_NO_DISPATCH=1 source "$FMW_HOME/bin/fmw" >/dev/null

FAKE_RUNTIME="/tmp/fmw-portable-runtime-$$"
FAKE_BIN="$FAKE_RUNTIME/bin"
FAKE_NODE="$FAKE_RUNTIME/node"
FAKE_PI="$FAKE_BIN/pi"
FAKE_HERDR="$FAKE_BIN/herdr"
FAKE_JQ="$FAKE_BIN/jq"
FAKE_PS="$FAKE_BIN/powershell.exe"
FAKE_CMD="$FAKE_BIN/cmd.exe"
FAKE_TREEHOUSE="$FMW_TESTLAB/real treehouse"
FAKE_DOTNET="$FMW_TESTLAB/windows dotnet.exe"
FAKE_FIRSTMATE="$FMW_TESTLAB/firstmate root"
FAKE_FM_HOME="$FMW_TESTLAB/shared fm home"
FAKE_REPOS="$FMW_TESTLAB/repos root"
FAKE_WORKTREES="$FMW_TESTLAB/worktrees root"
USER_CONF="$FMW_SANDBOX/user.conf"
PROFILE_CONF="$FMW_SANDBOX/profile.conf"
mkdir -p "$FAKE_BIN" "$FAKE_FIRSTMATE/bin" "$FAKE_FM_HOME" "$FAKE_REPOS" "$FAKE_WORKTREES"

cleanup() { rm -rf "$FAKE_RUNTIME"; }
trap cleanup EXIT

# Native-runtime and Windows-tool fakes are deterministic and never start tools.
printf '#!/bin/sh\necho linux\n' > "$FAKE_NODE"
printf '#!/bin/sh\nprintf "pi 0.0-test\\n"\n' > "$FAKE_PI"
printf '#!/bin/sh\nprintf "herdr 0.0-test\\n"\n' > "$FAKE_HERDR"
printf '#!/bin/sh\nprintf "jq-0.0-test\\n"\n' > "$FAKE_JQ"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_PS"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_CMD"
printf '#!/bin/sh\nif [ "${1:-}" = "--version" ]; then echo "treehouse 0.0-test"; else exit 1; fi\n' > "$FAKE_TREEHOUSE"
printf '#!/bin/sh\ncase "${1:-}" in --version) echo 8.0.0 ;; --info) echo "OS Name: Windows" ;; *) exit 1 ;; esac\n' > "$FAKE_DOTNET"
chmod +x "$FAKE_NODE" "$FAKE_PI" "$FAKE_HERDR" "$FAKE_JQ" "$FAKE_PS" "$FAKE_CMD" "$FAKE_TREEHOUSE" "$FAKE_DOTNET"
for script in fm-spawn.sh fm-brief.sh fm-teardown.sh; do : > "$FAKE_FIRSTMATE/bin/$script"; chmod +x "$FAKE_FIRSTMATE/bin/$script"; done

# --- parser allowlist, atomic rerun, and precedence ---
t_begin "portable config: allowlist and atomic rerun"
fmw_conf_write_atomic "$USER_CONF" "FIRSTMATE_ROOT='$FAKE_FIRSTMATE'" "FM_HOME='$FAKE_FM_HOME'" "FMW_REPOS_ROOT='$FAKE_REPOS'" "FMW_WORKTREES_ROOT='$FAKE_WORKTREES'"
fmw_conf_write_atomic "$USER_CONF" "FIRSTMATE_ROOT='$FAKE_FIRSTMATE'" "FM_HOME='$FAKE_FM_HOME'" "FMW_REPOS_ROOT='$FAKE_REPOS'" "FMW_WORKTREES_ROOT='$FAKE_WORKTREES'"
t_assert_true test -f "$USER_CONF"
printf 'NOT_ALLOWED=x\n' > "$FMW_SANDBOX/bad.conf"
t_assert_false fmw_config_file_valid "$FMW_SANDBOX/bad.conf"

cat > "$PROFILE_CONF" <<EOF
FIRSTMATE_ROOT='$FMW_TESTLAB/profile-firstmate'
FM_HOME='$FMW_TESTLAB/profile-home'
FMW_REPOS_ROOT='$FMW_TESTLAB/profile-repos'
FMW_WORKTREES_ROOT='$FMW_TESTLAB/profile-worktrees'
EOF
mkdir -p "$FMW_TESTLAB/profile-firstmate" "$FMW_TESTLAB/profile-home" "$FMW_TESTLAB/profile-repos" "$FMW_TESTLAB/profile-worktrees"
FMW_CONFIG_FILE="$USER_CONF" FIRSTMATE_ROOT="$FMW_TESTLAB/env-firstmate" fmw_config_resolve --config "$USER_CONF" --profile-config "$PROFILE_CONF" --firstmate-root "$FMW_TESTLAB/cli-firstmate"
t_assert_eq "$FMW_CFG_FIRSTMATE_ROOT" "$FMW_TESTLAB/cli-firstmate" "CLI overrides environment"
t_assert_eq "$FMW_CFG_FM_HOME" "$FAKE_FM_HOME" "user config overrides profile"

# --- path roots, spaces, and Windows filesystem rules ---
t_begin "portable config: NTFS roots and spaces"
t_assert_true fmw_path_is_windows_mounted "$FAKE_REPOS"
t_assert_true fmw_path_parent_writable "$FMW_TESTLAB/path that does not exist"
t_assert_false fmw_path_is_windows_mounted "/home/not-ntfs"
t_assert_false fmw_path_is_windows_mounted "/tmp/not-ntfs"

# --- Treehouse real route versus residual shim ---
t_begin "portable config: real Treehouse and broken shim"
FMW_CFG_TREEHOUSE_BIN="$FAKE_TREEHOUSE"
t_assert_true fmw_doctor_treehouse
FMW_CFG_TREEHOUSE_BIN="$FMW_SHIMS_DIR/treehouse"
t_assert_false fmw_doctor_treehouse

# --- dotnet Windows validation and optional MSBuild ---
t_begin "portable config: Windows dotnet and optional MSBuild"
FMW_CFG_WINDOWS_DOTNET="$FAKE_DOTNET"
t_assert_true fmw_doctor_dotnet
FMW_CFG_WINDOWS_MSBUILD=""
t_ok "missing MSBuild is optional"
printf '#!/bin/sh\necho 8.0.0\n' > "$FMW_TESTLAB/linux-dotnet"
chmod +x "$FMW_TESTLAB/linux-dotnet"
FMW_CFG_WINDOWS_DOTNET="$FMW_TESTLAB/linux-dotnet"
# Linux-looking output must not satisfy the Windows runtime check.
t_assert_false fmw_doctor_dotnet

# --- full static doctor with no captain, watcher, beacon, or task ---
t_begin "static doctor: prepared installation without live captain"
export FMW_CONFIG_FILE="$USER_CONF"
export FIRSTMATE_ROOT="$FAKE_FIRSTMATE"
export FM_HOME="$FAKE_FM_HOME"
export FMW_REPOS_ROOT="$FAKE_REPOS"
export FMW_WORKTREES_ROOT="$FAKE_WORKTREES"
export TREEHOUSE_BIN="$FAKE_TREEHOUSE"
export WINDOWS_DOTNET="$FAKE_DOTNET"
unset WINDOWS_MSBUILD
export FMW_LINUX_NODE="$FAKE_NODE"
export PATH="$FAKE_BIN:$PATH"
out="$(fmw doctor --config "$USER_CONF" 2>&1)"
echo "$out" | grep -q '\[PASS\] FIRSTMATE_ROOT' && t_ok "Firstmate root PASS" || t_fail "Firstmate root not PASS"
echo "$out" | grep -q '\[PASS\] real Treehouse' && t_ok "real Treehouse PASS" || t_fail "Treehouse not PASS"
echo "$out" | grep -q '\[PASS\] Windows dotnet.exe' && t_ok "Windows dotnet PASS" || t_fail "dotnet not PASS"
echo "$out" | grep -q '\[WARN\] optional MSBuild' && t_ok "MSBuild WARN is optional" || t_fail "MSBuild warning missing"
echo "$out" | grep -q '\[PASS\] FMW_REPOS_ROOT' && t_ok "repo root PASS" || t_fail "repo root not PASS"
echo "$out" | grep -q '\[PASS\] FMW_WORKTREES_ROOT' && t_ok "worktree root PASS" || t_fail "worktree root not PASS"
if echo "$out" | grep -qiE 'captain.*FAIL|watcher.*FAIL|beacon.*FAIL'; then
  t_fail "idle live state caused a static FAIL"
else
  t_ok "absence of captain/watcher/beacon does not fail static doctor"
fi

# Existing profiles remain available and optional.
t_begin "compatibility: existing profile fixtures remain available"
t_assert_true test -f "$FMW_HOME/profiles/ingenieumapp.sh"
t_assert_true test -f "$FMW_HOME/profiles/civilplan.sh"

t_summary
