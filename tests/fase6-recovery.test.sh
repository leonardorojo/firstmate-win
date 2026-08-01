# tests/fase6-recovery.test.sh — failed-spawn recovery
#   - fmw_ensure_shim_path: arms the tmux global PATH WITHOUT a server
#     (start-server) and with an existing server; idempotent (no shim-dir
#     duplication).
#   - A new tmux window inherits the global PATH with the shim (treehouse + node).
#   - node dispatcher: default = NATIVE Linux Node (platform=linux, execPath
#     outside /mnt/); explicit node.exe bridge with FMW_USE_WINDOWS_NODE=1.
#   - Failed-spawn recovery: task STATE=prepared with an existing worktree
#     -> fmw task spawn updates to spawned WITHOUT recreating/removing the worktree.
#   - REALISTIC meta without backend= (the real format published by
#     fm-spawn.sh): missing keys -> empty value + backend=tmux fallback
#     (regression of the silent rc=1 caused by set -euo pipefail + no-match grep).
#   - Meta without window= or endpoint_task_id= -> clear rejection, conf intact.
#
# NOTE (socket isolation): the suite runs against its OWN tmux socket
# (TMUX_TMPDIR=/tmp/fmw-fase6-tmux). kill-server only reaches the test server;
# the user's REAL server (e.g. firstmate session with agents) stays intact and
# is explicitly verified before and after the suite.
. "$(dirname "$0")/harness.sh"
. "$FMW_LIB_DIR/firstmate.sh"   # fmw_ensure_shim_path / fmw task spawn (not loaded by the harness)

# --- tmux socket isolation + snapshot of the real server ---
export TMUX_TMPDIR="/tmp/fmw-fase6-tmux"
rm -rf "$TMUX_TMPDIR"
mkdir -p "$TMUX_TMPDIR"
realtmux() { env -u TMUX_TMPDIR -u TMPDIR tmux "$@"; }
REAL_TMUX_BEFORE="$(realtmux ls 2>&1)"

fmw_test_setup_sandbox
fmw_test_make_repo "$FMW_TESTLAB/repo"
fmw_test_make_profile "adapter"
mkdir -p "$FMW_TESTLAB/wt"      # fmw project add requires an existing worktree root

tmux kill-server >/dev/null 2>&1 || true

t_begin "fmw_ensure_shim_path: without a tmux server starts one and arms the global PATH"

tmux kill-server >/dev/null 2>&1 || true
fmw_ensure_shim_path
cur="$(tmux show-environment -g PATH 2>/dev/null || true)"
cur="${cur#PATH=}"
case "$cur" in
  "$FMW_SHIMS_DIR:"*|"$FMW_SHIMS_DIR") t_ok "tmux global PATH starts with $FMW_SHIMS_DIR" ;;
  *) echo "global PATH: [$cur]"; t_fail "global PATH does not start with the shim dir" ;;
esac

t_begin "fmw_ensure_shim_path: idempotent (does not duplicate the shim dir)"

fmw_ensure_shim_path
cur="$(tmux show-environment -g PATH 2>/dev/null || true)"
cur="${cur#PATH=}"
case "$cur" in
  "$FMW_SHIMS_DIR:$FMW_SHIMS_DIR"*) t_fail "shim duplicated in the global PATH" ;;
  "$FMW_SHIMS_DIR:"*|"$FMW_SHIMS_DIR") t_ok "no duplication on the second call" ;;
  *) t_fail "unexpected global PATH: [$cur]" ;;
esac

t_begin "real tmux pane resolves treehouse and node via ~/.local/bin"

# Every tmux window runs an interactive bash that rebuilds PATH from
# ~/.bashrc (~/.local/bin first); the tmux env does not reach the panes.
# fmw_ensure_shim_path installs the symlinks in ~/.local/bin: we verify the
# REAL resolution inside a new pane (the exact spawn mechanism).
PANE_OUT=/tmp/fmw-pane-resolve.txt
rm -f "$PANE_OUT"
tmux new-window -t firstmate -n fase6-pane >/dev/null 2>&1 \
  || { echo "   FATAL: could not create a window in firstmate"; exit 1; }
