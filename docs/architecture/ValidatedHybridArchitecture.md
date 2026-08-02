# Validated WSL–NTFS hybrid architecture

## 1. Purpose and scope

This document defines the validated operating boundary for firstmate-win.
firstmate-win is a bootstrap, configuration, diagnostics, Windows-tool, smoke-test, and documentation layer around Firstmate upstream.
It is not a replacement task orchestrator.

The architecture targets reproducible WSL installations where source repositories and agent worktrees remain on Windows/NTFS while the agent runtime and Git lifecycle remain in WSL.

## 2. Validated architecture

The runtime boundary is:

- Firstmate, Herdr, Pi, Treehouse, and Git execute in WSL.
- Repositories and worktrees are located on configurable Windows-mounted filesystems.
- WSL Git owns repository and worktree operations.
- Windows tools such as `dotnet.exe`, `MSBuild.exe`, PowerShell, CMD, NuGet, and VSTest are invoked from WSL when the project requires them.
- Visual Studio and interactive Windows debugging remain Windows concerns.
- The supervisor, watcher, and tasks use one shared `FM_HOME`.

The Windows filesystem is storage and a Windows-tool boundary, not a reason to move Git or agent orchestration into Windows.

## 3. Component boundaries

```text
Captain terminal
      |
      v
Herdr-managed Pi captain ---- shared FM_HOME ---- Firstmate upstream
      |                                               |
      |                                               +--> watcher and task lifecycle
      |                                               +--> fm-send and state
      v
Herdr/Firstmate worker route --> Pi worker
                                      |
                                      v
                              Treehouse worktree
                              (Windows/NTFS)
                                      |
                     WSL Git <--------+--------> Windows tools
                                      |             dotnet.exe/MSBuild.exe
                                      v             Visual Studio/debugger
                              build/test results
```

firstmate-win owns discovery, configuration, diagnostics, launch convenience, and the Windows execution boundary.
Firstmate upstream owns task state, spawning, steering, watcher integration, and teardown whenever its supported path provides that behavior.
Treehouse owns its real worktree pool and lifecycle unless an explicitly documented compatibility adapter is still required during migration.

## 4. End-to-end flow

1. The captain starts one Pi captain inside a Herdr-managed terminal.
2. The captain, supervisor, watcher, and tasks resolve the same configured `FM_HOME`.
3. Firstmate upstream supervises the live session and owns the task lifecycle.
4. Herdr provides the managed terminal/session boundary for Pi.
5. Firstmate starts a Pi worker through the supported runtime route.
6. Treehouse supplies an isolated worktree on the configured Windows filesystem.
7. WSL Git inspects, branches, commits, and returns worktrees; Windows Git is not used for these operations.
8. The worker invokes Windows build/test tools from WSL, preserving working directory, stdout, stderr, and exit code.
9. The captain uses the upstream steering path, including `fm-send`, when a live instruction is required.
10. Firstmate detects completion and performs the supported teardown, releasing the worker, metadata, and worktree.

The flow is intentionally explicit and may be slow.
The end-to-end smoke test is not part of installation or static diagnosis.

## 5. Mandatory invariants

1. Git operating on agent worktrees is WSL Git exclusively.
2. Supervisor, watcher, and tasks share one effective `FM_HOME`.
3. Exactly one Pi captain has captain-level write authority for a home.
4. Pi captain startup occurs inside a Herdr-managed terminal.
5. The real Treehouse executable is resolved explicitly; a residual compatibility shim must not silently take precedence.
6. Firstmate upstream owns task lifecycle, watcher, steering, state, and teardown when upstream supports the operation.
7. Repositories and worktrees remain on configurable Windows/NTFS roots.
8. Runtime state, locks, sockets, beacons, task metadata, credentials, and live worktrees are not versioned or copied between installations.
9. Firstmate upstream remains a clean, independently updateable checkout.
10. Windows toolchain execution is explicit and project-aware; arbitrary Bash-to-PowerShell translation is not provided.
11. A correctly installed but idle home is not an operational failure merely because no captain is currently active.
12. Static doctor checks installation and configuration; live diagnosis checks captain, lock, watcher, beacon, and tasks; the E2E smoke test is explicit and resource-creating.

