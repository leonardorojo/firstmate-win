# tests/firstmate-adapter.test.sh — Firstmate integration
#   - treehouse shim: get with fmw context enters the worktree; without
#     context delegates; return over an fmw worktree translates to git
#     worktree remove.
#   - fmw task brief/spawn/send reuse the official scripts (fakes).
#   - detection by tmux window fm-<id> (real spawn flow).
. "$(dirname "$0")/harness.sh"

fmw_test_setup_sandbox
fmw_test_make_repo "$FMW_TESTLAB/repo"
fmw_test_make_profile "adapter"

# fake firstmate: official scripts that record their invocation
mkdir -p "$FMW_FIRSTMATE_HOME/bin" "$FMW_FIRSTMATE_HOME/state" "$FMW_FIRSTMATE_HOME/data"
for s in fm-brief.sh fm-spawn.sh fm-send.sh; do
  cat > "$FMW_FIRSTMATE_HOME/bin/$s" <<EOF
#!/usr/bin/env bash
echo "$s \$* FM_HOME=\${FM_HOME:-UNSET}" >> "$FMW_FIRSTMATE_HOME/calls.log"
exit 0
EOF
done

# fake REAL treehouse (to verify delegation)
mkdir -p "$FMW_TESTLAB/fakebin"
cat > "$FMW_TESTLAB/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
echo "REAL-TREEHOUSE \$*" >> "$FMW_TESTLAB/fakebin/calls.log"
exit 0
EOF

WTROOT="$FMW_TESTLAB/wt"
mkdir -p "$WTROOT"
fmw project add --name Adapter \
  --windows-path "C:\\FirstmateWorktrees\\TestLab\\repo" \
  --worktree-root "C:\\FirstmateWorktrees\\TestLab\\wt" \
  --profile adapter >/dev/null 2>&1 \
  || { echo "   FATAL: could not register Adapter"; exit 1; }
fmw task prepare --project Adapter --id adapter-task >/dev/null 2>&1 \
  || { echo "   FATAL: prepare failed"; exit 1; }
WT="$WTROOT/adapter-task"

SHIM="$FMW_HOME/bin/shims/treehouse"
export PATH="$FMW_TESTLAB/fakebin:$(dirname "$SHIM"):$PATH"

t_begin "shim: get with fmw context enters the worktree (FMW_TASK_WORKTREE)"

REC="$FMW_TESTLAB/rec.sh"
cat > "$REC" <<EOF
#!/usr/bin/env bash
pwd > "$FMW_TESTLAB/pwd-captured.txt"
exit 0
EOF
( export FMW_TASK_WORKTREE="$WT"; SHELL="$REC" bash "$SHIM" get )
t_assert_eq "$(cat "$FMW_TESTLAB/pwd-captured.txt" 2>/dev/null)" "$WT" "shim cwd = fmw worktree"

t_begin "shim: get without context delegates to the real treehouse"

rm -f "$FMW_TESTLAB/fakebin/calls.log"
FMW_TASK_WORKTREE="" bash "$SHIM" get
grep -q "REAL-TREEHOUSE get" "$FMW_TESTLAB/fakebin/calls.log" 2>/dev/null \
  && t_ok "delegated 'get'" || t_fail "did not delegate 'get'"

rm -f "$FMW_TESTLAB/fakebin/calls.log"
FMW_TASK_WORKTREE="" bash "$SHIM" get --lease
grep -q "REAL-TREEHOUSE get --lease" "$FMW_TESTLAB/fakebin/calls.log" 2>/dev/null \
  && t_ok "delegated 'get --lease'" || t_fail "did not delegate 'get --lease'"

rm -f "$FMW_TESTLAB/fakebin/calls.log"
FMW_TASK_WORKTREE="" bash "$SHIM" status
grep -q "REAL-TREEHOUSE status" "$FMW_TESTLAB/fakebin/calls.log" 2>/dev/null \
  && t_ok "delegated 'status'" || t_fail "did not delegate 'status'"

t_begin "shim: return over an fmw worktree translates to git worktree remove (fail-closed)"

printf 'dirty\n' > "$WT/base.txt"
rm -f "$FMW_TESTLAB/fakebin/calls.log"
bash "$SHIM" return "$WT" >/dev/null 2>&1
t_assert_true test -d "$WT"
if grep -q "REAL-TREEHOUSE return" "$FMW_TESTLAB/fakebin/calls.log" 2>/dev/null; then
  t_fail "delegated return of an fmw worktree (should translate)"
else
  t_ok "did not delegate: fmw translation"