tmux send-keys -t firstmate:fase6-pane \
  'command -v treehouse > /tmp/fmw-pane-resolve.txt 2>&1; command -v node >> /tmp/fmw-pane-resolve.txt 2>&1' Enter
# robust wait: poll until the pane writes the 2 lines
resolved=""
for _ in $(seq 1 30); do
  [ -f "$PANE_OUT" ] && [ "$(wc -l < "$PANE_OUT" 2>/dev/null || echo 0)" -ge 2 ] && { resolved=1; break; }
  sleep 0.5
done
if [ -z "$resolved" ]; then
  echo "pane: $(tmux capture-pane -p -t firstmate:fase6-pane 2>/dev/null | tr '\n' ' ' | tail -c 300)"
  t_fail "the pane did not resolve the commands (timeout)"
else
  th="$(head -1 "$PANE_OUT")"
  nd="$(sed -n 2p "$PANE_OUT")"
  [ "$(readlink -f "$th" 2>/dev/null)" = "$(readlink -f "$FMW_SHIMS_DIR/treehouse")" ] \
    && t_ok "pane resolves treehouse -> shim ($th)" \
    || { echo "treehouse -> $th"; t_fail "treehouse does not point to the shim"; }
  [ "$(readlink -f "$nd" 2>/dev/null)" = "$(readlink -f "$FMW_SHIMS_DIR/node")" ] \
    && t_ok "pane resolves node -> shim ($nd)" \
    || { echo "node -> $nd"; t_fail "node does not point to the bridge"; }
fi
tmux kill-window -t firstmate:fase6-pane >/dev/null 2>&1 || true
rm -f "$PANE_OUT"

t_begin "node bridge (FMW_USE_WINDOWS_NODE=1): bin/shims/node runs the Windows node.exe"

NODE_SHIM="$FMW_SHIMS_DIR/node"
[ -x "$NODE_SHIM" ] || { echo "FATAL: missing $NODE_SHIM"; exit 1; }
if [ -x "/mnt/c/Program Files/nodejs/node.exe" ]; then
  v="$(FMW_USE_WINDOWS_NODE=1 "$NODE_SHIM" --version 2>&1)"
  case "$v" in
    v[0-9]*) t_ok "bridge node answers: $v" ;;
    *) echo "output: $v"; t_fail "bridge node did not answer --version" ;;
  esac
else
  t_ok "node.exe missing; bridge not applicable (fail-soft)"
fi

t_begin "node bridge converts WSL paths to Windows (FMW_USE_WINDOWS_NODE=1; pi on Windows)"

# node.exe does not understand /mnt/c/... (it interprets it as relative ->
# C:\mnt\c\...): the bridge converts the args with wslpath -w. Verified with
# real scripts.
probe_w="$FMW_TESTLAB/node-probe.js"
printf 'console.log("PROBE_OK", process.cwd())\n' > "$probe_w"
out="$(FMW_USE_WINDOWS_NODE=1 "$NODE_SHIM" "$probe_w" 2>&1)"
case "$out" in
  *"PROBE_OK"*) t_ok "script under /mnt/c executed (path converted by the bridge)" ;;
  *) echo "out: $out"; t_fail "the bridge did not run the /mnt/c script" ;;
esac
case "$out" in
  *"PROBE_OK C:"*) t_ok "cwd exposed as Windows (C:\...) — the agent works on native Windows" ;;
  *) echo "cwd: $out"; t_fail "cwd not converted to Windows" ;;
esac
# native WSL path (/tmp) -> \\wsl.localhost\... via 9p: node.exe reads it
printf 'console.log("HOME_OK")\n' > /tmp/fmw-home-probe.js
out3="$(FMW_USE_WINDOWS_NODE=1 "$NODE_SHIM" /tmp/fmw-home-probe.js 2>&1)"
case "$out3" in
  *"HOME_OK"*) t_ok "script on the native WSL filesystem executed via UNC" ;;
  *) echo "out: $out3"; t_fail "did not run the native WSL script" ;;
