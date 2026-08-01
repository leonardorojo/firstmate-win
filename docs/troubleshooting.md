# Troubleshooting — firstmate-win (fmw)

Failure diagnosis and remediation. Run `fmw doctor` first: it checks the WSL
runtime, interop, Firstmate, Linux Node and Pi in one pass.

## node resolves to Windows

Symptom: `node --version` works but `node -p process.platform` prints
`win32`; the installer refuses with "node on PATH is a WINDOWS build";
agents misbehave with "WSL scripts from node.exe" errors.

Cause: the Windows `node.exe` bridge (`/mnt/c/Program Files/nodejs`) precedes
the native Linux Node in PATH.

Fix: put the Linux Node bin first, e.g. in `~/.bashrc`:

```bash
export PATH="$HOME/.local/nodejs/bin:$PATH"
```

Verify with `node -p process.platform` (must print `linux`).

## pi resolves to Windows

Symptom: the installer refuses with "pi on PATH is a WINDOWS binary"; the
doctor flags a Windows Pi.

Fix: ensure `~/.local/bin/pi` is the fmw shim link (created by
`bin/install.sh`) and that `~/.local/bin` precedes any Windows pi on PATH.

## tasks-axi not on PATH

Symptom: the completion gate closes scouts in `blocked:`; the pane cannot
resolve the `tasks-axi` command.

Fix: `bin/install.sh` installs and links it (`~/.local/npm-global/bin` →
`~/.local/bin`). Verify `command -v tasks-axi` inside the agent pane
(fmw arms the shims per-window; a window opened before the install may need
to be reopened).

## PowerShell/CMD interop not available

Symptom: `fmw doctor` reports `[FAIL] PowerShell interop` / `[FAIL] CMD
interop`.

Cause: a custom PATH that dropped the Windows directories.

Fix: ensure the WSL default Windows dirs are on PATH:

```bash
export PATH="/mnt/c/Windows/System32/WindowsPowerShell/v1.0:/mnt/c/Windows/System32:/mnt/c/Windows:$PATH"
```

## tmux does not inherit PATH

Symptom: new panes cannot find `pi`, `node` or `tasks-axi` even though the
login shell finds them.

Cause: tmux's global environment was captured before the PATH entries
existed, or a wrapper changed the PATH after the server started.

Fix: re-arm the shim PATH (fmw does this on `fmw task spawn`) and/or restart
the tmux server:

```bash
tmux kill-server        # closes ALL tmux sessions — do this with care
```

## Firstmate without state/ or data/

Symptom: `fm-send` fails with "state dir ... is missing"; the installer or
doctor reports a Firstmate home that lacks `state/`.

Fix: fmw creates `state/` and `data/` automatically on the first `fmw`
invocation (`fmw_ensure_dirs`). If a stale clone predates this, run any
`fmw task ...` command once or create them manually:

```bash
mkdir -p ~/firstmate/state ~/firstmate/data
```

## Watcher stale/down

Symptom: the spawn banner warns "WATCHER DOWN"; `fm-watch.sh` exited on a
stale window; no fresh beacon in `~/.local/.../state/.last-watcher-beat`.

Fix: drain the queue and re-arm (the watcher is a cycle by design):

```bash
bash ~/firstmate/bin/fm-wake-drain.sh
bash ~/firstmate/bin/fm-watch-arm.sh     # tracked process; NEVER shell &
```

## Task spawned but no window

Symptom: `fmw task status` shows `STATE=spawned`, `fm_window=no tmux
window`, `fm_state=unknown`.

Cause: the agent window/process was lost (killed, tmux/WSL restarted).

Remedy: fmw never invents `done`. Diagnose with `fmw task status`; if the
operative state is `unknown`, resolve with `fmw task abandon <id>` (explicit
authorization) then `fmw task teardown <id>`. If the state is not `unknown`
(a busy-state says `busy`), the agent may still be alive — investigate
before `--force`.

## Worktree clean but not eligible for teardown

Symptom: `fm_teardown_elegible=no` with a clean worktree.

Cause: eligibility requires `STATE=done` (agent finished, source-confirmed)
or `STATE=abandoned` (explicit operator authorization). `blocked`/`failed`
require review; `prepared`/`spawned` require resolution.

Fix: for a finished agent, re-run `fmw task status` so the source confirms
`done`; for an orphaned one, `fmw task abandon` then teardown.

## Sandbox or tests with leftovers

Symptom: `C:\FirstmateWorktrees\TestLab` exists, or stray files under
`config/projects/` / `profiles/` pointing at TestLab paths.

Cause: a test run was interrupted, or two test processes shared the sandbox.

Fix: the suite removes its sandbox on a clean run. Remove leftovers only if
they point at the sandbox:

```bash
rm -rf /mnt/c/FirstmateWorktrees/TestLab
# and any config/projects/*.conf / profiles/*.sh whose paths mention TestLab
```

## Partial installation

Symptom: the installer fails mid-way (e.g. node runtime missing, Firstmate
missing) — this is by design: it fails with the exact next command.

Fix: apply the printed command and re-run `bin/install.sh`; it is idempotent
and picks up where it stopped (installed parts are detected, not repeated).

## Re-running the installer safely

`bin/install.sh` is idempotent and non-destructive: no duplicate PATH
entries, no double links, `~/.bashrc` is backed up before any edit,
`--dry-run` changes nothing. Re-running after a partial or failed
installation is the supported recovery path.

## See also

- `docs/runbook.md` — full lifecycle, watcher, recovery after restarts
- `docs/rollback.md` — uninstall and rollback of every component
- `README.md` — installation and Quick Start
