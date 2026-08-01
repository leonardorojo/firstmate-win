# firstmate-win (fmw)

**A compatibility wrapper that lets [Firstmate](https://github.com/kunchenguid/firstmate)
orchestrate Git repositories and worktrees located on Windows, while the
orchestration runtime runs inside WSL.**

`fmw` is a small, fail-closed CLI. It does **not** reimplement Firstmate: it
delegates orchestration to the official Firstmate scripts and adds the
Windows/WSL integration layer around them.

> **Status: early public release.** No tagged releases yet. Everything
> documented as *Validated* has been demonstrated end-to-end on the author's
> environment (Windows 10, WSL2 Ubuntu) and is covered by the test suite.
> Nothing here should be considered production-ready.

---

## Overview

Firstmate is a multi-agent orchestration platform. It expects repositories,
worktrees and agents to live in the same Linux environment. On Windows
development machines — where the canonical repository checkout lives on
`C:\` and real builds run with MSBuild/Visual Studio — that assumption does
not hold.

`firstmate-win` addresses this by keeping a strict split:

- **Repositories stay on Windows.** The main checkout and every task worktree
  live under `C:\FirstmateWorktrees\<project>\<task>`.
- **The runtime stays in WSL.** Firstmate, Node, Pi and the agent harness run
  as native Linux processes.
- **WSL git owns the worktree lifecycle.** Worktrees are created, validated
  and removed through `git worktree` executed inside WSL.
- **Builds stay on Windows.** The `fmw build` / `fmw test` commands dispatch
  to native Windows tools (MSBuild, dotnet.exe, vstest) via WSL interop.

## Motivation

Windows-first .NET codebases (WPF, legacy `packages.config`, Tekla/Revit
add-ins) cannot move their canonical repositories into WSL: builds, tooling
and signing require the Windows toolchain, and `git` under `/mnt/c` is slow.
Firstmate's native flow assumes a Linux repository. `fmw` bridges the two:
agents work on the Windows checkout through WSL paths, and the authoritative
build evidence always comes from the Windows toolchain.

## Relationship with Firstmate

This project is **independent** of Firstmate. To be explicit:

- `firstmate-win` is an independent compatibility wrapper, not a fork of
  Firstmate and not affiliated with the Firstmate project.
- **Firstmate must be installed separately.** This repository does not
  redistribute Firstmate or any of its dependencies.
- **This repository does not modify Firstmate upstream.** Integration happens
  through the official scripts (`fm-brief.sh`, `fm-spawn.sh`, `fm-send.sh`,
  `fm-crew-state.sh`) and a delegating `treehouse` shim; the upstream tree is
  left untouched.
- **All credit for Firstmate belongs to its original author(s).**
  See [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate).
- This project exists to improve Windows interoperability for Firstmate
  users; no endorsement or shared ownership is implied.

## Architecture

```text
WSL
├── ~/firstmate            Firstmate upstream (installed separately, INTACT)
├── ~/firstmate-win        fmw (this repository)
│   ├── bin/fmw            CLI
│   ├── bin/shims/         treehouse (delegating), node/npm/npx/pi
│   │                      (Linux runtime guaranteed)
│   ├── lib/               common config paths safety projects worktrees
│   │                      windows firstmate reconcile
│   ├── profiles/          per-project build/test/open adapters
│   ├── config/projects/   *.conf — project registry (see *.example)
│   └── state/{tasks,archive,locks}/   runtime state (never committed)
└── tmux + git + agent harness (pi)

Windows
├── C:\<repo>              main checkout (never modified by fmw)
└── C:\FirstmateWorktrees
    └── <project>\<task>   per-task worktrees (branch firstmate/<task>)
```

Key components:

- **`bin/fmw`** — the CLI (`fmw help` for the full command reference).
- **`bin/shims/`** — PATH shims that force the Linux runtime for `node`,
  `npm`, `npx` and `pi` inside agent windows, plus a delegating `treehouse`
  shim that hands each `fm-<task>` window its pre-created worktree without
  touching the upstream pool.
- **`lib/`** — the integration library: path contract (`wslpath` as the only
  truth), fail-closed safety guards, worktree lifecycle, Firstmate adapter,
  terminal-state reconciliation.
- **`profiles/`** — per-project adapters exposing
  `fmw_profile_validate / build / test / open` for the Windows toolchain.
- **`config/projects/*.conf`** — the project registry (Windows↔WSL path
  pairs per repository). See `config/projects/example.conf.example`.

## Requirements

Validated environment (see [Supported platforms](#supported-platforms)):

- Windows 10 with WSL2 (Ubuntu recommended) — validated. Windows 11 is
  expected to work but has not been externally validated yet
- WSL: `bash`, `git`, `tmux`, `flock`, `wslpath`, `realpath`
- A separate installation of Firstmate in WSL (`~/firstmate` by default,
  override with `FMW_FIRSTMATE_HOME`)
- Agent harness: native Linux `pi` (the fmw shims enforce a Linux runtime)
- `tasks-axi` CLI on the pane PATH for the Firstmate completion gate
- PowerShell and CMD interop enabled (WSL default) for Windows tool dispatch

## Installation

There is no installer: setup is manual. Before using fmw you need Firstmate
installed separately in WSL (upstream instructions), plus the Linux Node and
Pi runtimes and the `tasks-axi` CLI — see [Requirements](#requirements).

Clone this repository anywhere on Windows; the WSL side accesses it via
`/mnt/c/...`:

```bash
# on Windows
git clone https://github.com/leonardorojo/firstmate-win.git C:\firstmate-win

# in WSL (adjust the path)
cd /mnt/c/firstmate-win
bash bin/fmw doctor          # environment diagnostics
```

The CLI must run inside WSL (`wslpath` is the runtime probe). Add a small
alias in `~/.bashrc` if desired:

```bash
alias fmw='bash /mnt/c/firstmate-win/bin/fmw'
```

Then register your repositories (see [Quick Start](#quick-start)).

## Quick Start

After installing Firstmate in WSL and cloning this repository:

```bash
# 1. register your repository (creates config/projects/<name>.conf)
fmw project add --name MyApp \
  --windows-path "C:\MyApp" \
  --worktree-root "C:\FirstmateWorktrees\MyApp" \
  --profile myapp

# 2. run a read-only scout task
fmw task prepare --project MyApp --id my-first-scout
fmw task brief my-first-scout --scout
fmw task spawn my-first-scout --scout --harness pi

# 3. give the scout its actual mission — the scaffolded brief still
#    contains a {TASK} placeholder, so the agent waits until it receives
#    the real one:
fmw task send my-first-scout "Inspect the repository architecture. Read only. Produce the report requested by the brief."

# 4. wait for the agent to finish, then check the state
fmw task status my-first-scout       # STATE -> done when finished

# 5. remove the task worktree (the branch is kept). Teardown refuses while
#    the task window (fm-my-first-scout) is still open: close the window
#    first, then run teardown.
fmw task teardown my-first-scout
```

See [docs/runbook.md](docs/runbook.md) for the full lifecycle, the completion
gate setup (`tasks-axi`) and parallel execution.

## Configuration

### Project registry (`config/projects/*.conf`)

One `.conf` per registered repository. Copy
`config/projects/example.conf.example` and edit:

```conf
PROJECT_NAME='MyApp'
PROJECT_WINDOWS_PATH='C:\MyApp'
PROJECT_WSL_PATH='/mnt/c/MyApp'
PROJECT_WORKTREE_WINDOWS_ROOT='C:\FirstmateWorktrees\MyApp'
PROJECT_WORKTREE_WSL_ROOT='/mnt/c/FirstmateWorktrees/MyApp'
PROJECT_PROFILE='myapp'
REGISTERED_AT='2026-01-01T00:00:00Z'
```

Config files are parsed against a strict allowlist; nothing is `source`d or
`eval`ed. Machine-specific `.conf` files are git-ignored — only the
`*.example` file is committed.

### Environment overrides

| Variable | Default | Purpose |
|----------|---------|---------|
| `FMW_FIRSTMATE_HOME` | `$HOME/firstmate` | Firstmate installation |
| `FMW_LINUX_NODE` | `$HOME/.local/nodejs/bin/node` | Linux Node runtime path |
| `FMW_USE_WINDOWS_NODE` | unset | explicit node.exe bridge |
| `FMW_SKIP_INTEROP_CHECK` | unset | skip PowerShell interop checks (tests) |
| `FMW_SKIP_RUNTIME_CHECK` | unset | skip pi Linux runtime checks (tests) |

## Runtime architecture

The wrapper enforces a native Linux runtime for the agent stack:

- `node` resolves to the Linux Node runtime (ELF, `platform=linux`); the
  `node.exe` bridge exists only behind the explicit `FMW_USE_WINDOWS_NODE=1`
  flag, for Windows npm harnesses.
- `pi` must resolve to a Linux binary. A `pi` resolving under `/mnt/` (a
  Windows npm shim) is rejected by default — fail-closed.
- `npm` / `npx` run the Linux Node directly to avoid the `#!/usr/bin/env
  node` shebang landing on the Windows bridge.

`fmw doctor` verifies all of this and prints a per-check PASS/FAIL report.

### Windows integration

- **Interop**: `fmw exec powershell <script>` and `fmw exec cmd <command>`
  run native Windows processes from WSL and propagate their exact exit code.
- **Path contract**: every Windows↔WSL conversion goes through `wslpath`
  (`fmw_path_to_wsl` / `fmw_path_to_windows`); paths are canonicalized with
  `realpath -m` and drive letters normalized to lowercase.
- **Guards**: repositories and worktree roots must resolve under
  `/mnt/<drive>/`; native WSL paths (`/home`, `/tmp`, `/var`, `/root`) are
  rejected for worktrees.

### WSL integration

- Worktree lifecycle is executed by WSL `git` (`git worktree add/remove/
  prune`). Windows git is never used for lifecycle operations.
- tmux hosts one window per task (`fm-<task>`); the `treehouse` shim is armed
  in the tmux global PATH and in `~/.local/bin` so agent windows find it.
- The Firstmate watcher (`fm-watch-arm.sh` / `fm-watch.sh`) supervises all
  tasks of the home from a single process.

## Supported harnesses

- **Validated**: `pi` (native Linux, via the fmw shims). Every capability in
  this README was validated with the `pi` harness.
- **Not validated / not supported**: Claude, Codex, OpenCode. They are not
  part of the supported flow, even if the executables happen to exist on a
  machine.

## Supported build profiles

A profile is a per-project adapter exposing:

```bash
fmw_profile_validate          # environment/toolchain sanity
fmw_profile_build             # authoritative Windows build
fmw_profile_test              # Windows test run
fmw_profile_open <target>     # explorer | vscode | visual-studio
```

The repository ships two reference profiles:

- `profiles/ingenieumapp.sh` — a real Windows/.NET flow (`nuget restore` +
  `dotnet build` + `vstest`), with every tool overridable via
  `INGENIEUMAPP_*` environment variables. The profile contract is validated
  by the test suite; the exact build flow matches the repository's own README.
- `profiles/civilplan.sh` — a fail-loud stub.

Profiles for other projects are **experimental** until the contract is
exercised by more repositories.

## Task lifecycle

```text
prepare -> spawned -> {done|blocked|failed} -> torn-down
```

1. `fmw task prepare --project P --id T` — creates the worktree
   `C:\FirstmateWorktrees\P\T` on branch `firstmate/T` (base = current HEAD),
   writes atomic metadata (`state/tasks/T.conf`).
2. `fmw task brief T [--scout]` — creates the task brief via the official
   `fm-brief.sh`.
3. `fmw task spawn T [--scout] [--harness pi]` — hands the worktree to
   `fm-spawn.sh`; the shim delivers the worktree to the `fm-T` window.
4. `fmw task send T <message>` — steering via the official `fm-send.sh`.
5. `fmw task status T` — combined state: fmw metadata, Firstmate operative
   state (authoritative source: `fm-crew-state.sh`), git, window, and
   teardown eligibility.
6. `fmw task teardown T` — fail-closed removal; the branch is always kept.
   If the task window (`fm-T`) is still open, teardown refuses with
   "active Firstmate agent": close the window first, then run teardown.

Branches are **never** deleted without explicit authorization. Metadata is
archived (`state/archive/`) on teardown, never destroyed.

## Parallel execution

Multiple tasks run concurrently with full per-task isolation — one tmux
window, one agent process, one worktree, one metadata set per task. The only
shared components by design are the tmux global PATH (idempotent shim setup)
and the Firstmate watcher (one process supervising all tasks). Two concurrent
read-only scouts were demonstrated end-to-end; see
[docs/architecture.md](docs/architecture.md#parallelism-and-multi-task-isolation)
for the isolation table and the validated workflow.

## Safety model

- **Fail-closed teardown**: a worktree is removed only when the registered
  project, task ID, expected path, ownership record, wrapper metadata, `git
  worktree list --porcelain` output, allowed root and expected branch all
  match.
- **No `--force` surprises**: local changes block teardown unless `--force`
  is passed explicitly.
- **Active-agent guard**: teardown refuses while a `fm-<task>` tmux window
  exists.
- **Allowlist config parsing**: `.conf` files are parsed line-by-line against
  a strict key allowlist; invalid keys abort.
- **Per-task locks**: `flock` by task id around every mutable operation.
- **Terminal-state reconciliation**: only reliable terminal states (`done`,
  `blocked`, `failed`) confirmed by the authoritative Firstmate source are
  persisted; transient states are never written; `.turn-ended` and
  `report.md` alone never mark a task done.

## Troubleshooting

| Symptom | Cause | Action |
|---------|-------|--------|
| `worktree root does not exist` | missing `C:\FirstmateWorktrees\<project>` | create it and run `fmw project validate` |
| `worktree NOT registered in git` | worktree created by another tool | `git -C <repo> worktree list`; do not force |
| `active Firstmate agent` | tmux window `fm-<id>` open | close the task in Firstmate first |
| `the worktree has local changes` | dirty worktree | review; `--force` only with authorization |
| `Pi resolves to a Windows binary` | Windows npm pi shim on PATH | use the fmw shim + Linux Node (`npm install -g @earendil-works/pi-coding-agent`) |
| scout closes in `blocked:` | completion gate without `tasks-axi` in the pane | install `tasks-axi` (Linux) and re-steer with `fmw task send` |
| `FM_HOME is not set` (fmw task send) | old wrapper version | use the current fmw (it exports `FM_HOME` when calling `fm-send.sh`) |
| slow git under `/mnt/c` | drvfs | expected; measure before optimizing |

Full runbook: [`docs/runbook.md`](docs/runbook.md).

## Development

```bash
# run the full test suite (WSL; sandbox in FMW_TESTLAB, default
# /mnt/c/FirstmateWorktrees/TestLab — created and removed by the suite)
bash tests/run-all.sh

# run a single suite
bash tests/run-all.sh paths.test.sh

# syntax-check everything
for f in bin/fmw bin/shims/* lib/*.sh profiles/*.sh tests/*.sh; do bash -n "$f" || exit 1; done
```

The test suites run against a disposable sandbox and an isolated tmux socket;
they never touch the real fmw state or a live tmux server.

## Testing

The suite covers the path contract, config parser, project registry,
worktree safety (fail-closed prepare/teardown), Firstmate adapter (shim
delegation, brief/spawn/send wiring), failed-spawn recovery, runtime
detection/rejection, the IngenieumApp build profile contract and the
terminal-state reconciliation matrix. The upstream Firstmate scripts are
simulated with fakes; their real semantics are audited separately.

## Current capabilities

Maturity labels used in this repository:

- **Validated** — demonstrated end-to-end (on the author's Windows 10 +
  WSL2 Ubuntu environment) and/or covered by the test suite.
- **Preview** — working, with a narrower validation scope; expect changes.
- **Experimental** — proof-of-concept; may change or disappear.
- **Not supported** — explicitly out of scope.

### Validated

| Capability | Evidence |
|------------|----------|
| WSL runtime (CLI requires WSL) | `bin/fmw` guard, `fmw doctor` |
| Linux Node runtime enforcement | `lib/runtime.sh`, shims, runtime tests |
| Linux Pi runtime enforcement | `lib/runtime.sh`, runtime tests |
| tasks-axi integration (completion gate) | validated with tasks-axi 0.2.4 |
| Windows repositories + worktrees | `lib/worktrees.sh`, worktree-safety tests |
| Safe teardown (fail-closed, branch kept) | `lib/worktrees.sh`, worktree-safety tests |
| Multi-task isolation (per-task metadata, locks, windows) | parallel-scout trial, two concurrent tasks |
| Terminal-state reconciliation (Design C) | `lib/reconcile.sh`, reconcile tests |
| Completion gates (done/blocked/failed) | `lib/reconcile.sh`, reconcile tests |
| Failed-spawn recovery (meta published, rc≠0 downstream) | `lib/firstmate.sh`, fase6-recovery tests |
| Test suite (220 assertions across 8 suites) | `tests/run-all.sh` |

### Preview

| Capability | Evidence |
|------------|----------|
| Parallel agents (2 concurrent tasks) | parallel-scout trial: two read-only scouts, full isolation |
| Watcher integration (single watcher, N tasks) | watcher cycles during the parallel-scout trial; upstream behavior |
| Windows build profiles | `profiles/ingenieumapp.sh` (contract-validated by tests) |

### Experimental

- **Profiles for projects other than the two bundled references.** The
  profile contract works; a wider set of real projects is needed before the
  contract can be considered stable.

### Not supported

- Claude / Codex / OpenCode harnesses (only `pi` is validated)
- Generic harness abstraction
- Remote workers / multiple machines
- GUI
- Package-manager installation (no npm/pip/apt install of fmw)
- CI/CD pipelines
- Automatic updates
- Cross-platform support outside Windows + WSL2

## Roadmap

Broad engineering directions, no commitments or dates:

- Additional harness integrations
- Multi-repository orchestration improvements
- Installation/distribution improvements
- Documentation and examples

## Supported platforms

Validated only on:

- Windows 10 + WSL2 Ubuntu — validated. Windows 11: expected to work, not
  yet externally validated
- tmux (isolated test sockets; real server untouched)
- Git worktrees (WSL git as lifecycle owner)
- PowerShell / CMD interop
- Visual Studio (MSBuild/devenv/vstest on Windows)
- Linux Node (v24.x) and Pi (0.83.x, native Linux)
- tasks-axi (0.2.4)

## Validated workflows

Demonstrated end-to-end:

- `prepare` → `brief` → `spawn` → `send` → `status` → `teardown` (single task)
- Parallel scouts (two concurrent read-only tasks with full isolation)
- Watcher supervision of multiple tasks (benign absorption + consolidated
  wake)
- Completion gate + state reconciliation (`spawned → done`, idempotent)
- Failed-spawn recovery (meta published, rc≠0 downstream)

## Limitations

- Requires a Windows machine with WSL2; no other platform is supported.
- Worktrees must live on a Windows drive (`/mnt/...`); native WSL paths are
  rejected by design.
- Only the `pi` harness has been validated.
- The completion gate depends on `tasks-axi` being installed in the agent
  pane PATH.
- The Firstmate watcher is a cycle that exits on actionable wakes — it must
  be re-armed (upstream behavior, documented in the runbook).
- `git` under `/mnt/c` (drvfs) is slower than native Linux git; worktree
  creation takes ~11 s on a large repo.

## License

MIT — see [LICENSE](LICENSE).

## Attribution

Firstmate is created and maintained by its original author(s) at
[kunchenguid/firstmate](https://github.com/kunchenguid/firstmate). This
project is an independent compatibility wrapper and is not affiliated with,
endorsed by, or a fork of Firstmate. Firstmate authorship and copyright
remain with its original author(s).

---

See also: [`docs/architecture.md`](docs/architecture.md) ·
[`docs/design-decisions.md`](docs/design-decisions.md) ·
[`docs/runbook.md`](docs/runbook.md) · [`docs/rollback.md`](docs/rollback.md) ·
[`CONTRIBUTING.md`](CONTRIBUTING.md) · [`SECURITY.md`](SECURITY.md) ·
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)