esac
rm -f "$probe_w" /tmp/fmw-home-probe.js

t_begin "default: bin/shims/node runs the native Linux Node (platform=linux, execPath outside /mnt)"

# In WSL, `node` is Linux by default. The node.exe bridge is reserved for
# FMW_USE_WINDOWS_NODE=1 (verified above).
pl="$("$NODE_SHIM" -p process.platform 2>&1)"
ep="$("$NODE_SHIM" -p process.execPath 2>&1)"
[ "$pl" = "linux" ] \
  && t_ok "process.platform=linux" \
  || { echo "platform: [$pl]"; t_fail "platform != linux (bridge active by default?)"; }
case "$ep" in
  /mnt/*) echo "execPath: [$ep]"; t_fail "execPath under /mnt (bridge active by default?)" ;;
  *) t_ok "execPath outside /mnt: $ep" ;;
esac

t_begin "pi/node resolution from WSL with the shims on PATH"

export PATH="$FMW_SHIMS_DIR:$PATH"
[ "$(command -v node)" = "$NODE_SHIM" ] \
  && t_ok "node resolves to the shim ($NODE_SHIM)" \
  || { echo "command -v node: [$(command -v node)]"; t_fail "node does not resolve to the shim"; }
if ls /mnt/c/Users/*/AppData/Roaming/npm/pi >/dev/null 2>&1; then
  grep -q "exec node" /mnt/c/Users/*/AppData/Roaming/npm/pi \
    && t_ok "the Windows npm pi shim exists and uses 'exec node' (no longer the default runtime)" \
    || t_fail "the Windows pi shim does not use 'exec node' (unexpected structure)"
  # pi must resolve to the fmw shim (bin/shims/pi -> native Linux Node),
  # NOT to the Windows npm shim.
  case "$(command -v pi)" in
    "$FMW_SHIMS_DIR/pi")
      grep -q "pi-coding-agent" "$FMW_SHIMS_DIR/pi" \
        && t_ok "pi resolves to the fmw Linux shim (bin/shims/pi)" \
        || t_fail "the fmw pi shim does not reference the Linux package"
      ;;
    */AppData/Roaming/npm/pi)
      echo "command -v pi: [$(command -v pi)]"
      t_fail "pi still resolves to the Windows npm shim (wrong default runtime)"
      ;;
    *)
      echo "command -v pi: [$(command -v pi)]"
      t_fail "pi does not resolve to the fmw shim nor the npm shim (unexpected resolution)"
      ;;
  esac
else
  t_ok "Windows npm pi shim absent; non-rejection check skipped (fail-soft)"
fi

t_begin "failed-spawn recovery: prepared + existing worktree without recreating"

# firstmate fakes (same pattern as firstmate-adapter)
# fake firstmate: fm-spawn.sh returns rc=1 BUT publishes the meta — reproduces
# the real case (REAL fm-spawn.sh: rc!=0 when the first busy event does not
# arrive, although the window was created and the meta published). The wrapper
# must link the meta and return 0 anyway.
mkdir -p "$FMW_FIRSTMATE_HOME/bin" "$FMW_FIRSTMATE_HOME/state"
for s in fm-brief.sh fm-spawn.sh fm-send.sh; do
  cat > "$FMW_FIRSTMATE_HOME/bin/$s" <<'EOF'
#!/usr/bin/env bash
echo "$0 $*" >> "$FMW_FIRSTMATE_HOME/calls.log"
exit 1
EOF
  chmod +x "$FMW_FIRSTMATE_HOME/bin/$s"
done
fmw project add --name F6Rec \
  --windows-path "C:\\FirstmateWorktrees\\TestLab\\repo" \
  --worktree-root "C:\\FirstmateWorktrees\\TestLab\\wt" \
  --profile adapter >/dev/null 2>&1 \
  || { echo "   FATAL: could not register F6Rec"; exit 1; }
