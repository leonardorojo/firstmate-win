# Runbook — firstmate-win (fmw)

## Installation from scratch

```bash
# 1. clone (Windows) and run the installer (WSL) — see README for details
git clone https://github.com/leonardorojo/firstmate-win.git C:\firstmate-win
cd /mnt/c/firstmate-win
bash bin/install.sh --dry-run     # preview (changes nothing)
bash bin/install.sh               # idempotent, user-space, no sudo

# 2. manual steps the installer cannot do:
git clone https://github.com/kunchenguid/firstmate.git ~/firstmate
#    (follow the upstream setup; fmw never modifies it)
#    authenticate pi once (its API key lives in ~/.pi/agent)
source ~/.bashrc                  # PATH entries added by the installer

# 3. verify
fmw doctor                        # expect: environment OK
```

- **Reinstallation / re-run**: always safe — idempotent, no duplicate PATH
  entries, no double links; `~/.bashrc` is backed up before any edit.
- **Partial installation**: the installer fails with the exact next command
  (e.g. missing node runtime, missing Firstmate). Apply it and re-run.
- **Authentication**: Pi's API key is manual; without it a scout cannot
  start (the installer warns when `~/.pi/agent` is absent).
- **PATH diagnosis**: `fmw doctor` checks Linux Node, Pi and interop;
  `command -v node pi tasks-axi` in the agent pane verifies the per-window
  PATH (fmw arms the shims on spawn).
- **Windows Node/Pi detected by mistake**: `node -p process.platform` must
  print `linux`; the pi on PATH must be the fmw shim link
  (`~/.local/bin/pi`). See docs/troubleshooting.md.
- **tasks-axi missing**: the installer installs and links it; without it
  the completion gate closes scouts in `blocked:`.
- **Firstmate missing**: the installer prints the clone command and stops
  (rc≠0); fmw creates `~/firstmate/state` and `~/firstmate/data` on the
  first command (no manual step).

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
fmw task send <task> "<mission — the scaffolded brief contains a {TASK} placeholder, so the agent waits for the real mission>"
fmw task status <task>           # wait until the agent finishes (STATE=done)
fmw task teardown <task>         # fail-closed; keeps the branch. Refuses while
                                 # the fm-<task> window is still open: close the
                                 # window first, then run teardown.
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
source ~/firstmate/bin/fm-tasks-axi-lib.sh
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
bash ~/firstmate/bin/fm-watch-arm.sh   # standalone tracked; beacon
# if there are queued wakes: bin/fm-wake-drain.sh BEFORE re-arming
```

## Parallel scouts (multi-task)

Two or more concurrent scouts with full isolation — on the same project or on
**different registered projects** (e.g. one task on IngenieumApp and another
on CivilPlan, simultaneously). Sequence validated with
`parallel-scout-cloud` + `parallel-scout-build` (same project) and
`mrepo-scout-ia` + `mrepo-scout-cp` (two projects):

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

## Resilience and recovery

The wrapper is stateless between invocations: every owned resource lives on
disk (repos and worktrees on Windows; task confs, Firstmate metadata, locks
and reports under `state/` and `~/firstmate`). Killing an `fmw` process at
any point loses nothing — state is written atomically and re-read on the
next invocation.

| Interruption | What persists | What is lost / needs re-arming |
|--------------|---------------|--------------------------------|
| `fmw` process killed mid-operation | task conf, worktree, metadata, lock state (flock is fd-based: released on process death) | nothing; the next `fmw task status` rebuilds the state |
| Agent window / Pi process disappears | worktree, conf, metadata, report | the window and agent; `fmw task status` reports `fm_state=unknown` (source unavailable) and stays fail-closed (no invented `done`, no worktree removal) |
| tmux server restart | worktree, conf, metadata | all windows and agents; the task is diagnosed with `fmw task status` (window absent, source unknown) |
| WSL restart | repos, worktrees, confs, metadata, locks, Linux Node/Pi/tasks-axi, the wrapper | all processes: tmux server (windows, agents), watcher — must be re-armed |

What does NOT recover automatically: tmux windows, agent processes and the
watcher. A `spawned` task whose window is gone is NOT re-spawned (fail-closed):
diagnose with `fmw task status <id>` (expect `fm_state=unknown`,
`fm_window=no tmux window`, `STATE` unchanged) and resolve with teardown
(requires authorization for real tasks) or re-creation.

Recovery procedure after a WSL restart:

```bash
wsl.exe --terminate Ubuntu          # or wsl --shutdown — REQUIRES authorization
# inside WSL, after the restart:
bash ~/firstmate-win/bin/fmw doctor          # runtime sanity (Node/Pi/tasks-axi)
tmux new-session -d -s firstmate            # re-arm the tmux server
bash ~/firstmate/bin/fm-watch-arm.sh        # re-arm the watcher (tracked; NEVER shell &)
fmw task status <id>                        # diagnose each affected task
```

Diagnostic commands: `fmw task status <id>` (persisted lifecycle + operative
state + eligibility), `fmw doctor`, `git -C <repo> worktree list`, `tmux
list-windows -a`, `ps aux | grep pi`.

Known limits: the watcher is a cycle that exits on actionable wakes or on a
stale window (see architecture); a stale window from an older task makes the
watcher exit early — re-arm it. Teardown of real tasks, `wsl --shutdown` /
`--terminate`, killing the real tmux server, `--force`, branch deletion and
any commit/push/PR require explicit authorization.

## Resolving abandoned tasks

1. `fmw task status <id>` → see window/state and `fm_teardown_elegible`.
2. If the agent is alive: close it from Firstmate (or `fm-send.sh`).
3. If the agent closed in `blocked:` because of the gate: install `tasks-axi`
   (section above) and re-send steering; do not restart the agent.
4. If the window no longer exists and the operative state is `unknown`
   (agent lost), the explicit, traceable transition is:

   ```bash
   fmw task abandon <id> --reason "agent window lost"   # STATE=abandoned
   fmw task teardown <id>                                # now eligible
   ```

   `abandon` is fail-closed: it refuses unless there is no window, the agent
   is not busy, the operative state is `unknown`, the worktree exists/is
   registered/clean at `BASE_REF`, the lock is acquirable and a human
   explicitly runs the command. It NEVER marks the task `done`.
5. `fmw task teardown <id>` (without `--force`) requires `STATE=done` or
   `STATE=abandoned`; `blocked`/`failed` require review, not teardown.
6. `fmw task teardown <id> --force` is the LAST-RESORT explicit destructive
   authorization: it skips the STATE gate and discards worktree changes.
   Use it only for a disposable task whose agent died mid-run (e.g. a frozen
   `busy` busy-state after the window was killed) — never as a routine path.
7. Orphan worktrees not registered in fmw: do NOT touch them with fmw; review
   with `git -C <repo> worktree list` and decide manually.
