# Architecture — firstmate-win (fmw)

## Deployment model

```text
WSL
├── ~/firstmate            Firstmate upstream (INTACT; cloned manually, never
│                          modified by fmw; fmw creates its state/ and data/)
├── ~/firstmate-win        fmw (this repository; cloned manually)
│   ├── bin/fmw            CLI
│   ├── bin/install.sh     user-space installer (idempotent, --dry-run)
│   ├── bin/shims/         treehouse (delegating), node/npm/npx/pi
│   │                      (Linux runtime guaranteed)
│   ├── lib/               common config paths safety projects worktrees
│   │                      windows firstmate reconcile
│   ├── profiles/          example adapters (validate/build/test/open)
│   ├── config/projects/   *.conf (4 paths + profile per project)
│   └── state/{tasks,archive,locks}/
├── ~/.local/nodejs        native Linux Node (LTS; FMW_LINUX_NODE override)
├── ~/.local/npm-global    Linux npm prefix (pi, tasks-axi)
├── ~/.local/bin           symlinks: pi/tasks-axi (pane PATH)
└── tmux + git + harnesses (pi)

Windows
├── C:\<repo>              main checkout (never modified by fmw)
└── C:\FirstmateWorktrees
    ├── <project>\<task>   task worktrees (branch firstmate/<task>)
```

**Installation boundary.** `bin/install.sh` owns (all user-space, no sudo,
idempotent, never touches the Windows global PATH or the Firstmate
upstream): system-prerequisite verification, the Linux Node/npm check, the
`tasks-axi` and Pi npm packages under `~/.local/npm-global`, the
`~/.local/bin` symlinks, the executable bits of the repo scripts, the
`~/.bashrc` PATH entries (with backup), and the Windows worktree root
verification. Manual by design: cloning Firstmate upstream, the Pi API key
(`~/.pi/agent`), and registering projects. The installer never downloads
Node; it verifies the runtime and prints the exact command when missing.

## Boundaries and responsibilities

| Boundary | Owner | Mechanism |
|----------|-------|-----------|
| Worktree create/remove | WSL git (fmw) | `git worktree add/remove/prune` |
| Windows↔WSL paths | fmw | `wslpath -u/-w` + `realpath -m` + guards |
| Orchestration (briefs, spawn, supervision) | Firstmate | official scripts |
| Worktree delivery to the agent | `treehouse` shim | window `fm-<id>` → cd to the worktree |
| Completion gate (`decision-hold`) | tasks-axi (Linux) | `command -v tasks-axi` in the pane + `fm-decision-hold.sh complete/verify` |
| Build/test | Windows tools | MSBuild.exe / PowerShell / CMD (interop) |
| Teardown | fmw (fail-closed) | conf + git + root + branch + lock |

## Task flow

```text
fmw task prepare --project P --id T
  → validate id/project/root → lock → git worktree add -b firstmate/T <root>/T
  → verify (git worktree list --porcelain) → atomic metadata STATE=prepared

fmw task brief T [--scout]        → fm-brief.sh T <repo> [--scout]
fmw task spawn T [--scout] ...    → arm the shim in the tmux global PATH
  → fm-spawn.sh T <repo-wsl-path> [flags]
  → window fm-T: 'treehouse get' → shim → cd <worktree> → agent
  → linked meta: STATE=spawned, FIRSTMATE_ENDPOINT=window

fmw task status T                 → fmw metadata + Firstmate meta + git + tmux
                                   → reconcile the authoritative terminal state
                                   → persisted lifecycle + operative state +
                                     teardown eligibility
fmw build/test --task T           → profile → MSBuild/vstest over the worktree
fmw task teardown T               → no active agent + git registered + clean
  → git worktree remove → archive conf (STATE=torn-down) → branch kept
```

## Security (fail-closed)

- **Paths**: every worktree must resolve under `/mnt/<drive>/`; `/home`,
  `/tmp`, `/var`, `/root` are rejected (two layers: project root and task
  target).
- **Ownership**: teardown requires `state/tasks/<id>.conf` (atomic write,
  allowlist), basename match, root, branch and `git worktree list`.
- **Active agent**: teardown refuses while a tmux window `fm-<id>` exists.
- **Teardown eligibility**: only with `STATE=done` (persisted by the
  authoritative source) + clean worktree + non-busy agent; a live window with
  busy-state `idle` is eligible after a controlled close; missing or `busy`
  busy-state ⇒ not eligible.