fmw task prepare --project F6Rec --id f6-task >/dev/null 2>&1 \
  || { echo "   FATAL: prepare f6-task"; exit 1; }
WT="$FMW_TESTLAB/wt/f6-task"
fmw_conf_load "$FMW_TASKS_DIR/f6-task.conf" "${FMW_TASK_CONF_KEYS[@]}"
t_assert_true test -d "$WT"
t_assert_eq "$WORKTREE_WSL_PATH" "$WT" "prepare registered the correct WSL worktree"

# simulated firstmate meta (window already existing from the failed attempt)
# REALISTIC format: the meta published by fm-spawn.sh does NOT include backend=
# (real bug: the parsing died silently under set -euo pipefail and the conf
# stayed unlinked). The wrapper must tolerate the missing key and fall back to
# backend=tmux. worktree= is included and must match the registered one
# (fail-closed if it differs).
printf 'window=fm-f6-task\nendpoint_task_id=f6-task\nworktree=C:\\FirstmateWorktrees\\TestLab\\wt\\f6-task\n' \
  > "$FMW_FIRSTMATE_HOME/state/f6-task.meta"
rm -f "$FMW_FIRSTMATE_HOME/calls.log"

fmw task spawn f6-task --scout --harness pi
rc=$?
[ "$rc" -eq 0 ] || { echo "   spawn rc=$rc"; t_fail "spawn rc!=0"; }

fmw_conf_load "$FMW_TASKS_DIR/f6-task.conf" "${FMW_TASK_CONF_KEYS[@]}"
t_assert_eq "$STATE" "spawned" "STATE=spawned after recovered spawn"
t_assert_eq "$FIRSTMATE_ENDPOINT" "fm-f6-task" "FIRSTMATE_ENDPOINT linked"
t_assert_eq "$FIRSTMATE_BACKEND" "tmux" "FIRSTMATE_BACKEND=tmux (fallback: real meta without backend=)"

# the worktree was NOT recreated nor removed: it is still the same git
# worktree of the repo
t_assert_true test -d "$WT"
t_assert_eq "$WORKTREE_WSL_PATH" "$WT" "the spawn did not change the task worktree"
t_assert_eq "$(git -C "$WT" rev-parse --git-common-dir 2>/dev/null)" \
"$FMW_TESTLAB/repo/.git" "worktree still anchored to the repo (no recreation)"
if grep -q "fm-spawn.sh f6-task /mnt/c/FirstmateWorktrees/TestLab/repo --scout --harness pi" \
  "$FMW_FIRSTMATE_HOME/calls.log" 2>/dev/null; then
  t_ok "fm-spawn.sh invoked with the absolute Windows repo (--scout --harness pi)"
else
  echo "calls: $(cat "$FMW_FIRSTMATE_HOME/calls.log" 2>/dev/null)"
  t_fail "fm-spawn.sh wrongly invoked"
fi

t_begin "meta without window= or endpoint_task_id= -> clear spawn rejection"

# Without window= or endpoint_task_id= the spawn is NOT linkable: fmw must
# reject it with an explicit notice and leave the conf intact (STATE=prepared),
# neither link an empty endpoint nor die silently.
fmw task prepare --project F6Rec --id f6-bad >/dev/null 2>&1 \
  || { echo "   FATAL: prepare f6-bad"; exit 1; }
printf 'backend=tmux\n' > "$FMW_FIRSTMATE_HOME/state/f6-bad.meta"
rm -f "$FMW_FIRSTMATE_HOME/calls.log"
out="$(fmw task spawn f6-bad --scout --harness pi 2>&1)"; rc=$?
[ "$rc" -ne 0 ] \
  && t_ok "spawn rejected (rc=$rc) with meta without endpoint" \
  || { echo "out: $out"; t_fail "spawn NOT rejected with meta without endpoint"; }
echo "$out" | grep -q "without window=" \
  && t_ok "clear rejection notice ('without window= or endpoint_task_id=')" \
  || { echo "out: $out"; t_fail "missing rejection notice in the output"; }
