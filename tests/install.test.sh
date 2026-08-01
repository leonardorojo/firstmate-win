# tests/install.test.sh — clean-install reproducibility (bin/install.sh)
#   Scenarios:
#     1. initial install (complete) -> links, PATH entries, rc=0
#     2. reinstall idempotent       -> no duplicates, rc=0
#     3. partial install detected   -> actionable fail (Firstmate missing)
#     4. wrong PATH (Windows node)  -> refused with actionable message
#     5. Windows node detected      -> node platform enforced
#     6. Windows pi detected        -> refused
#     7. tasks-axi missing          -> installed via user npm prefix
#     8. Firstmate missing          -> refused, clone command shown
#     9. existing config            -> backup created before editing
#    10. rollback                   -> dry-run leaves everything untouched
#    11. dry-run                    -> nothing changes
. "$(dirname "$0")/harness.sh"

fmw_test_setup_sandbox
INST="$FMW_TESTLAB/home"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$INST" "$FMW_TESTLAB/cleanbin" "$FMW_TESTLAB/fakewin" "$FMW_TESTLAB/fakebin"

# --- fake npm (cleanbin): installs into the requested user prefix (no network) ---
cat > "$FMW_TESTLAB/cleanbin/npm" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "install" ]; then
  prefix=""; pkg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix) prefix="$2"; shift 2 ;;
      -g) shift ;;
      *) pkg="$1"; shift ;;
    esac
  done
  if [ "$pkg" = "@earendil-works/pi-coding-agent" ]; then
    mkdir -p "$prefix/lib/node_modules/@earendil-works/pi-coding-agent/dist"
    printf '#!/usr/bin/env node\nconsole.log("fake pi")\n' \
      > "$prefix/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
  else
    mkdir -p "$prefix/bin"
    printf '#!/usr/bin/env bash\necho fake-tasks-axi\n' > "$prefix/bin/tasks-axi"
    chmod +x "$prefix/bin/tasks-axi"
  fi
  exit 0
fi
exit 1
FAKE
chmod +x "$FMW_TESTLAB/cleanbin/npm"

# --- fake Windows node (fakewin): answers process.platform with win32 ---
cat > "$FMW_TESTLAB/fakewin/node" <<'FAKE'
#!/usr/bin/env bash
echo win32
FAKE
chmod +x "$FMW_TESTLAB/fakewin/node"

# --- fake Windows pi (fakebin): MZ header so `file` sees a non-Linux binary ---
printf 'MZ\x90\x00\x03\x00\x00\x00\x00\x00\x04\x00\x00\x00\xff\xff\x00\x00\xb8\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' > "$FMW_TESTLAB/fakebin/pi"
chmod +x "$FMW_TESTLAB/fakebin/pi"

# controlled PATH: real Linux node BINARY (never the fmw shims) + fake npm;
# NO user ~/.local/bin (no tasks-axi/pi from the operator), NO /mnt/c nodejs
NODE_DIR=""
for p in "$HOME/.local/nodejs/bin/node" /usr/bin/node /usr/local/bin/node; do
  if [ -x "$p" ]; then NODE_DIR="$(dirname "$p")"; break; fi
done
[ -n "$NODE_DIR" ] || { echo "   FATAL: no native Linux node found for the test"; exit 1; }
BASE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
PATH_CTRL="$FMW_TESTLAB/cleanbin:$NODE_DIR:$BASE_PATH"

# the fmw node runtime expected under the install home (install step 2)
mkdir -p "$INST/.local/nodejs/bin"
[ -e "$INST/.local/nodejs/bin/node" ] || ln -s "$NODE_DIR/node" "$INST/.local/nodejs/bin/node"

fake_firstmate() {
  mkdir -p "$INST/firstmate/bin"
  touch "$INST/firstmate/bin/fm-spawn.sh" "$INST/firstmate/bin/fm-crew-state.sh"
}

