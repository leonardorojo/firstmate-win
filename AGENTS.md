# AGENTS.md — firstmate-win (fmw)

Guide for agents (AI or human) working on this wrapper.

## Invariants (do not break)

1. **Firstmate runtime → WSL; repos and worktrees → Windows (`/mnt/<drive>/`).**
   Never create worktrees under `/home`, `/tmp`, `/var`, `/root`.
2. **WSL git is the sole owner of the worktree lifecycle.** Windows tools
   edit/compile/test, but never create or remove fmw-managed worktrees.
3. **Firstmate/Treehouse upstream stays intact.** Integration is done with the
   delegating shim `bin/shims/treehouse` and the official scripts
   (`fm-brief.sh`, `fm-spawn.sh`, `fm-send.sh`, `fm-crew-state.sh`).
4. **Fail-closed teardown**: task conf + `git worktree list --porcelain` +
   root + branch + basename; on ambiguity, stop and report.
5. **No `eval` or `source` of files not created by the wrapper.** Shell-safe
   config with allowlist (`lib/config.sh`).
6. **Authoritative Windows builds** (MSBuild/PowerShell/CMD); Linux
   `dotnet build` is not evidence unless the project is explicitly
   cross-platform.
7. **No commit/push/PR without authorization.** Never delete branches without
   authorization (teardown keeps `firstmate/<task>`).
8. **Installation boundary**: `bin/install.sh` is the only installer; it owns
   user-space setup (npm prefix, symlinks, `~/.bashrc` PATH with backup,
   executable bits) and never touches sudo, the Windows global PATH or the
   Firstmate upstream. `fmw_ensure_dirs` creates the upstream's
   `state/`/`data/` dirs (a fresh clone lacks them).

## Structure

```text
bin/fmw                  CLI (thin dispatch; the logic lives in lib/)
bin/install.sh           user-space installer (idempotent, --dry-run; never
                         sudo, never Windows global PATH, never upstream)
bin/shims/treehouse      delegating shim (get/return of fmw tasks; rest delegates)
lib/common.sh            base: dirs, log/die, utilities
lib/config.sh            .conf parser/writer with allowlist, atomic write
lib/paths.sh             path contract (wslpath, canonical, guards)
lib/safety.sh            flock locks + fail-closed checks
lib/projects.sh          project registry/validation
lib/worktrees.sh         prepare/show/list/status/teardown
lib/windows.sh           exec PowerShell/CMD, build/test/open via profile
lib/firstmate.sh         brief/spawn/send + shim arming in tmux
lib/reconcile.sh         operative state (fm-crew-state.sh), terminal-state
                         reconciliation and teardown eligibility
profiles/*.sh            contract: validate/build/test/open
config/projects/*.conf   project registry (4 paths + profile)
state/tasks/*.conf       task metadata (ownership)
state/archive/*.conf     retired tasks (never deleted)
tests/                   bash suites (run-all.sh)
docs/                    architecture, design-decisions, runbook, rollback
```

## Contracts

- Profile: `fmw_profile_validate`, `fmw_profile_build`, `fmw_profile_test`,
  `fmw_profile_open <target>`; context: `FMW_PROJECT_*`, `FMW_TASK_*`
  (exported by `fmw_profile_load`).
- Task: `state/tasks/<id>.conf` with the `FMW_TASK_CONF_KEYS` allowlist
  (see `lib/config.sh`). Lifecycle states: `prepared` → `spawned` →
  `{done|blocked|failed}` → `torn-down`. Terminal states
  (`done|blocked|failed`) are persisted ONLY when `fm-crew-state.sh`
  (authoritative source, see `lib/reconcile.sh`) confirms them; transient
  states (`working|parked|paused|idle|unknown`) are NEVER persisted: they are
  computed dynamically in `fmw task status`. The persisted state
  (lifecycle/ownership) and the operative state (the agent's current
  situation) are distinct concepts shown separately in the status.
- Task ID: `^[a-z0-9][a-z0-9-]{0,62}$`. Branch: `firstmate/<id>`.
- Exit codes: `fmw exec/build/test` propagate EXACTLY the Windows process
  exit code.

## Running the tests

```bash
cd ~/firstmate-win/tests && bash run-all.sh          # everything
bash run-all.sh paths.test.sh                        # one suite
```

Sandbox: `FMW_TESTLAB` (default `C:\FirstmateWorktrees\TestLab`; created and
removed by the suite itself; override with the environment variable).

## How a worktree is delivered to Firstmate (the core of the integration)

1. `fmw task prepare` creates `<worktree-root>/<id>` on branch
   `firstmate/<id>` and writes `state/tasks/<id>.conf` (STATE=prepared).
2. `fmw task spawn` arms the shim in the tmux global PATH and calls
   `fm-spawn.sh <id> <repo-wsl-path> [flags]`.
3. The tmux window `fm-<id>` runs `treehouse get` → the shim (by window name)
   enters the prepared worktree instead of creating a pool worktree.
4. Firstmate's `validate_spawn_worktree` validates the worktree against
   `git worktree list` (it passes: it is a worktree distinct from the main
   checkout).
5. On completion, `fmw task teardown` (or `treehouse return` translated by
   the shim) removes the worktree with confirmed ownership; the branch is kept.