- **Local changes**: teardown rejects dirty worktrees unless `--force` is
  explicit.
- **Shim**: only intercepts `treehouse get` (windows `fm-<id>` with a task in
  prepared/spawned) and `treehouse return` of fmw-registered paths; everything
  else delegates to the real treehouse. It does not reimplement the pool.
- **Locks**: `flock` per task id around mutable operations.

## Parallelism and multi-task isolation

The system supports N concurrent tasks without shared resources between them,
**including tasks belonging to different registered projects**. Each task is
a **disjoint set of identifiers and resources**:

| Resource | Isolated by | Mechanism |
|----------|-------------|-----------|
| tmux window | task-id | `fm-<id>` (one per task; created and registered by `fm-spawn.sh`) |
| Agent process | task-id | one pi process per window (harness), started by the shim |
| Worktree | task-id | `C:\FirstmateWorktrees\<project>\<id>`, branch `firstmate/<id>` |
| fmw metadata | task-id | `state/tasks/<id>.conf` + `state/locks/<id>.lock` (flock per task) |
| Firstmate metadata | task-id | `state/<id>.meta`, `state/<id>.busy-state`, `state/<id>.status`, `state/<id>.pi-ext.ts` |
| Brief/report | task-id | `data/<id>/brief.md`, `data/<id>/report.md` |
| Supervision events | task-id | busy-gen/seq and turn-ended per task; consolidated wakes by the watcher |

Design points that make parallelism possible without upstream changes:

- **The `treehouse` shim resolves by window name**: the spawn arms the shim in
  the tmux global PATH once (idempotent, via `tmux set-environment -g`); each
  `fm-<id>` window runs `treehouse get` and the shim delivers the worktree of
  ITS task. Concurrent spawns do not race: locks are per task-id and the shim
  is read-only over registered paths.
- **One watcher supervises N tasks**: `fm-watch.sh` is a singleton-locked
  process that classifies wakes of ALL tasks of the home. Benign signals (with
  busy-state `busy`) are absorbed; actionable ones are queued into one
  consolidated wake, then the watcher exits (reason=actionable-signal, exit
  0). The captain re-arms it with `fm-watch-arm.sh` (tracked process; NEVER a
  shell `&`, which gets reaped and leaves supervision down).
- **Per-task events**: each task's busy-state is a separate file with its own
  sequence (`gen`/`seq`); one task's `done:` does not alter another task's
  busy-state or status.
- **Per-task reconciliation and gate**: `fmw task status <id>` reconciles and
  persists ONLY the indicated task; teardown eligibility is evaluated per task
  and never touches other worktrees/windows.
- **Per-project isolation**: every task conf carries its own `PROJECT_NAME`,
  repository path and worktree root; the registry lookup is read-only
  (`fmw_conf_value`), so iterating over registered projects never leaks one
  project's values into another task's prepare/brief/spawn steps. Two
  concurrent scouts on two different repositories (IngenieumApp + CivilPlan)
  were demonstrated end-to-end with zero metadata cross-contamination.

### Observed limits

1. **The watcher is not a permanent daemon**: every cycle ends on the first
   actionable wake (by design: notify the captain). With tasks in flight it
   must be re-armed after each cycle; the `WATCHER DOWN` banner printed by
   fmw at spawn when the beacon is stale (>grace 300s) is informational and
   does not block the operation.
2. **Scaffolded brief with literal `{TASK}`**: `fm-brief.sh --scout` writes
   the standard contract with the placeholder that the Firstmate captain LLM
   fills in. Without an active captain, the agent starts in
   `needs-decision` and only proceeds after receiving the mission via
   `fmw task send` (official steering).
3. **Orphan wakes**: after a task teardown, the wakes of its status remain in
   `.wake-queue` (historical records). Harmless; cleaned with
   `fm-wake-drain.sh` (atomic drain, closes the supervision cycle).
4. **Idle pi processes**: after `agent-settled`, the pi process stays alive in
   its window waiting for input (the normal state of a task without teardown).
   Teardown closes the window and terminates it.
5. **`no registry at data/projects.md` notice**: benign; the no-mistakes mode
   does not apply to scouts (kind=scout → report, no merge).

These limits were observed during the two-concurrent-scouts trial.

