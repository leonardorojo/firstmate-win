# tests/runtime.test.sh — runtime detection and rejection
#   - Linux Node: detects platform=linux; rejects platform != linux.
#   - Linux Pi: accepts pi outside /mnt; rejects pi resolving to /mnt (Windows).
#   - spawn fail-closed: --harness pi with Windows Pi never reaches fm-spawn.sh;
#     with Linux Pi it does.
#   - fmw doctor reports Linux Node / Linux Pi and rejects Windows Pi.
. "$(dirname "$0")/harness.sh"

fmw_test_setup_sandbox
fmw_test_make_repo "$FMW_TESTLAB/repo"
fmw_test_make_profile "runtime"

# node fakes (detection by platform)
FAKE_NODE_OK="$FMW_TESTLAB/fake-node-ok"
FAKE_NODE_WIN="$FMW_TESTLAB/fake-node-win"
mkdir -p "$FAKE_NODE_OK" "$FAKE_NODE_WIN"
printf '#!/bin/sh\necho linux\n'  > "$FAKE_NODE_OK/node"
printf '#!/bin/sh\necho win32\n'  > "$FAKE_NODE_WIN/node"
chmod +x "$FAKE_NODE_OK/node" "$FAKE_NODE_WIN/node"

# pi fakes: WIN = under /mnt (Windows pattern); LINUX = /tmp (native fs)
WINDIR="$FMW_SANDBOX/fake-winbin"
mkdir -p "$WINDIR"
printf '#!/bin/sh\nexit 0\n' > "$WINDIR/pi"
chmod +x "$WINDIR/pi"
FAKEDIR="/tmp/fmw-runtime-test-$$"
mkdir -p "$FAKEDIR/bin"
printf '#!/bin/sh\nexit 0\n' > "$FAKEDIR/bin/pi"
chmod +x "$FAKEDIR/bin/pi"

# --- Linux Node ---
t_begin "Linux Node: detection by platform"

out="$(FMW_LINUX_NODE="$FAKE_NODE_OK/node" fmw_runtime_node_linux)"
t_assert_eq "$out" "$FAKE_NODE_OK/node" "detects Linux Node (platform=linux)"

if FMW_LINUX_NODE="$FAKE_NODE_WIN/node" fmw_runtime_node_linux >/dev/null 2>&1; then
  t_fail "accepted node with platform=win32"
else
  t_ok "rejects node with platform != linux"
fi
case "$FMW_RUNTIME_REASON" in
  *platform=win32*) t_ok "reason explains platform ($FMW_RUNTIME_REASON)" ;;
  *) t_fail "reason: $FMW_RUNTIME_REASON" ;;
esac

if FMW_LINUX_NODE="/no/existe/node" fmw_runtime_node_linux >/dev/null 2>&1; then
  t_fail "accepted nonexistent node"
else
  t_ok "rejects nonexistent node"
fi

# --- Linux Pi / Windows Pi / missing ---
t_begin "Linux Pi: accepts pi outside /mnt"

if out="$(PATH="$FAKEDIR/bin:$PATH" fmw_runtime_pi_linux)"; then
  t_assert_eq "$out" "$FAKEDIR/bin/pi" "Linux pi detected"
else
  t_fail "did not detect Linux pi ($FMW_RUNTIME_REASON)"
fi

t_begin "Windows Pi: rejects pi resolving to /mnt"

if PATH="$WINDIR:$PATH" fmw_runtime_pi_linux >/dev/null 2>&1; then
  t_fail "accepted Windows pi (resolves to /mnt)"
else
  t_ok "rejects pi resolving to /mnt"
fi
case "$FMW_RUNTIME_REASON" in
  *Windows*) t_ok "reason mentions Windows ($FMW_RUNTIME_REASON)" ;;
  *) t_fail "reason: $FMW_RUNTIME_REASON" ;;
esac

t_begin "missing pi: clear reason"

