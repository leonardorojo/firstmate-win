# Design decisions — firstmate-win (fmw)

This document records the significant design decisions of the project and
the reasoning behind them. It describes how the current system came to be;
for a description of the system as it is today, see
[docs/architecture.md](docs/architecture.md).

## 1. Independent wrapper (not a fork)

The project is a standalone compatibility layer, not a fork of Firstmate.
Upstream updates therefore never conflict with local changes, and the
relationship with the upstream project stays explicit and minimal.

## 2. `treehouse` shim instead of patching upstream

Firstmate hands a worktree to an agent through `treehouse get`. To deliver a
worktree that fmw already created on Windows, the alternatives were:

- existing Firstmate API / composition / environment variables / a point
  wrapper: rejected with evidence (see the original integration audit)
- a **delegating shim** for `treehouse`: chosen.

The shim (`bin/shims/treehouse`) intercepts only:

- `treehouse get` inside an `fm-<task>` tmux window whose task is in
  `prepared`/`spawned` state — it enters the fmw-created worktree instead of
  letting treehouse create a pool worktree;
- `treehouse return` over fmw-registered worktrees — translated to
  `git worktree remove` with confirmed ownership.

Everything else delegates to the real treehouse. The shim never reimplements
the pool.

## 3. fmw owns the teardown of its tasks

fmw is the owner of its task lifecycle. The shim translates `treehouse
return` for fmw worktrees so that Firstmate's own `fm-teardown.sh` also works
unchanged when it triggers a return.

## 4. `fmw task send` exports `FM_HOME`

`fm-send.sh` (upstream) is fail-closed: it refuses to resolve steering
targets without an explicit `FM_HOME`. The wrapper exports
`FM_HOME="$FMW_FIRSTMATE_HOME"` when invoking it. This was a real wrapper bug
found during development and fixed with a regression test.

## 5. Linux runtime by default in the shims

`node`/`npm`/`npx`/`pi`/`tasks-axi` resolve under the Linux home (never
`/mnt/`); the `node.exe` bridge requires the explicit
`FMW_USE_WINDOWS_NODE=1` flag. Without `tasks-axi` on the pane PATH, the
Firstmate completion gate closes in `blocked:` — the wrapper keeps that
dependency explicit instead of hiding it.

## 6. Reconciliation = Design C with `fm-crew-state.sh` as the single source

Three designs were considered for persisting task state:

| Design | What it persists | Problem |
|--------|------------------|---------|
| A | every state with evidence | persists transients (working/parked) and mixes operative state into the lifecycle; conf churn on every status |
| B | `FMW_STATE=spawned` + `FIRSTMATE_STATE=done` | keeps the separation but leaves the wrapper blind: cannot distinguish done from abandoned and does not enable the teardown gate |
| **C** | **only reliable terminals (`done|blocked|failed`) confirmed by the source; transients stay dynamic** | no churn, fail-closed, idempotent, test-compatible |

**Chosen: Design C.** Only `done|blocked|failed` are persisted, and only when
Firstmate's `fm-crew-state.sh` (the authoritative reader) confirms them.
Transient states (`working|parked|paused|idle|unknown`) are computed
dynamically on every `fmw task status` and never written. `.turn-ended` and
`report.md` are complementary evidence, never a source.

Criteria applied: current code (allowlist conf, atomic write), teardown
invariants (gate by `STATE=done`), test compatibility (tests assume
`STATE=spawned` right after spawn — without terminal evidence nothing is
persisted) and false-positive risk (zero local rules; the Firstmate
reconciliation is delegated).
