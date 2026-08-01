## Summary

<!-- One paragraph: what and why. -->

## Behavior change

<!-- What changes for the user? New commands, changed output, removed flags? -->

## Evidence

<!-- Required: output of the full test suite, ideally twice:

for f in bin/fmw bin/shims/* lib/*.sh profiles/*.sh tests/*.sh; do bash -n "$f" || exit 1; done
bash tests/run-all.sh
bash tests/run-all.sh
-->

## Safety

<!-- If this touches teardown, worktree removal or path validation, describe
the fail-closed guards involved and how they were verified. -->

## Scope

- [ ] No changes to Firstmate upstream
- [ ] Tests added/updated for the change
- [ ] Documentation updated (README/docs/AGENTS) if user-facing