6. **A stale window from an older task makes the watcher exit early**: if an
   old `fm-<id>` window (left open by design, awaiting teardown authorization)
   stops answering the agent heartbeat, the watcher reports it as `stale`
   and exits before later tasks finish — their terminal events are not
   watched. This does not affect task state, reconciliation or reports; the
   watcher must simply be re-armed (and the stale window eventually closed).

### Recommendations (routine parallelism)

- Arm the watcher BEFORE the spawns and re-arm it after each cycle.
- Send the specific mission (`fmw task send`) right after each spawn.
- Drain `.wake-queue` after each watcher cycle.
- Concurrent spawns are safe (per-task locks), but prepare and brief both
  tasks before launching the spawns.

## State model and reconciliation (Design C)

### Two planes, never mixed

- **Persisted** (`STATE` in `state/tasks/<id>.conf`) = worktree lifecycle and
  ownership. Documented transition:
  `prepared → spawned → {done|blocked|failed} → torn-down`.
- **Operative** = the agent's current situation according to Firstmate:
  `working | parked | done | blocked | paused | failed | unknown`.
  It is dynamic: recomputed on every `fmw task status`.

### Authoritative source

`fm-crew-state.sh <id>` from Firstmate (upstream, unmodified). It is the
deterministic reader of current state: it reconciles run-step → pane busy →
status-log. The status-log is **not** current state (it is an append-only
event log): the last `done:` line counts only if the pane is not busy and is
readable; a dead/unreadable pane ⇒ `unknown` even when the log says `done:`.

### Decision: Design C (hybrid)

| Design | What it persists | Problem |
|--------|------------------|---------|
| A | every state with evidence | persists transients (working/parked) and mixes operative into lifecycle; conf churn on every status |
| B | `FMW_STATE=spawned` + `FIRSTMATE_STATE=done` | keeps the separation but leaves the wrapper blind: cannot tell done from abandoned and does not enable the teardown gate |
| **C** | **only reliable terminals (`done|blocked|failed`) confirmed by the source; transients stay dynamic** | no churn, fail-closed, idempotent, test-compatible |

Criteria applied: current code (allowlist conf, atomic write), teardown
invariants (gate by `STATE=done`), compatibility (tests assume
`STATE=spawned` right after spawn — without terminal evidence nothing is
persisted) and false-positive risk (zero local rules; the Firstmate
reconciliation is delegated).

### Reconciliation rules (`lib/reconcile.sh`)

1. Acts only on `prepared|spawned` lifecycles (never on `torn-down`).
2. Persists `done|blocked|failed` only when `fm-crew-state.sh` emits them;
   `working|parked|paused|idle|unknown` are never persisted.
3. `.turn-ended` and `report.md` are complementary evidence of the status, not
   a source: alone they never mark `done`.
4. Fail-closed: missing/failed/unparseable source ⇒ `STATE` unchanged and the
   task is not teardown-eligible.
5. Idempotent: re-running over a reconciled conf does not alter it (verified
   with `cmp` in the tests).
6. `blocked` is terminal but recoverable: reconciliation re-evaluates on every
   status and will overwrite `blocked → done` when the crew finishes.
7. Reconciliation only reads the source and writes the conf: it never touches
   windows, processes, worktrees or the upstream.

### Teardown eligibility

`fmw_task_teardown_elegible` = `STATE=done` + worktree present and clean +
agent not busy (no `fm-<id>` window, or a window with busy-state `idle` →
requires a prior controlled close; `busy`/missing/unreadable ⇒ not eligible).
`blocked` and `failed` require captain review, not teardown.

## Persistence and recovery

Every owned resource lives on disk: repositories and worktrees on Windows,
task confs / locks under `state/`, Firstmate metadata and reports under
`~/firstmate`. The wrapper is stateless between invocations and writes
atomically, so killing a `fmw` process loses nothing. Processes are the only
volatile layer: tmux windows, agent processes and the watcher die with their
server/WSL session and must be re-armed; a task whose window is gone is
diagnosed (not re-spawned) — `fm_state=unknown`, `STATE` unchanged,
fail-closed. See `docs/runbook.md` (Resilience and recovery) for the
per-interruption matrix and recovery procedure.

## Performance (measured)

- `git status` on a 1337-file Windows repo from WSL: ~39 s first pass.
- `git worktree add` from WSL over a Windows repo: ~11 s.
- Windows profiles run native MSBuild (never Linux `dotnet`).

---

See [docs/design-decisions.md](design-decisions.md) for the rationale behind
the current architecture (shim approach, Design C, Linux runtime policy).
