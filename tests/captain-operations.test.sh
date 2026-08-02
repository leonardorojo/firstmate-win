# tests/captain-operations.test.sh — Herdr/Pi captain and operational diagnosis
. "$(dirname "$0")/harness.sh"

fmw_test_setup_sandbox
set -- captain
FMW_NO_DISPATCH=1 source "$FMW_HOME/bin/fmw" >/dev/null
set +e

ROOT="$FMW_TESTLAB/fake upstream with spaces"
HOME_SHARED="$FMW_TESTLAB/shared captain home"
FAKE_BIN="$FMW_TESTLAB/fake-bin"
SOCKET="$FMW_TESTLAB/herdr socket"
HERDR_LOG="$FMW_TESTLAB/herdr.log"
mkdir -p "$ROOT/bin" "$ROOT/.pi/extensions" "$HOME_SHARED/state" "$FAKE_BIN"
: > "$SOCKET"
for script in fm-session-start.sh fm-watch.sh fm-spawn.sh fm-brief.sh fm-teardown.sh; do : > "$ROOT/bin/$script"; chmod +x "$ROOT/bin/$script"; done
: > "$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
: > "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${HERDR_LOG:?}"\ncase "${1:-}" in\n  --version) echo "herdr 0.7.5" ;;\n  status) echo "{\\"client\\":{\\"protocol\\":17,\\"version\\":\\"0.7.5\\"}}" ;;\n  session) echo "{\\"sessions\\":[{\\"name\\":\\"default\\",\\"running\\":true,\\"socket_path\\":\\"%s\\"}]}" ;;\n  *) exit 1 ;;\nesac\n' "$SOCKET" > "$FAKE_BIN/herdr"
printf '#!/bin/sh\necho "pi fake"\n' > "$FAKE_BIN/pi"
chmod +x "$FAKE_BIN/herdr" "$FAKE_BIN/pi"
export PATH="$FAKE_BIN:$PATH"
export HERDR_LOG
export HERDR_ENV=1 HERDR_PANE_ID=pane-1 HERDR_SOCKET_PATH="$SOCKET" HERDR_TAB_ID=tab-1 HERDR_WORKSPACE_ID=workspace-1
unset HERDR_SESSION

resolve_test_config() {
  fmw_config_resolve --firstmate-root "$ROOT" --fm-home "$HOME_SHARED" --repos-root "$FMW_TESTLAB/repos root" --worktrees-root "$FMW_TESTLAB/worktrees root"
}
reset_live() {
  rm -rf "$HOME_SHARED/state/.lock" "$HOME_SHARED/state/.watch.lock" "$HOME_SHARED/state/.last-watcher-beat"
  mkdir -p "$HOME_SHARED/state"
}
make_watcher() {
  mkdir -p "$HOME_SHARED/state/.watch.lock"
  printf '%s\n' "$$" > "$HOME_SHARED/state/.watch.lock/pid"
  printf '%s\n' "$HOME_SHARED" > "$HOME_SHARED/state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$HOME_SHARED/state/.watch.lock/watcher-path"
  touch "$HOME_SHARED/state/.last-watcher-beat"
}
make_lock_current() { printf '%s\n' "$$" > "$HOME_SHARED/state/.lock"; }
status_capture() { fmw_captain_status --firstmate-root "$ROOT" --fm-home "$HOME_SHARED" 2>&1; }

# 1-5: Herdr identity and portable configuration.
t_begin "captain: Herdr identity and shared portable configuration"
resolve_test_config
t_assert_true fmw_captain_herdr_probe
unset HERDR_ENV
t_assert_false fmw_captain_herdr_probe
export HERDR_ENV=1
unset HERDR_SESSION
t_assert_true fmw_captain_herdr_probe
old_socket="$HERDR_SOCKET_PATH"; HERDR_SOCKET_PATH="$FMW_TESTLAB/missing socket"
t_assert_false fmw_captain_herdr_probe
HERDR_SOCKET_PATH="$old_socket"
cp "$FAKE_BIN/herdr" "$FMW_TESTLAB/herdr-original"
sed "s|$SOCKET|$FMW_TESTLAB/inconsistent socket|g" "$FMW_TESTLAB/herdr-original" > "$FAKE_BIN/herdr"
t_assert_false fmw_captain_herdr_probe
cp "$FMW_TESTLAB/herdr-original" "$FAKE_BIN/herdr"
resolve_test_config
t_assert_eq "$FMW_CFG_FM_HOME" "$HOME_SHARED" "FM_HOME resolves with spaces"

# 6-7: shared home and mismatch detection.
t_begin "captain: FM_HOME consistency"
reset_live; make_lock_current; make_watcher
fmw_captain_lock_inspect; fmw_captain_watcher_inspect; fmw_captain_shared_home_check
t_assert_eq "$FMW_CAPTAIN_HOME_CONSISTENCY" consistent "captain and watcher share FM_HOME"
printf '%s\n' "$FMW_TESTLAB/other home" > "$HOME_SHARED/state/.watch.lock/fm-home"
fmw_captain_watcher_inspect; fmw_captain_shared_home_check
t_assert_eq "$FMW_CAPTAIN_HOME_CONSISTENCY" mismatch "different watcher FM_HOME is detected"