## 6. Experimental validation evidence

The architecture has been demonstrated with real disposable resources:

- Treehouse created distinct worktrees under a Windows-mounted root.
- Firstmate launched real Pi agents through Herdr.
- Agent work was isolated in separate worktrees.
- Windows `.exe` tooling built WPF-oriented projects from those worktrees.
- `fm-send` delivered an instruction that the agent executed, producing an ACK.
- The watcher was fresh and operational when supervisor, watcher, and task shared one `FM_HOME`.
- Normal teardown released agents, task records, and worktrees.

These demonstrations validate the architecture boundary.
They do not make any particular user path, host name, Windows account, tool version, or profile a portable default.

## 7. Explicitly out of contract

The following are not architectural requirements:

- Using Git for Windows to operate agent worktrees.
- Translating arbitrary Bash commands into PowerShell commands.
- Copying live Firstmate or Herdr state between homes or machines.
- Running WPF builds with a Linux-only toolchain when the project requires Windows tooling.
- Treating the IngenieumApp profile as a generic platform dependency.
- Treating an existing Treehouse shim as the real Treehouse implementation.
- Starting a second captain because the first captain is idle or difficult to locate.

## 8. Transportability model

### Versioned

- Shell code and allowlisted configuration parsing.
- Safe defaults and documented configuration schema.
- Doctor checks and diagnostics.
- Windows execution helpers that preserve process semantics.
- Smoke-test procedure and disposable fixtures.
- Architecture, troubleshooting, rollback, and compatibility documentation.

### Configured per installation

- Firstmate upstream root.
- Shared `FM_HOME`.
- Repository root and worktree root on a Windows-mounted filesystem.
- Real Treehouse executable.
- Herdr command/session integration.
- Linux Node/Pi route when not provided by the upstream bootstrap.
- Windows PowerShell/CMD, dotnet, MSBuild, NuGet, and VSTest routes.
- Optional project profiles and their tool overrides.

### Detected

- WSL and interop availability.
- WSL Git, `wslpath`, jq, Herdr, Pi, and Treehouse versions.
- Whether configured paths resolve and are writable.
- Whether the real Treehouse route is distinct from a compatibility shim.
- Static validity of `FM_HOME`, roots, PATH, and tool executables.
- Live captain, lock, watcher, beacon, and task state only in operational diagnostics.

### Installed

- Only the documented WSL prerequisites and user-space integration needed by the selected bootstrap.
- Installation must be idempotent and must not install credentials.
- Installation must not silently update dependencies on every run.

### Never transported

- API keys or other credentials.
- Sockets, locks, beacons, task metadata, live reports, active panes, process identifiers, and worktrees.
- Host-specific absolute paths as normative defaults.
- A running captain or watcher process.

## 9. New-installation acceptance criteria

A new installation is acceptable when:

1. Static doctor passes WSL, Git, interop, configured roots, Firstmate, Herdr, Pi, jq, Treehouse, PATH, and Windows-tool checks.
2. The configured Firstmate root is clean and independently updateable.
3. The real Treehouse executable is identified without relying on a residual shim.
4. `FM_HOME` is explicit, writable, and the same value is selected for supervisor, watcher, and tasks.
5. No captain is required for static doctor to pass.
6. Captain startup creates or locates exactly one Herdr-managed Pi captain and reports its identity.
7. Operational diagnostics accurately report live lock, watcher/beacon, and active tasks without fabricating state.
8. A separately invoked smoke test can create disposable NTFS resources, exercise spawn/steering/build/teardown, and clean them up.
9. Re-running installation and static doctor does not duplicate PATH entries, create a second captain, or modify credentials.
10. Rollback can remove firstmate-win-owned installation material without touching Firstmate upstream, repositories, or live state.
