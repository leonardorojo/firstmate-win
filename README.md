# firstmate-win (fmw)

**Firstmate orchestration for Windows repositories — a compatibility wrapper
around [Firstmate](https://github.com/kunchenguid/firstmate) that runs
Firstmate agents in WSL while keeping repositories and worktrees on Windows.**

`fmw` is a small, fail-closed CLI that makes Firstmate work with Git
repositories that live on a Windows drive (`C:\...`), where the Git client
that owns the worktree lifecycle runs inside WSL. It does **not** reimplement
Firstmate: it delegates orchestration to the official Firstmate scripts and
adds the Windows/WSL integration layer around them.

---

## Overview

Firstmate is a multi-agent orchestration platform. It expects repositories,
worktrees and agents to live in the same Linux environment. On Windows
development machines — where the canonical repository checkout lives on
`C:\` and real builds run with MSBuild/Visual Studio — that assumption does
not hold.

`firstmate-win` solves exactly that problem:

- **Repositories stay on Windows.** The main checkout and every task worktree
  live under `C:\FirstmateWorktrees\<project>\<task>`.
- **The runtime stays in WSL.** Firstmate, Node, Pi and the agent harnesses
  run as native Linux processes.
- **Git lifecycle is owned by WSL git.** Worktrees are created, validated and
  removed through `git worktree` executed inside WSL — the only reliable owner
  of worktree metadata.
- **Builds stay on Windows.** The `fmw build` / `fmw test` commands dispatch
  to native Windows tools (MSBuild, dotnet.exe, vstest) via WSL interop.

## Motivation

Windows-first .NET shops (Tekla, Revit, WPF, legacy `packages.config`)
cannot move their canonical repositories into WSL: builds, tooling and
signing require the Windows toolchain, and `git` under `/mnt/c` is slow.
Firstmate's native flow assumes a Linux repo. `fmw` is the bridge: agents
work on the Windows checkout through WSL paths, and the authoritative build
evidence always comes from the Windows toolchain.

## Architecture

```text
WSL
├── ~/firstmate            Firstmate upstream (INTACT, installable)
├── ~/firstmate-win        fmw (this repository)
│   ├── bin/fmw            CLI
│   ├── bin/shims/         treehouse (delegating), node/npm/npx/pi
│   │                      (Linux runtime guaranteed)
│   ├── lib/               common config paths safety projects worktrees
│   │                      windows firstmate reconcile
│   ├── profiles/          per-project build/test/open adapters
│   ├── config/projects/   *.conf — project registry (see *.example)
│   └── state/{tasks,archive,locks}/   runtime state (never committed)
└── tmux + git + agent harnesses (pi, …)

Windows
├── C:\<repo>              main checkout (never touched by fmw)
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
  pairs per repository). Copy `*.conf.example` and adjust.

## Relationship with Firstmate

- **This project is independent.** It is not Firstmate and it is not
  affiliated with the Firstmate project.
- **Firstmate must be installed separately.** `fmw` does not redistribute
  Firstmate or any of its dependencies.
