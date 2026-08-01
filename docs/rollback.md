# Rollback — firstmate-win (fmw)

## What can be reverted and how

### 1. Active task worktrees

```bash
fmw task list                     # inventory
fmw task teardown <id>            # fail-closed; keeps the branch
# firstmate/<id> branches remain in the repo (never deleted without
# authorization)
```

### 2. fmw metadata

```bash
# tasks: state/tasks/<id>.conf (active) and state/archive/<id>.conf (retired)
# projects: config/projects/*.conf
# delete a record (fmw-owned resources only):
rm -f ~/firstmate-win/state/tasks/<id>.conf
```

### 3. Changes in real repositories

fmw **never** modifies main checkouts: it only creates `firstmate/<task>`
branches and worktrees under `C:\FirstmateWorktrees`. To clean up:

```bash
git -C /mnt/c/<repo> worktree list                 # see the worktrees
git -C /mnt/c/<repo> worktree remove <path>        # only if it is fmw's
git -C /mnt/c/<repo> branch -D firstmate/<task>    # ONLY with authorization
```

### 4. tmux global PATH (shim)

`fmw task spawn` prepends `~/firstmate-win/bin/shims` to the tmux global PATH
(affects only NEW windows). To revert:

```bash
tmux set-environment -g PATH "<the original PATH without the shim>"
# or: tmux kill-server   (closes ALL tmux sessions)
```

### 5. Reverting to "no fmw"

1. Teardown of every task (`fmw task list` + `fmw task teardown`).
2. Remove the shim from the tmux global PATH (above).
3. Remove the wrapper and its roots:
   `rm -rf ~/firstmate-win` (symlink), `C:\Users\<user>\firstmate-win`,
   `C:\FirstmateWorktrees` (only if no worktrees are wanted).
4. The repositories and Firstmate (`~/firstmate`) stay intact.

### 6. tasks-axi and its skill

```bash
# 1. remove the pane-PATH symlink
rm -f ~/.local/bin/tasks-axi
# 2. uninstall the CLI (Linux npm; NO sudo; does not touch the system)
npm uninstall -g tasks-axi
# 3. remove the global skill (installed via the skills CLI)
rm -rf ~/.agents/skills/tasks-axi
# 4. the gate will close scouts in blocked: again (previous behavior).
```

### 7. Metadata reconciliation

`fmw task status` persists the terminal state (`done|blocked|failed`) in
`state/tasks/<id>.conf` when `fm-crew-state.sh` confirms it. Reverting is
safe because reconciliation is idempotent and re-evaluable:

```bash
# see the persisted state:
grep '^STATE=' ~/firstmate-win/state/tasks/<id>.conf
# to go back to a previous lifecycle (e.g. to reopen the task), do NOT edit
# the conf by hand — re-evaluate the source:
bash ~/firstmate-win/bin/fmw task status <id>
```

Notes:

- Changing `STATE` by hand breaks the contract (atomic write with allowlist);
  if a conf is corrupted, the status fails cleanly with "corrupt task config"
  and does NOT reconcile (fail-closed).
- `blocked` → `done` is overwritten only when the source changes (e.g. after
  steering); never edit the conf.
- An archived teardown (`state/archive/<id>.conf`, `STATE=torn-down`) is not
  reactivated: the `firstmate/<id>` branch stays in the repo and the task can
  be reopened with `fmw task prepare` (new conf) if needed.

## Guarantees

- No fmw command touches a repository's main checkout.
- No teardown deletes resources without confirmed ownership (conf + git).
- No commit/push/PR; branches are disposable.