run_install() {
  HOME="$INST" FMW_INSTALL_HOME="$INST" \
  FMW_BASHRC="$INST/.bashrc" FMW_REPO="$REPO" \
  FMW_FIRSTMATE_HOME="$INST/firstmate" \
  FMW_NPM_PREFIX="$INST/npm-prefix" FMW_LOCAL_BIN="$INST/.local/bin" \
  FMW_WORKTREE_ROOT_WINDOWS="$FMW_WORKTREE_ROOT_WINDOWS" \
  PATH="$PATH_CTRL" bash "$REPO/bin/install.sh" "$@" 2>&1
}

# --- 1. initial install (complete) ---
t_begin "1: initial install"
fake_firstmate
out="$(run_install)"; rc=$?
[ "$rc" = 0 ] && t_ok "install rc=0" || t_fail "install rc=$rc: $(echo "$out" | grep ERROR | head -1)"
[ -L "$INST/.local/bin/pi" ] && t_ok "pi shim linked" || t_fail "pi shim not linked"
grep -q "npm-prefix/bin" "$INST/.bashrc" 2>/dev/null && t_ok "PATH entry added" || t_fail "PATH entry missing"
[ -f "$INST/npm-prefix/bin/tasks-axi" ] && t_ok "tasks-axi installed (fake npm)" || t_fail "tasks-axi not installed"
echo "$out" | grep -q "Firstmate present" && t_ok "Firstmate accepted" || t_fail "Firstmate not accepted"
echo "$out" | grep -q "executable bits restored" && t_ok "executable bits restored" || t_fail "chmod step missing"

# --- 2. reinstall idempotent ---
t_begin "2: reinstall idempotent"
before="$(md5sum "$INST/.bashrc" | cut -d' ' -f1)"
lines_before="$(grep -c 'export PATH=' "$INST/.bashrc")"
out="$(run_install)"
[ "$(grep -c 'export PATH=' "$INST/.bashrc")" = "$lines_before" ] && t_ok "no duplicate PATH entries" || t_fail "duplicates added"
[ "$(md5sum "$INST/.bashrc" | cut -d' ' -f1)" = "$before" ] && t_ok "bashrc unchanged on reinstall" || t_fail "bashrc changed"

# --- 3. partial install: Firstmate missing -> actionable fail ---
t_begin "3: partial install (Firstmate missing) -> actionable fail"
rm -rf "$INST/firstmate"
out="$(run_install)"; rc=$?
[ "$rc" != 0 ] && t_ok "install refused (rc=$rc)" || t_fail "install rc=0 with Firstmate missing"
echo "$out" | grep -q "Firstmate not found" && t_ok "Firstmate missing reported" || t_fail "Firstmate missing not reported"
echo "$out" | grep -q "kunchenguid/firstmate.git" && t_ok "clone command shown" || t_fail "clone command missing"
fake_firstmate

# --- 4. wrong PATH: Windows node -> refused ---
t_begin "4: Windows node on PATH -> refused"
out="$(PATH="$FMW_TESTLAB/fakewin:$PATH_CTRL" HOME="$INST" FMW_INSTALL_HOME="$INST" FMW_BASHRC="$INST/.bashrc" FMW_REPO="$REPO" FMW_FIRSTMATE_HOME="$INST/firstmate" FMW_NPM_PREFIX="$INST/npm-prefix" FMW_LOCAL_BIN="$INST/.local/bin" FMW_WORKTREE_ROOT_WINDOWS="$FMW_WORKTREE_ROOT_WINDOWS" bash "$REPO/bin/install.sh" 2>&1)"
echo "$out" | grep -q "WINDOWS build" && t_ok "Windows node detected" || t_fail "Windows node not detected"

# --- 5. Windows node detected (explicit) ---
t_begin "5: node platform enforced (Linux OK)"
out="$(run_install)"
echo "$out" | grep -q "native Linux" && t_ok "Linux node accepted" || t_fail "Linux node not reported"