fi

git -C "$WT" checkout -- base.txt 2>/dev/null
rm -f "$FMW_TESTLAB/fakebin/calls.log"
bash "$SHIM" return --force "$WT"
t_assert_false test -d "$WT"
t_assert_false fmw_safety_worktree_registered "$FMW_TESTLAB/repo" "$WT" "firstmate/adapter-task"

t_begin "shim: return over a NON-fmw path delegates"

rm -f "$FMW_TESTLAB/fakebin/calls.log"
bash "$SHIM" return --force /tmp/not-a-fmw-worktree
grep -q "REAL-TREEHOUSE return --force /tmp/not-a-fmw-worktree" "$FMW_TESTLAB/fakebin/calls.log" 2>/dev/null \
  && t_ok "delegated return of a non-fmw path" || t_fail "did not delegate return of a non-fmw path"

t_begin "shim: detection by tmux window fm-<id> (real spawn flow)"

fmw task prepare --project Adapter --id window-task >/dev/null 2>&1 \
  || { echo "   FATAL: prepare window-task"; exit 1; }
WWT="$WTROOT/window-task"
unset FMW_TASK_WORKTREE
# the session stays alive for the status/teardown tests (active agent)
env FMW_TASKS_DIR="$FMW_TASKS_DIR" FMW_ARCHIVE_DIR="$FMW_ARCHIVE_DIR" \
    PATH="$PATH" \
    tmux new-session -d -s fmw-adapt -n fm-window-task >/dev/null 2>&1
tmux send-keys -t fmw-adapt "bash $SHIM get" Enter
sleep 2
out="$(tmux capture-pane -p -t fmw-adapt 2>/dev/null)"
echo "$out" | grep -q "window-task" \
  && t_ok "the fm-window-task window entered the worktree (prompt contains window-task)" \
  || { echo "pane capture: $(echo "$out" | tail -3)"; t_fail "did not enter the worktree via window"; }

t_begin "fmw task brief/spawn/send reuse the official scripts"

rm -f "$FMW_FIRSTMATE_HOME/calls.log"
fmw task brief window-task
fmw task brief window-task --scout
# simulated firstmate meta BEFORE the spawn (the link is read from state/<id>.meta)
printf 'window=fm-window-task\nendpoint_task_id=window-task\nbackend=tmux\n' > "$FMW_FIRSTMATE_HOME/state/window-task.meta"
fmw task spawn window-task --scout --harness pi
fmw task send window-task "hello agent"
calls="$(cat "$FMW_FIRSTMATE_HOME/calls.log" 2>/dev/null)"
echo "$calls" | grep -q "fm-brief.sh window-task repo --scout" \
  && t_ok "brief --scout invoked fm-brief.sh correctly" || { echo "$calls"; t_fail "brief --scout wrong"; }
echo "$calls" | grep -q "fm-spawn.sh window-task /mnt/c/FirstmateWorktrees/TestLab/repo --scout --harness pi" \
  && t_ok "spawn invoked fm-spawn.sh with the Windows repo (absolute)" || { echo "$calls"; t_fail "spawn wrong"; }
echo "$calls" | grep -q "fm-send.sh window-task hello agent" \
  && t_ok "send invoked fm-send.sh" || { echo "$calls"; t_fail "send wrong"; }
# the real fm-send.sh is fail-closed: without explicit FM_HOME it cannot resolve targets
echo "$calls" | grep -q "fm-send.sh window-task hello agent FM_HOME=$FMW_FIRSTMATE_HOME" \
  && t_ok "send exports FM_HOME for fm-send.sh (Sprint 2.2 regression)" || { echo "$calls"; t_fail "send without FM_HOME"; }

# spawn updates the task conf to STATE=spawned and links the metadata
fmw_conf_load "$FMW_TASKS_DIR/window-task.conf" "${FMW_TASK_CONF_KEYS[@]}"
t_assert_eq "$STATE" "spawned" "STATE=spawned after spawn"
t_assert_eq "$FIRSTMATE_ENDPOINT" "fm-window-task" "FIRSTMATE_ENDPOINT linked"

# status combines firstmate meta (window still active)
st_out=$(fmw task status window-task 2>&1)
echo "$st_out" | grep -q "fm_window=active" \
  && t_ok "status reflects the active window" || t_fail "status does not reflect the window"

t_begin "teardown rejects with an active agent (window-task in tmux)"

t_assert_false fmw task teardown window-task
tmux kill-session -t fmw-adapt >/dev/null 2>&1 || true

t_summary
