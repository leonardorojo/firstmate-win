# Portability gap analysis

## 1. Scope and classifications

This analysis compares the current firstmate-win compatibility layer with the validated WSL–NTFS architecture in `ValidatedHybridArchitecture.md`.

- **KEEP**: useful in the target with no ownership change.
- **ADAPT**: retain the responsibility but make its routes/configuration portable.
- **DEPRECATE**: keep temporarily while the supported upstream route becomes primary.
- **REMOVE-LATER**: remove only after migration, tests, and rollback evidence.
- **REPLACE-UPSTREAM**: delegate to Firstmate/Herdr/Pi/real Treehouse capability.
- **INVESTIGATE**: evidence or ownership is not sufficient for a safe decision.

The current checkout is clean on `main` after the crew-state recovery merge.
No live Firstmate or Herdr state is part of this analysis.

## 2. Component inventory and target disposition

| Path | Current responsibility | Original problem solved | Status | Classification | Target architecture | Minimum change | Risk | Tests |
|---|---|---|---|---|---|---|---|---|
| `bin/fmw` | Public CLI, doctor, projects, tasks, builds, tests, and integration dispatch | One WSL entry point for Windows projects | Productive but broad | ADAPT | Thin bootstrap/config/diagnostic/convenience CLI | Preserve command compatibility while routing task ownership upstream | Breaking existing users if commands disappear early | CLI smoke, doctor, compatibility tests |
| `bin/install.sh` | User-space install, PATH links, npm prefix, Firstmate checks, dry-run | Reproducible local setup without sudo | Productive | ADAPT | Idempotent dependency/bootstrap installer with no credential management | Add config convergence and static route checks; make updates explicit | Installer may alter user PATH or choose wrong runtime | Fresh WSL install, rerun, dry-run, rollback |
| `bin/shims/treehouse` | Intercepts task `get`/`return`, delegates other Treehouse commands | Deliver pre-created fmw worktrees without changing upstream | Compatibility/legacy | DEPRECATE; REMOVE-LATER | Real Treehouse has precedence and owns worktree lifecycle | Add explicit compatibility warning and route diagnostics before removal | Wrong executable precedence can bypass configured lifecycle | Treehouse precedence, compatibility and smoke tests |
| `bin/shims/node` | Native Linux Node default and optional Windows node bridge | Prevent Windows Node from running Linux Pi and convert WSL paths for node.exe | Compatibility | INVESTIGATE / DEPRECATE | Prefer upstream bootstrap and standard Linux runtime discovery | Prove whether upstream route replaces it; retain only as explicit fallback | Removing it too early can select Windows Node/Pi | Runtime matrix and clean install |
| `bin/shims/npm` | Native npm route through selected Node | Avoid Windows npm contamination | Compatibility | INVESTIGATE / DEPRECATE | Standard Linux npm route selected by config/doctor | Compare upstream bootstrap and PATH behavior | Package installs may target a different prefix | Clean install, PATH diagnostics |
| `bin/shims/npx` | Native npx route | Avoid Windows npx contamination | Compatibility | INVESTIGATE / DEPRECATE | Standard Linux npx route selected by config/doctor | Same evaluation as npm | Wrong npx can execute Windows packages | Runtime and install tests |
| `bin/shims/pi` | Direct Pi package launcher through Linux Node | Ensure Pi uses Linux Node | Compatibility | INVESTIGATE / DEPRECATE | Upstream/Herdr-managed captain and configured Pi runtime | Determine whether upstream bootstrap supplies the correct route | Duplicate captain or unsupported package layout | Captain launch and duplicate-captain tests |
| `lib/common.sh` | Defaults, state directories, logs, prerequisites | Centralized wrapper paths and safe directory setup | Productive | ADAPT | Central config resolver with shared `FM_HOME` | Introduce config precedence and compatibility aliases | Conflicting old/new state roots | Config and migration tests |
| `lib/config.sh` | Allowlisted parser and atomic writer | Avoid unsafe `eval`/`source` configuration | Productive | KEEP / ADAPT | Versioned machine config with same safety boundary | Extend allowlist without changing existing project/task keys | Invalid migration or overly broad keys | Parser, malformed config, idempotence |
| `lib/paths.sh` | WSL/Windows conversion, NTFS validation, path safety | Keep Git/worktrees on Windows-mounted filesystems | Productive | KEEP | Configurable drive/root validation | Remove normative machine-specific examples from defaults/docs | Incorrect canonicalization across WSL distros | Unit path matrix, NTFS sandbox |
| `lib/safety.sh` | Locks and ownership checks | Fail-closed teardown and branch/worktree protection | Productive | KEEP / ADAPT | Compatibility safety boundary around upstream lifecycle | Keep checks read-only where upstream owns mutation | Two lock owners could disagree | Safety and live lifecycle tests |
| `lib/projects.sh` | Multi-repository registry and path resolution | Independent projects/worktrees | Productive | ADAPT | Portable repository/worktree roots and optional profiles | Preserve existing keys; add route/profile fields only as needed | Registry migration can misroute a project | Multi-repo and config tests |
| `lib/worktrees.sh` | Prepare, branch, reconcile, abandon, teardown | Safe wrapper-owned task lifecycle | Productive but duplicated | DEPRECATE; REMOVE-LATER | Firstmate/Treehouse owns lifecycle | Freeze compatibility path, add delegation/diagnostic mode, then retire | Premature removal strands existing tasks | Compatibility and migration tests |
| `lib/windows.sh` | PowerShell/CMD invocation, profile build/test/open, exit-code preservation | Use Windows toolchain from WSL | Productive | KEEP / ADAPT | Generic explicit Windows executable boundary | Centralize executable discovery and `wslpath` cwd conversion | Quoting or exit-code regressions | Windows exec unit and WPF smoke |
| `lib/runtime.sh` | Linux Node/Pi and interop checks | Reject Windows runtime contamination | Productive | ADAPT | Static runtime and route checks, no captain requirement | Split static checks from live captain diagnosis | Doctor could incorrectly fail idle homes | Doctor matrix |
| `lib/firstmate.sh` | Calls official brief/spawn/send and links metadata | Integrate without forking Firstmate | Productive compatibility | ADAPT; DEPRECATE bookkeeping | Firstmate upstream owns tasks and steering | Preserve official delegation but stop duplicating state | Existing users depend on wrapper task commands | Compatibility and migration tests |
| `lib/reconcile.sh` | Reads upstream crew state and persists wrapper terminal state | Safe teardown eligibility | Productive compatibility | DEPRECATE; REMOVE-LATER | Upstream state is authoritative | Add read-only adapter, then remove persistence after adoption | Losing fail-closed protection during transition | Reconciliation regression suite |
| `profiles/ingenieumapp.sh` | NuGet, Windows dotnet build, VSTest and open flow | Reference Windows/.NET project execution | Optional productive profile | KEEP / ADAPT | Optional profile, never core/default dependency | Generalize tool discovery while preserving overrides | Profile assumptions may leak into generic design | Profile contract and optional WPF smoke |
| `profiles/civilplan.sh` | Validate-only stub | Placeholder profile contract | Experimental/incomplete | INVESTIGATE | Keep as fixture or replace with real evidence-backed profile | Document unsupported status before any removal | Users may mistake it for a working profile | Profile validation |
| `tests/harness.sh` | Disposable sandbox and isolated tmux test harness | Prevent tests touching real state | Productive | KEEP / ADAPT | Reusable sandbox harness plus separate live smoke harness | Make roots configurable and keep live operations opt-in | Cleanup mistakes can destroy unrelated resources | Sandbox isolation tests |
| `tests/*` lifecycle suites | Validate wrapper task, shim, reconciliation and resilience behavior | Protect old fmw lifecycle | Productive regression set | ADAPT / DEPRECATE by suite | Keep safety tests; add target ownership contract tests | Mark old expectations and migrate one suite at a time | Tests can preserve obsolete ownership | Full regression and migration matrix |
| `tests/run-all.sh` | Runs mutating disposable suite | One repeatable regression command | Productive | KEEP / ADAPT | Keep as regression runner; do not make it install/doctor/smoke | Add explicit separate commands rather than automatic E2E | Users may assume it validates live architecture | Runner, clean sandbox |
| `docs/architecture.md` | Current wrapper architecture | Explain existing design | Productive documentation | ADAPT later | Link to validated architecture and deprecation matrix | Update only after behavior slices land | Docs can promise unsupported routes | Link and documentation checks |
| `README.md` | Installation, quick start, runtime and lifecycle docs | Onboarding | Productive documentation | ADAPT later | Describe small bootstrap layer and explicit smoke | Retain compatibility section and route users upstream | User confusion during migration | Fresh install/readme walkthrough |
| `docs/runbook.md` | Installation and lifecycle operations | Repeatable operator flow | Productive documentation | ADAPT later | Separate static doctor, live captain diagnosis and E2E smoke | Add explicit lifecycle ownership and shared-FM_HOME rules | Unsafe operator action if boundaries are unclear | Runbook review and smoke |
| `docs/troubleshooting.md` | Runtime and lifecycle troubleshooting | Diagnose common WSL/Windows issues | Productive documentation | ADAPT later | Add route precedence, FM_HOME and captain distinctions | Link each symptom to static/live/smoke owner | Stale fixes can damage user environment | Documentation checks |
| `docs/rollback.md` | User-space uninstall/rollback | Recover from partial installation | Productive documentation | KEEP / ADAPT later | Preserve rollback and add config/captain cleanup boundaries | Never remove credentials or live state automatically | Rollback could touch user-owned files | Dry-run and rollback tests |