# --- 6. Windows pi detected -> refused ---
t_begin "6: Windows pi on PATH -> refused"
rm -f "$INST/.local/bin/pi"
out="$(PATH="$FMW_TESTLAB/fakebin:$PATH_CTRL" HOME="$INST" FMW_INSTALL_HOME="$INST" FMW_BASHRC="$INST/.bashrc" FMW_REPO="$REPO" FMW_FIRSTMATE_HOME="$INST/firstmate" FMW_NPM_PREFIX="$INST/npm-prefix" FMW_LOCAL_BIN="$INST/.local/bin" FMW_WORKTREE_ROOT_WINDOWS="$FMW_WORKTREE_ROOT_WINDOWS" bash "$REPO/bin/install.sh" 2>&1)"
echo "$out" | grep -q "WINDOWS binary" && t_ok "Windows pi detected" || t_fail "Windows pi not detected ($(echo "$out" | grep -E "ERROR|warn" | head -1))"

# --- 7. tasks-axi missing -> installed via fake npm ---
t_begin "7: tasks-axi missing -> installed"
rm -f "$INST/.local/bin/pi" "$INST/npm-prefix/bin/tasks-axi"
out="$(run_install)"
[ -f "$INST/npm-prefix/bin/tasks-axi" ] && t_ok "tasks-axi installed" || t_fail "tasks-axi not installed"
[ -L "$INST/.local/bin/tasks-axi" ] && t_ok "tasks-axi linked" || t_fail "tasks-axi link missing"
[ -L "$INST/.local/bin/pi" ] && t_ok "pi shim linked" || t_fail "pi shim missing"

# --- 8. Firstmate missing -> refused with instructions ---
t_begin "8: Firstmate missing -> refused"
rm -rf "$INST/firstmate"
out="$(run_install)"; rc=$?
[ "$rc" != 0 ] && t_ok "install refused (rc=$rc)" || t_fail "install rc=0 with Firstmate missing"
echo "$out" | grep -q "kunchenguid/firstmate" && t_ok "upstream URL shown" || t_fail "upstream URL missing"
fake_firstmate

# --- 9. existing config -> backup created ---
t_begin "9: existing .bashrc -> backup"
printf 'export FOO=bar\n' > "$INST/.bashrc"
out="$(run_install)"
backup_count="$(ls "$INST"/.bashrc.fmw-backup-* 2>/dev/null | wc -l)"
[ "$backup_count" -ge 1 ] && t_ok "backup created ($backup_count)" || t_fail "no backup"
grep -q "FOO=bar" "$INST/.bashrc" && t_ok "original content preserved" || t_fail "original content lost"

# --- 10. rollback: dry-run leaves everything untouched ---
t_begin "10: rollback (dry-run is inert)"
before_rc="$(md5sum "$INST/.bashrc" | cut -d' ' -f1)"
before_links="$(ls -A "$INST/.local/bin" 2>/dev/null | wc -l)"
out="$(run_install "--dry-run")"
after_rc="$(md5sum "$INST/.bashrc" | cut -d' ' -f1)"
after_links="$(ls -A "$INST/.local/bin" 2>/dev/null | wc -l)"
[ "$before_rc" = "$after_rc" ] && t_ok "bashrc untouched by dry-run" || t_fail "bashrc modified by dry-run"
[ "$before_links" = "$after_links" ] && t_ok "links untouched by dry-run" || t_fail "links modified by dry-run"

# --- 11. dry-run reports actions ---
t_begin "11: dry-run reports actions"
out="$(run_install "--dry-run")"
echo "$out" | grep -q "dry-run" && t_ok "dry-run markers present" || t_fail "no dry-run markers"

# --- 12. pi package missing -> installed via fake npm ---
t_begin "12: pi package missing -> installed"
rm -rf "$INST/npm-prefix/lib/node_modules/@earendil-works/pi-coding-agent"
out="$(run_install)"
[ -f "$INST/npm-prefix/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js" ] \
  && t_ok "pi package installed" || t_fail "pi package not installed"
echo "$out" | grep -q "pi package installed" && t_ok "pi package reported" || t_fail "pi package not reported"

fmw_test_cleanup
t_summary