# 8-10: lock ownership is read-only and distinguishes owner/other/stale.
t_begin "captain: lock ownership"
reset_live; make_lock_current; fmw_captain_lock_inspect
t_assert_eq "$FMW_CAPTAIN_LOCK_STATE" owned "current process owns the lock"
sleep 30 & other_pid=$!
printf '%s\n' "$other_pid" > "$HOME_SHARED/state/.lock"
fmw_captain_lock_inspect
t_assert_eq "$FMW_CAPTAIN_LOCK_STATE" other "live other captain owns the lock"
kill "$other_pid" 2>/dev/null || true; wait "$other_pid" 2>/dev/null || true
printf '999999\n' > "$HOME_SHARED/state/.lock"
fmw_captain_lock_inspect
t_assert_eq "$FMW_CAPTAIN_LOCK_STATE" stale "dead lock is stale"

# 11-15: operational states and exit semantics.
t_begin "captain: operational state matrix"
reset_live
out="$(status_capture)"; rc=$?
t_assert_eq "$rc" 0 "captain not started is successful informational status"
echo "$out" | grep -q '^STATE: NOT_RUNNING$' && t_ok "NOT_RUNNING state" || t_fail "NOT_RUNNING state"
printf '999999\n' > "$HOME_SHARED/state/.lock"
out="$(status_capture)"; rc=$?
t_assert_ne "$rc" 0 "stale lock is nonzero read-only status"
echo "$out" | grep -q '^STATE: READ_ONLY$' && t_ok "READ_ONLY state" || t_fail "READ_ONLY state"
make_lock_current
out="$(status_capture)"; rc=$?
t_assert_ne "$rc" 0 "active captain without watcher is nonzero"
echo "$out" | grep -q '^STATE: WATCHER_STALE$' && t_ok "WATCHER_STALE state" || t_fail "WATCHER_STALE state"
make_watcher
out="$(status_capture)"; rc=$?
t_assert_eq "$rc" 0 "fresh watcher is ready"
echo "$out" | grep -q '^STATE: READY$' && t_ok "READY state" || t_fail "READY state"
touch -d '10 minutes ago' "$HOME_SHARED/state/.last-watcher-beat"
out="$(status_capture)"; rc=$?
t_assert_ne "$rc" 0 "stale beacon is nonzero"
echo "$out" | grep -q '^STATE: WATCHER_STALE$' && t_ok "stale beacon state" || t_fail "stale beacon state"

# 16-18: extensions, idempotence, and lock preservation.
t_begin "captain: extensions and idempotent launch guide"
reset_live; make_lock_current; make_watcher
out="$(fmw_captain status --firstmate-root "$ROOT" --fm-home "$HOME_SHARED" 2>&1)"; rc=$?
t_assert_eq "$rc" 0 "CLI status works"
t_assert_true test -f "$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
rm "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
out="$(status_capture)"; rc=$?
t_assert_ne "$rc" 0 "missing official extension is nonzero"
echo "$out" | grep -q 'STATE: MISCONFIGURED' && t_ok "missing extension is diagnosed" || t_fail "missing extension diagnosis"
: > "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
lock_before="$(sha256sum "$HOME_SHARED/state/.lock")"
out="$(fmw_captain --firstmate-root "$ROOT" --fm-home "$HOME_SHARED" 2>&1)"; rc=$?
t_assert_eq "$rc" 0 "active captain launch is idempotent"
echo "$out" | grep -q 'already active' && t_ok "active captain is not restarted" || t_fail "active captain restart warning"
lock_after="$(sha256sum "$HOME_SHARED/state/.lock")"
t_assert_eq "$lock_after" "$lock_before" "launcher does not alter the lock"

# 19-22: no beacon/Herdr mutation, exact guide, route spaces, and exit codes.
t_begin "captain: safe launch guide and mutation boundaries"
reset_live
beacon="$HOME_SHARED/state/.last-watcher-beat"; printf 'beacon\n' > "$beacon"; beacon_before="$(sha256sum "$beacon")"
: > "$HERDR_LOG"
out="$(fmw_captain --firstmate-root "$ROOT" --fm-home "$HOME_SHARED" 2>&1)"; rc=$?
t_assert_eq "$rc" 0 "no-captain launch guide is informational"
echo "$out" | grep -q 'fm-session-start.sh' && t_ok "guide uses official session start" || t_fail "guide omits session start"
echo "$out" | grep -q 'fm_watch_arm_pi' && t_ok "guide names official Pi watcher tool" || t_fail "guide omits watcher tool"
echo "$out" | grep -q 'fake\\ upstream\\ with\\ spaces' && t_ok "guide quotes paths with spaces" || t_fail "guide does not quote spaced root"
beacon_after="$(sha256sum "$beacon")"
t_assert_eq "$beacon_after" "$beacon_before" "launcher does not write the beacon"
if grep -Eq 'stop|delete|kill' "$HERDR_LOG"; then t_fail "launcher stopped or deleted Herdr"; else t_ok "launcher did not stop Herdr"; fi

# Explicit outside-Herdr diagnostic.
t_begin "captain: outside Herdr diagnostic"
unset HERDR_ENV
out="$(status_capture)"; rc=$?
t_assert_ne "$rc" 0 "outside Herdr is nonzero operational diagnosis"
echo "$out" | grep -q 'not Herdr-managed' && t_ok "outside Herdr is actionable" || t_fail "outside Herdr message missing"
export HERDR_ENV=1

fmw_test_cleanup
t_summary