if PATH="/usr/bin:/bin" fmw_runtime_pi_linux >/dev/null 2>&1; then
  t_fail "detected pi with a PATH without pi"
else
  t_ok "missing pi detected"
fi
case "$FMW_RUNTIME_REASON" in
  *"not on PATH"*) t_ok "clear reason ($FMW_RUNTIME_REASON)" ;;
  *) t_fail "reason: $FMW_RUNTIME_REASON" ;;
esac

# --- spawn fail-closed ---
WTROOT="$FMW_TESTLAB/wt"
mkdir -p "$WTROOT"
fmw project add --name Runtime \
  --windows-path "C:\\FirstmateWorktrees\\TestLab\\repo" \
  --worktree-root "C:\\FirstmateWorktrees\\TestLab\\wt" \
  --profile runtime >/dev/null 2>&1 \
  || { echo "   FATAL: could not register Runtime"; exit 1; }
fmw task prepare --project Runtime --id runtime-task >/dev/null 2>&1 \
  || { echo "   FATAL: prepare failed"; exit 1; }

# fake fm-spawn.sh that records its invocation
mkdir -p "$FMW_FIRSTMATE_HOME/bin"
cat > "$FMW_FIRSTMATE_HOME/bin/fm-spawn.sh" <<'EOF'
#!/usr/bin/env bash
echo "fm-spawn.sh $*" >> "$FMW_FIRSTMATE_HOME/calls.log"
exit 0
EOF
chmod +x "$FMW_FIRSTMATE_HOME/bin/fm-spawn.sh"

t_begin "spawn fail-closed: pi harness with Windows Pi never reaches fm-spawn.sh"

rm -f "$FMW_FIRSTMATE_HOME/calls.log"
(
  unset FMW_SKIP_RUNTIME_CHECK
  export PATH="$WINDIR:$PATH"
  if fmw task spawn runtime-task --harness pi >/dev/null 2>&1; then
    t_fail "spawn with Windows Pi was not rejected"
  else
    t_ok "spawn with Windows Pi rejected (fail-closed)"
  fi
)
if [ -f "$FMW_FIRSTMATE_HOME/calls.log" ]; then
  t_fail "fm-spawn.sh was invoked with Windows Pi"
else
  t_ok "fm-spawn.sh NOT invoked"
fi

t_begin "spawn with Linux Pi DOES reach fm-spawn.sh"

rm -f "$FMW_FIRSTMATE_HOME/calls.log"
(
  unset FMW_SKIP_RUNTIME_CHECK
  export PATH="$FAKEDIR/bin:$PATH"
  fmw task spawn runtime-task --harness pi >/dev/null 2>&1
)
grep -q "fm-spawn.sh" "$FMW_FIRSTMATE_HOME/calls.log" 2>/dev/null \
  && t_ok "fm-spawn.sh invoked with Linux Pi" \
  || t_fail "fm-spawn.sh NOT invoked with Linux Pi"

# --- doctor ---
t_begin "doctor reports Linux Node / Linux Pi"

out="$(fmw doctor 2>&1 || true)"
echo "$out" | grep -q "Linux Node" && t_ok "doctor shows Linux Node" || t_fail "doctor without Linux Node"
echo "$out" | grep -q "Linux Pi"   && t_ok "doctor shows Linux Pi"   || t_fail "doctor without Linux Pi"
echo "$out" | grep -q "\[PASS\] Linux Node" && t_ok "Linux Node PASS in doctor (real runtime)" || t_fail "Linux Node not PASS in doctor"

t_begin "doctor rejects Windows Pi on PATH"

out2="$(PATH="$WINDIR:$PATH" fmw doctor 2>&1 || true)"
echo "$out2" | grep -q "\[FAIL\] Linux Pi" \
  && t_ok "doctor marks FAIL with Windows Pi on PATH" \
  || t_fail "doctor did not reject Windows Pi"

rm -rf "$FAKEDIR"

t_summary