## 3. Hardcodes and machine dependencies

| Dependency | Current evidence | Classification | Target treatment |
|---|---|---|---|
| Linux user home and Firstmate root | `$HOME/firstmate` defaults | Configurable/autodetectable | Explicit route wins; home default is only a fallback |
| Windows account and drive | Examples under `C:\` and `/mnt/c` | Configurable | Discover mounted drives; require configured roots for real work |
| Repository/worktree roots | Project config stores paired Windows/WSL roots | Configurable | Preserve keys; never version actual user paths |
| Host name/distro | Not a valid architectural input | Autodetectable | Doctor reports context; no hostname defaults |
| Windows dotnet/MSBuild/VS tools | Profile-specific paths and names | Autodetectable/configurable | Resolve executable paths and preserve project overrides |
| npm/Pi PATH | `$HOME/.local/npm-global` and shims | Investigate/configurable | Compare upstream bootstrap before keeping shims |
| Treehouse route | PATH search and compatibility shim | Autodetectable/configurable | Resolve real executable explicitly; report shim conflict |
| Herdr route | Not represented in current source | Autodetectable/configurable | Add route check and captain integration in a later slice |
| `FM_HOME` | Implicit Firstmate home; partial send export | Configurable | Make one explicit shared value for supervisor, watcher, and tasks |
| Credentials, sockets, locks, beacons, metadata | Local runtime material | Non-portable state | Detect presence where safe; never version or copy |
| Live worktrees and panes | Runtime resources | Non-portable state | Create only in explicit smoke/lifecycle flows |

## 4. Portable configuration contract

Existing names should remain valid where they already express the same concept.
The target should add only missing machine-level values, using a documented precedence of explicit environment, user config, autodetection, and safe failure.

Candidate values are:

- `FM_HOME`: one shared authoritative Firstmate home.
- `FIRSTMATE_ROOT` or existing `FMW_FIRSTMATE_HOME`: upstream Firstmate checkout, with an explicit compatibility alias.
- `FMW_REPOS_ROOT`: default repository root on a Windows-mounted filesystem.
- `FMW_WORKTREES_ROOT`: default worktree root on a Windows-mounted filesystem.
- `TREEHOUSE_BIN`: resolved real Treehouse executable, not a residual shim.
- `HERDR_BIN` or equivalent configured Herdr route.
- `WINDOWS_DOTNET`: Windows dotnet executable.
- `WINDOWS_MSBUILD`: optional MSBuild executable.
- `FMW_CONFIG_FILE`: selected user configuration file.

The final names must be reconciled with the current `FMW_*`, `PROJECT_*`, task metadata, and profile variables before implementation.
No credentials, sockets, locks, beacons, task metadata, or live worktrees belong in this configuration.

## 5. Command separation

The command names below are recommendations, not an instruction to change the current CLI in this phase.
Existing compatible conventions should be retained.

| Area | Responsibility | Static/live/resource behavior |
|---|---|---|
| `install` | Verify/install WSL prerequisites, create user-space links and config | Idempotent; no credentials; no captain; no E2E resources |
| `config` | Show/validate effective portable routes and overrides | Read/write configuration only; no live lifecycle |
| `doctor` | Validate WSL, paths, binaries, Treehouse route, Firstmate, Herdr, Pi, jq and Windows tools | Static; an idle installation is not FAIL because no captain is active |
| `captain` | Start or locate the one Herdr-managed Pi captain | Live and potentially process-creating; explicit command only |
| `captain status` or live diagnostic equivalent | Report captain, lock, watcher, beacon, and active tasks | Operational diagnosis; must not be conflated with static doctor |
| `win-exec` | Convert cwd with `wslpath` and invoke one configured Windows executable | Explicit tool execution; preserve quoting, stdout, stderr and exit code |
| `smoke` | Run disposable full architecture proof | Explicit, slow, potentially resource-creating; never automatic from install/doctor |

## 6. Three diagnostic layers

### Static doctor

Static doctor answers: is the installation configured and usable?
It checks WSL/interop, WSL Git, `wslpath`, jq, Herdr and Pi binaries, Firstmate root and official scripts, the real Treehouse route, PATH, `FM_HOME`, repository/worktree roots, Windows tool executables, permissions, and configuration syntax.
It does not start a captain, acquire a lock, arm a watcher, inspect live task state, or require a live captain.

### Operational diagnosis

The live diagnostic command answers: what is happening in this home now?
It may read the captain identity, lock ownership, watcher process/beacon, active tasks, panes, and task metadata through upstream interfaces.
An absent captain is a reportable idle state, not a static installation failure.
Live diagnosis must not fabricate a beacon or repair state by copying artifacts.

### E2E smoke

The smoke command is an explicit operator action.
It may create a disposable repository, NTFS worktree, Herdr/Pi task, build process, ACK, watcher event, and teardown resources.
It must have a clear cleanup boundary, a timeout, an evidence directory outside the repository, and a final integrity check.
It must never be invoked by install or doctor.

## 7. Compatibility and gradual deprecation

1. Keep the existing lifecycle commands and fail-closed safety checks while the upstream route is introduced.
2. Make the upstream Firstmate/Herdr/real Treehouse path the documented recommendation first.
3. Add diagnostics and warnings when a compatibility shim or wrapper-owned lifecycle path is selected.
4. Preserve rollback and make each migration slice reversible.
5. Migrate tests from wrapper-owned expectations to ownership-boundary expectations one suite at a time.
6. Retire lifecycle persistence, wrapper teardown, and Treehouse interception only after the upstream path has passing tests and real adoption evidence.
7. Remove shims only after static doctor proves the standard bootstrap route works on clean installations.
8. Do not remove the IngenieumApp profile; keep it optional and reference-only.
9. Treat node/npm/npx/pi shims as INVESTIGATE/DEPRECATE until upstream bootstrap and standard configuration are proven sufficient.

## 8. Prioritized gap table

| Priority | Gap | Current component | Minimum change | Dependency | Risk | Tests |
|---:|---|---|---|---|---|---|
| P0 | No explicit shared `FM_HOME` contract | `common.sh`, `firstmate.sh`, installer | Add resolver, aliases, validation and precedence | None | State split between watcher/tasks | Config and doctor |
| P0 | Static doctor lacks complete route checks | `bin/fmw`, `runtime.sh`, installer | Separate static checks from live diagnosis | Config resolver | Idle captain misreported as failure | Static doctor matrix |
| P0 | Herdr-managed single captain absent | `runtime.sh`, `firstmate.sh`, shims | Add explicit captain adapter/status without deleting old path | Shared `FM_HOME` | Multiple write authorities | Captain duplicate/launch tests |
| P1 | Real Treehouse versus shim precedence implicit | `bin/shims/treehouse`, `firstmate.sh` | Resolve and diagnose real Treehouse route first | Config resolver | Wrong lifecycle owner | Route and compatibility tests |
| P1 | Lifecycle duplicated | `worktrees.sh`, `reconcile.sh`, Treehouse shim | Add upstream delegation boundary and read-only compatibility mode | Captain and route proof | Stranded legacy tasks | Migration lifecycle tests |
| P1 | Windows executable routes are profile-specific | `windows.sh`, profiles | Add generic configured executable discovery | Config resolver | Quoting/exit-code regression | `win-exec` and profile tests |
| P1 | Installer does not converge Herdr/captain routes | `install.sh` | Add idempotent route/config verification | Doctor | User PATH conflicts | Clean install/rerun |
| P2 | Tests mix sandbox lifecycle and live architecture | `tests/` | Separate unit/sandbox, live captain, and explicit smoke suites | Ownership boundary | False confidence or destructive tests | Runner matrix |
| P2 | Documentation describes wrapper as primary orchestrator | README and existing docs | Update after behavior slices | Stable command names | Migration confusion | Link and walkthrough checks |
| P3 | Profile/tool assumptions are not generic | `profiles/ingenieumapp.sh`, CivilPlan | Keep IngenieumApp optional; investigate profile discovery | Win-exec | Accidental core dependency | Optional profile tests |

## 9. Implementation slices

1. **Portable config and static doctor**: add effective config resolution, preserve existing names as aliases, validate roots and binaries, and separate static output from live diagnosis.
2. **Captain route**: add explicit Herdr-managed single-captain start/status behavior using the shared `FM_HOME`; do not remove old lifecycle commands.
3. **Windows execution**: centralize `wslpath` cwd conversion and Windows executable discovery while retaining exact exit-code behavior and profile overrides.
4. **Smoke contract**: add an explicit slow E2E command with disposable resources, evidence, timeouts, and cleanup; keep it out of install and doctor.
5. **Documentation**: update existing onboarding/runbook/troubleshooting documents after the command behavior is stable.
6. **Gradual deprecation**: warn on wrapper-owned lifecycle and shim paths, retain rollback, and remove only after adoption and tests.

## 10. First slice recommendation

Start with portable configuration plus static doctor.

It should not create a captain, acquire a lock, arm a watcher, inspect tasks, create worktrees, invoke Windows builds, or run an E2E smoke.
It should only resolve and report installation, routes, binaries, roots, and configuration.

The first slice should explicitly prove:

- one effective shared `FM_HOME` value is available to later supervisor/watcher/task launches;
- Firstmate and official scripts are present and clean;
- Herdr, Pi, jq, WSL Git, and the real Treehouse executable are discoverable;
- repository and worktree roots are configurable Windows-mounted paths;
- Windows tool routes are either found or clearly optional/missing;
- an idle installation is successful when all static requirements pass.

## 11. Test matrix

| Layer | Purpose | Resource behavior |
|---|---|---|
| Unit | Config parsing, precedence, path conversion, executable discovery, exit-code handling | Temporary files only |
| Sandbox | Installer idempotence, doctor pass/fail, route conflicts, compatibility aliases | Disposable sandbox; no live captain |
| Clean installation | New WSL home, user-space install, rerun, rollback | Separate WSL/user test environment |
| Live captain | Herdr-managed Pi captain, shared `FM_HOME`, singleton and operational status | Explicit live processes; never automatic |
| Smoke E2E | Treehouse NTFS worktree, real spawn, Windows build, `fm-send` ACK, watcher and teardown | Explicit, slow, disposable and cleaned |
| Regression | Existing lifecycle and safety behavior while compatibility remains | Existing test sandbox |

The IngenieumApp profile may be used as one optional Windows-tool reference in profile-specific tests.
It is not a dependency or default for the portable core.

## 12. Open risks and decisions

- Which upstream bootstrap contract is authoritative for Linux Node/Pi and whether the node/npm/npx/pi shims are still necessary.
- Exact Herdr CLI/session API and the supported single-captain startup path.
- How real Treehouse route discovery should behave when a legacy shim already exists on PATH.
- The ownership boundary and migration mechanics for existing wrapper-created tasks.
- Which Windows tool discovery strategy is reliable across Visual Studio editions and standalone SDK installations.
- Whether project profiles should remain shell contracts or move to a declarative tool-route schema.
- The final configuration file location and precedence, while preserving existing `FMW_*` and project/task keys.
- How clean-install tests can validate the route without importing credentials or live state.
- Adoption and rollback criteria required before removing lifecycle or shim compatibility.
