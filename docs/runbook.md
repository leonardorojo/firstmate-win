# Runbook — firstmate-win (fmw)

## Quick diagnostics

```bash
fmw doctor                       # WSL/Windows environment + Firstmate + interop
fmw project list                 # registered projects
fmw project validate <name>
fmw task list                    # active tasks
fmw task status <id>             # fmw metadata + Firstmate + git + window
                                 # + terminal-state reconciliation
```

## Scout cycle (read-only investigation)

```bash
fmw task prepare --project <project> --id <task>
fmw task brief <task> --scout
fmw task spawn <task> --scout --harness pi
fmw task status <task>           # wait until the agent finishes (STATE=done)
fmw task teardown <task>         # fail-closed; keeps the branch
```

## Completion gate and tasks-axi

`tasks-axi` (backlog/decision-holds) is required by the `decision-hold` gate:
without the CLI on the pane PATH, the scout closes in `blocked:` and never
emits `done:`.

Installation and verification (WSL, no sudo, Linux npm):

```bash
npm install -g tasks-axi                  # prefix ~/.local/npm-global
ln -sf ~/.local/npm-global/bin/tasks-axi ~/.local/bin/tasks-axi
npx -y skills add kunchenguid/tasks-axi --skill tasks-axi --global --yes
tasks-axi --version                       # 0.2.4 (validated 2026-07-31)
tasks-axi update --help | grep archive-body    # required by Firstmate
tasks-axi mv --help | grep -E '\[<id>\.\.\.\]|multi' # multiple ids
# official compatibility check:
source /home/leo/firstmate/bin/fm-tasks-axi-lib.sh
fm_tasks_axi_compatible && echo "COMPATIBLE"
```

A scout already stuck in `blocked:` can be closed with steering (no Pi
restart):

```bash
fmw task send <task> "tasks-axi is installed (0.2.4,
$HOME/.local/bin/tasks-axi). Retry the pending completion gate with the Linux
CLI, close the protocol and emit done: if the brief is satisfied."
```

The official watcher is re-armed with:

```bash
bash /home/leo/firstmate/bin/fm-watch-arm.sh   # standalone tracked; beacon
# if there are queued wakes: bin/fm-wake-drain.sh BEFORE re-arming
```

## Parallel scouts (multi-task)

Two or more concurrent scouts with full isolation. Sequence validated
(2026-07-31, `parallel-scout-cloud` + `parallel-scout-build`):

```bash
# 0) watcher BEFORE the spawns (fresh beacon) + clean queue
bash ~/firstmate/bin/fm-wake-drain.sh            # if .wake-queue has records
bash ~/firstmate/bin/fm-watch-arm.sh             # tracked process (NEVER shell &)

# 1) prepare + brief per task (independent)
fmw task prepare --project <project> --id <a>
fmw task prepare --project <project> --id <b>
fmw task brief <a> --scout && fmw task brief <b> --scout

# 2) spawns (parallel or sequential; per-task locks, no race)
fmw task spawn <a> --scout --harness pi
fmw task spawn <b> --scout --harness pi
#  verify: 2 fm-<id> windows, 2 pi processes, 2 metas (distinct busy_gen)

# 3) specific mission per task (the scaffolded brief carries a literal {TASK})
fmw task send <a> "<mission A, read-only>"
fmw task send <b> "<mission B, read-only>"

# 4) wait: status logs with done: + .turn-ended + report.md per task
fmw task status <a> && fmw task status <b>   # STATE -> done for each

# 5) when the watcher exits (reason=actionable-signal): drain and re-arm
bash ~/firstmate/bin/fm-wake-drain.sh
bash ~/firstmate/bin/fm-watch-arm.sh
```

Isolation verification (everything per task-id, no cross references):