- **Firstmate authorship remains entirely with its original author(s).**
  See the [upstream repository](https://github.com/kunchenguid/firstmate).
- `fmw` invokes the official Firstmate scripts (`fm-brief.sh`, `fm-spawn.sh`,
  `fm-send.sh`, `fm-crew-state.sh`) unchanged. This repository only adds the
  Windows/WSL compatibility and orchestration layer around them.
- No endorsement, affiliation or shared ownership is implied.

## Requirements

Validated environment (see [Compatibility](#compatibility)):

- Windows 10/11 with WSL2 (Ubuntu recommended)
- WSL: `bash`, `git`, `tmux`, `flock`, `wslpath`, `realpath`
- A separate installation of Firstmate in WSL (`~/firstmate` by default,
  override with `FMW_FIRSTMATE_HOME`)
- Agent harness: native Linux `pi` (the fmw shims enforce a Linux runtime)
- `tasks-axi` CLI on the pane PATH for the Firstmate completion gate
- PowerShell and CMD interop enabled (WSL default) for Windows tool dispatch

## Installation

Clone this repository anywhere on Windows; the WSL side accesses it via
`/mnt/c/...`. The repository layout is fully relative — there is no install
step:

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

Install Firstmate separately (upstream instructions), then register your
repositories:

```bash
fmw project add --name MyApp \
  --windows-path "C:\MyApp" \
  --worktree-root "C:\FirstmateWorktrees\MyApp" \
  --profile myapp
```

## Configuration

### Project registry (`config/projects/*.conf`)

One `.conf` per registered repository. Copy the examples and edit:

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
`*.example` files are committed.

### Environment overrides

| Variable | Default | Purpose |
|----------|---------|---------|
| `FMW_FIRSTMATE_HOME` | `$HOME/firstmate` | Firstmate installation |
| `FMW_LINUX_NODE` | `$HOME/.local/nodejs/bin/node` | Linux Node runtime path |
| `FMW_USE_WINDOWS_NODE` | unset | explicit node.exe bridge |
| `FMW_SKIP_INTEROP_CHECK` | unset | skip PowerShell interop checks (tests) |
| `FMW_SKIP_RUNTIME_CHECK` | unset | skip pi Linux runtime checks (tests) |

## Runtime

The wrapper enforces a native Linux runtime for the agent stack:

- `node` resolves to the Linux Node runtime (ELF, `platform=linux`); the
  `node.exe` bridge exists only behind the explicit `FMW_USE_WINDOWS_NODE=1`
  flag, for Windows npm harnesses.
- `pi` must resolve to a Linux binary. A `pi` resolving under `/mnt/` (a
  Windows npm shim) is rejected by default — fail-closed.
- `npm` / `npx` run the Linux Node directly to avoid the `#!/usr/bin/env
  node` shebang landing on the Windows bridge.

`fmw doctor` verifies all of this and prints a per-check PASS/FAIL report.

## Windows integration

- **Interop**: `fmw exec powershell <script>` and `fmw exec cmd <command>`
  run native Windows processes from WSL and propagate their exact exit code.
- **Path contract**: every Windows↔WSL conversion goes through `wslpath`
  (`fmw_path_to_wsl` / `fmw_path_to_windows`); paths are canonicalized with
  `realpath -m` and drive letters normalized to lowercase.
- **Guards**: repositories and worktree roots must resolve under
  `/mnt/<drive>/`; native WSL paths (`/home`, `/tmp`, `/var`, `/root`) are
  rejected for worktrees.

## WSL integration

- Worktree lifecycle is executed by WSL `git` (`git worktree add/remove/
  prune`). Windows git is never used for lifecycle operations.
- tmux hosts one window per task (`fm-<task>`); the `treehouse` shim is armed
  in the tmux global PATH and in `~/.local/bin` so agent windows find it.
- The Firstmate watcher (`fm-watch-arm.sh` / `fm-watch.sh`) supervises all
  tasks of the home from a single process.

## Build profiles

A profile is a per-project adapter exposing:

```bash
fmw_profile_validate          # environment/toolchain sanity
fmw_profile_build             # authoritative Windows build
fmw_profile_test              # Windows test run
fmw_profile_open <target>     # explorer | vscode | visual-studio
```

The repository ships two reference profiles: `profiles/ingenieumapp.sh` (a
real Windows/.NET flow: `nuget restore` + `dotnet build` + `vstest`, with
every tool overridable via `INGENIEUMAPP_*` environment variables) and
`profiles/civilplan.sh` (a fail-loud stub). Write your own per project — the
contract is three functions plus `validate`.

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

Branches are **never** deleted without explicit authorization. Metadata is
archived (`state/archive/`) on teardown, never destroyed.

## Parallel execution

Multiple tasks run concurrently with full per-task isolation — one tmux
window, one agent process, one worktree, one metadata set per task. The only
shared components by design are the tmux global PATH (idempotent shim setup)
and the Firstmate watcher (one process supervising all tasks). See
[`docs/architecture.md`](docs/architecture.md#parallelism-and-multi-task-isolation)
for the isolation table and the validated parallel-scout workflow.

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
- **Terminal-state reconciliation** (Design C): only reliable terminal states
  (`done`, `blocked`, `failed`) confirmed by the authoritative Firstmate
  source are persisted; transient states are never written; `.turn-ended` and
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
| `FM_HOME is not set` (fmw task send) | stale wrapper | use the current version; the fix exports `FM_HOME` |
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

## Currently supported

Everything below is implemented and exercised by the test suite and/or
demonstrated end-to-end. Maturity labels: **Stable** (production-tested),
**Preview** (working, still maturing), **Experimental** (proof-of-concept).

| Capability | Maturity | Evidence |
|------------|----------|----------|
| WSL runtime (CLI requires WSL) | Stable | `bin/fmw` guard, `fmw doctor` |
| Linux Node runtime enforcement | Stable | `lib/runtime.sh`, shims, runtime tests |
| Linux Pi runtime enforcement | Stable | `lib/runtime.sh`, runtime tests |
| tasks-axi integration (completion gate) | Stable | validated with tasks-axi 0.2.4 |
| Windows repositories + worktrees | Stable | `lib/worktrees.sh`, worktree-safety tests |
| Parallel agents (N concurrent tasks) | Stable | Sprint 4 parallel-scout demo (2 tasks) |
| Watcher integration (single watcher, N tasks) | Stable | `fm-watch-arm.sh` cycles |
| Completion gates (done/blocked/failed) | Stable | `lib/reconcile.sh`, reconcile tests |
| State reconciliation (Design C) | Stable | `lib/reconcile.sh`, reconcile tests |
| Safe teardown (fail-closed, branch kept) | Stable | `lib/worktrees.sh`, worktree-safety tests |
| Multi-agent isolation | Stable | per-task metadata, locks, windows |
| Windows build profiles | Preview | `profiles/ingenieumapp.sh` (contract-validated) |
| Test suite (220 assertions across 8 suites) | Stable | `tests/run-all.sh` |

## Not supported

Explicitly out of scope today:

- Claude / Codex / OpenCode harness abstraction (only `pi` is wired through
  the Linux-runtime enforcement; other harnesses exist on the machine but are
  not part of the supported flow)
- Generic harness abstraction
- Remote workers / multiple machines
- GUI
- Package-manager installation (no npm/pip/apt install of fmw)
- CI/CD pipelines
- Automatic updates
- Cross-platform support outside Windows + WSL2

## Experimental

- **Windows build profiles beyond the reference adapters**: the profile
  contract is stable, but only the two bundled profiles exist. Treat
  third-party profiles as experimental until the contract is exercised by
  more projects.

## Roadmap

Broad engineering directions, no commitments or dates:

- Additional harness integrations
- Multi-repository orchestration improvements
- Installation/distribution improvements
- Documentation and examples

## Compatibility

Validated only on:

- Windows 10/11, WSL2 Ubuntu
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
- The completion gate depends on `tasks-axi` being installed in the agent
  pane PATH.
- The Firstmate watcher is a cycle that exits on actionable wakes — it must
  be re-armed (this is upstream behavior, documented in the runbook).
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
[`docs/runbook.md`](docs/runbook.md) · [`docs/rollback.md`](docs/rollback.md) ·
[`CONTRIBUTING.md`](CONTRIBUTING.md) · [`SECURITY.md`](SECURITY.md) ·
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)