fmw_conf_load "$FMW_TASKS_DIR/f6-bad.conf" "${FMW_TASK_CONF_KEYS[@]}"
[ "$STATE" = "prepared" ] \
  && t_ok "conf intact after rejection (STATE=prepared)" \
  || t_fail "conf mutated after rejection (STATE=$STATE)"

t_begin "shim get in a NON-active fm-<id> window enters the worktree (real spawn bug)"

# Reproduces the real scenario: the firstmate session has window 0 active and
# the fm-<id> window NOT active. display-message without target returned the
# active window name ("bash") and the shim delegated to the real (missing)
# treehouse -> "treehouse get did not enter a worktree within 60s". With
# TMUX_PANE as the target, the shim must detect fm-<id> and enter the worktree.
tmux select-window -t firstmate:0 >/dev/null 2>&1
tmux new-window -t firstmate -n fm-f6-task >/dev/null 2>&1 \
  || { echo "   FATAL: could not create the fm-f6-task window"; exit 1; }
tmux select-window -t firstmate:0 >/dev/null 2>&1   # fm-f6-task stays NOT active
tmux send-keys -t firstmate:fm-f6-task \
  "export FMW_STATE=\"$FMW_STATE\"; cd $FMW_TESTLAB/repo && treehouse get" Enter
pane_wt=""
for _ in $(seq 1 40); do
  pane_wt="$(tmux display-message -p -t firstmate:fm-f6-task '#{pane_current_path}' 2>/dev/null)"
  [ "$pane_wt" = "$WT" ] && break
  sleep 0.5
done
t_assert_eq "$pane_wt" "$WT" "shim entered the worktree from a NON-active window"
tmux kill-window -t firstmate:fm-f6-task >/dev/null 2>&1 || true

t_begin "shim via symlink (~/.local/bin) resolves the real FMW_HOME (real spawn bug)"

# The shim run through the ~/.local/bin symlink derived FMW_HOME from the
# symlink dir (BASH_SOURCE) -> nonexistent state -> the task was not found
# and it delegated to the real treehouse ("real treehouse not found"). The fix
# uses readlink -f. It runs with a CLEAN env of FMW_STATE/FMW_TASKS_DIR so the
# shim uses its own defaults (the suite exports the sandbox FMW_STATE and that
# masked the bug).
out="$(env -u FMW_STATE -u FMW_TASKS_DIR FMW_SHIM_SELFCHECK=1 "$HOME/.local/bin/treehouse" 2>&1)"
th="$(echo "$out" | grep '^FMW_HOME=' | head -1)"
# Normalized comparison with readlink -f: the shim resolves the physical path
# (readlink -f) while the harness uses the logical path (pwd). They are
# equivalent when ~/firstmate-win is a real dir or a symlink to /mnt/c/...
[ "$th" = "FMW_HOME=$(readlink -f "$FMW_HOME")" ] \
  && t_ok "real FMW_HOME via symlink ($th)" \
  || { echo "selfcheck: $out"; t_fail "FMW_HOME broken via symlink: $th"; }
tst="$(echo "$out" | grep '^FMW_STATE=' | head -1)"
[ "$tst" = "FMW_STATE=$(readlink -f "$FMW_HOME")/state" ] \
  && t_ok "FMW_STATE derived from the real FMW_HOME ($tst)" \
  || { echo "selfcheck: $out"; t_fail "FMW_STATE broken: $tst"; }

tmux kill-server >/dev/null 2>&1 || true   # only the test server (isolated socket)

REAL_TMUX_AFTER="$(realtmux ls 2>&1)"
[ "$REAL_TMUX_AFTER" = "$REAL_TMUX_BEFORE" ] \
  && t_ok "real tmux server intact after the suite" \
  || { echo "before:   [$REAL_TMUX_BEFORE]"; echo "after: [$REAL_TMUX_AFTER]"; t_fail "the real tmux server changed during the suite"; }

t_summary