```bash
grep -c "<other-task>" ~/firstmate-win/state/tasks/<task>.conf \
  ~/firstmate/state/<task>.meta ~/firstmate/state/<task>.busy-state \
  ~/firstmate/data/<task>/report.md ~/firstmate/state/<task>.status
#   → 0 cross references expected
git -C /mnt/c/FirstmateWorktrees/<project>/<task> status --short --branch
#   → clean, HEAD = BASE_REF (scouts made no commits)
```

## Isolated modification cycle

```bash
fmw task prepare --project <project> --id <task>
fmw task brief <task>
fmw task spawn <task> --harness <harness>
# the agent edits in C:\FirstmateWorktrees\<project>\<task>
fmw build --task <task>         # Windows MSBuild over the worktree
fmw test  --task <task>
fmw task open <task> --vscode   # inspection on Windows
# review the changes; NO commit unless explicitly authorized
fmw task teardown <task>        # only after review (rejects when dirty)
```

## Common failures

| Symptom | Probable cause | Action |
|---------|----------------|--------|
| `worktree root does not exist` | missing `C:\FirstmateWorktrees\<project>` | `mkdir -p` and `fmw project validate` |
| `worktree NOT registered in git` | worktree created by another tool | `git -C <repo> worktree list`; do not force |
| `active Firstmate agent` | tmux window `fm-<id>` open | close the task in Firstmate first |
| `the worktree has local changes` | dirty worktree | review; `--force` only with authorization |
| `git worktree remove failed` | lock or protected files | `git -C <repo> worktree list` and review |
| `real treehouse not found` | shim on PATH without a real treehouse | install treehouse or ignore (fmw does not need it) |
| `FM_HOME is not set` (fmw task send) | stale wrapper | use the current fmw; the fix exports FM_HOME |
| scout closes in `blocked:` | `decision-hold` gate without `tasks-axi` in the pane | install tasks-axi + `ln -s` in `~/.local/bin` + steering (`fmw task send`) |
| `[SKIP] PowerShell interop` | FMW_SKIP_INTEROP_CHECK=1 | run `fmw doctor` without the flag |
| slow build | git under `/mnt/c` (drvfs) | wait; do not optimize before measuring |

## Terminal-state reconciliation

`fmw task status <id>` persists the authoritative terminal state and shows
the two planes separately:

```text
STATE=done                       <- persisted lifecycle (fmw conf)
...
--- operative state (authoritative source: fm-crew-state.sh) ---
fm_state=done                    <- current state per Firstmate
fm_state_source=status-log       <- origin (run-step | pane | status-log)
fm_state_detail=...              <- status-file note
fm_agent_busy=idle               <- busy-state file (busy|idle|missing)
fm_turn_ended=yes                <- complementary evidence (not a source)
fm_report=yes                    <- report.md present (not a source)
fm_teardown_elegible=yes (...|no: reason)
```

- Single source: Firstmate's `fm-crew-state.sh <id>` (reconciles run-step →
  pane busy → status-log; a dead/unreadable pane ⇒ `unknown` even when the
  log says `done:`).
- Only `done|blocked|failed` confirmed by the source are persisted;
  `working|parked|paused|idle|unknown` are shown without persisting.
  Idempotent.
- `.turn-ended` and `report.md` alone NEVER mark `done`.
- Teardown is eligible only with `STATE=done` + clean worktree + non-busy
  agent; with a live idle window it requires a prior controlled close.
- `blocked`/`failed` are not eligible: they require review (steering or
  analysis), not teardown.

## Resolving abandoned tasks

1. `fmw task status <id>` → see window/state and `fm_teardown_elegible`.
2. If the agent is alive: close it from Firstmate (or `fm-send.sh`).
3. If the agent closed in `blocked:` because of the gate: install `tasks-axi`
   (section above) and re-send steering; do not restart the agent.
4. If the window no longer exists: `fmw task teardown <id>` (requires a clean
   worktree; if dirty, review and decide).
5. Orphan worktrees not registered in fmw: do NOT touch them with fmw; review
   with `git -C <repo> worktree list` and decide manually.
