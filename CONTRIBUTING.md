# Contributing to firstmate-win

Thanks for your interest! This project is a small, fail-closed compatibility
wrapper — the bar for changes is deliberately high.

## Ground rules

- **Do not modify Firstmate upstream.** All integration goes through the
  official scripts and the delegating shims.
- **Fail-closed wins.** If a change makes a destructive path (teardown,
  worktree removal) less strict, it will be rejected.
- **No unnecessary refactoring.** Prefer minimal, reversible changes.
- **English only** for code, comments, messages and documentation.

## Development setup

- WSL2 (Ubuntu) with `bash`, `git`, `tmux`, `flock`, `wslpath`.
- The test suite runs in a disposable sandbox (`FMW_TESTLAB`, default
  `/mnt/c/FirstmateWorktrees/TestLab`) against an isolated tmux socket. It
  never touches a real tmux server or real fmw state.

## Making changes

1. Open an issue describing the problem (or pick one).
2. Fork the repository and create a feature branch.
3. Make the change with tests. The wrapper ships 8 suites; add or extend a
   suite for the affected `lib/` module.
4. Verify:

   ```bash
   for f in bin/fmw bin/shims/* lib/*.sh profiles/*.sh tests/*.sh; do bash -n "$f" || exit 1; done
   bash tests/run-all.sh            # all suites, twice (idempotency)
   bash tests/run-all.sh            # again — the suite must be stable
   ```

5. Open a pull request describing the change, the evidence (test output) and
   any behavior changes.

## What counts as a good change

- A bug fix with a regression test (the repo history contains real bugs that
  were fixed exactly this way: `FM_HOME` export in `fmw task send`, the
  silent `rc=1` on missing meta keys, the shim `FMW_HOME` resolution through
  the symlink, the tmux `TMUX_PANE` target for non-active windows).
- A portability improvement that removes machine-specific assumptions.
- Documentation corrections that stay within the documented scope.

## What usually gets rejected

- Changes that touch Firstmate upstream.
- New features without tests.
- Broad refactors that rewrite modules "for style".
- Claims of compatibility with environments that have not been validated.

## Code of conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
