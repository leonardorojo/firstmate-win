---
name: Bug report
about: Report a reproducible problem with firstmate-win
title: "[bug] "
labels: bug
assignees: ''
---

## Environment

- Windows version: (e.g. Windows 11 23H2)
- WSL distro + version: (e.g. Ubuntu 22.04, WSL2)
- fmw commit: (output of `git rev-parse HEAD` in the wrapper)
- Firstmate version: (e.g. commit or release of kunchenguid/firstmate)
- Agent harness: (pi version, etc.)

## Description

What happened, and what did you expect to happen?

## Reproduction steps

1. ...
2. ...
3. ...

## Evidence

- `fmw doctor` output
- The failing command and its full output (stdout + stderr)
- `git worktree list` of the affected repository
- Any relevant state: `state/tasks/<id>.conf`, `~/firstmate/state/<id>.status`

## Safety note

Did the failure involve teardown, worktree removal or path validation? If so,
please describe the exact command and the guard that should have caught it.
