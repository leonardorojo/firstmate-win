# Security Policy

## Scope

This repository is a compatibility wrapper around
[Firstmate](https://github.com/kunchenguid/firstmate). Security issues in
Firstmate itself belong to the upstream project.

In scope for this repository:

- Fail-closed bypasses (teardown, worktree removal, path guards)
- Path traversal / native-WSL escape in task IDs, project paths or worktree
  targets
- Config injection (allowlist parser, atomic writes)
- Secret handling in the wrapper's own code and documentation

## Reporting a vulnerability

Do **not** open a public issue for security problems. Report privately:

- **GitHub**: use the repository's private vulnerability reporting (Security
  → Report a vulnerability), or
- **Email**: see the author profile on GitHub for a contact address.

Please include:

- Affected version / commit
- Reproduction steps (commands and expected vs actual behavior)
- Impact assessment if known

You will receive an acknowledgment within 5 business days, and a fix plan as
soon as the issue is triaged. We ask for coordinated disclosure: give the
maintainer a reasonable window before publicizing.

## Supported versions

This project has no tagged releases yet. Fixes land on `main`; please verify
against the latest `main` commit before reporting.

## Security-relevant design notes

- Worktree paths are validated against `/mnt/<drive>/` roots; native WSL
  paths are rejected.
- Task IDs are constrained to `^[a-z0-9][a-z0-9-]{0,62}$`.
- Config files are parsed against a strict allowlist; `eval`/`source` of
  external files is never used.
- Teardown requires multi-factor ownership confirmation (conf + git
  porcelain + root + branch + basename) and refuses while an agent window
  exists or the worktree is dirty (unless `--force` is explicit).
- Secrets are never stored by the wrapper; credentials belong to the
  underlying tools (git, Firstmate, GitHub CLI).
