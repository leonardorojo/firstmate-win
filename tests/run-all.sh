# tests/run-all.sh — runner for the fmw test suites (runtime: WSL)
#
#   bash tests/run-all.sh                  -> all suites
#   bash tests/run-all.sh paths.test.sh    -> specific suite(s)
#
# The test sandbox lives in FMW_TESTLAB (default /mnt/c/FirstmateWorktrees/
# TestLab, the agreed laboratory zone). At the end ONLY that sandbox is
# cleaned (resources created by this task).

set -uo pipefail
cd "$(dirname "$0")" || exit 1

# bootstrap the wrapper + harness (the suites use lib/ and the CLI bin/fmw)
. ./harness.sh

# preventive fail-closed sandbox cleanup: guarantees idempotency between
# runs, even if a previous run was interrupted or a suite ran in isolation
# (only touches FMW_TESTLAB, verified)
fmw_test_clean_sandbox || { echo "FATAL: could not clean the sandbox; aborting" >&2; exit 1; }

suites=("$@")
[ "${#suites[@]}" -gt 0 ] || suites=(paths.test.sh project-registry.test.sh portable-config.test.sh captain-operations.test.sh worktree-safety.test.sh firstmate-adapter.test.sh fase6-recovery.test.sh profile-ingenieumapp.test.sh runtime.test.sh reconcile.test.sh multirepo.test.sh resilience.test.sh abandon.test.sh install.test.sh crewstate-recovery.test.sh)

total_fail=0
for suite in "${suites[@]}"; do
  echo
  echo "############ $suite ############"
  bash "$suite" || total_fail=1
done

# final sandbox cleanup (only the tests' own resources)
echo
echo "############ cleanup ############"
fmw_test_cleanup
echo "test sandbox removed: $FMW_TESTLAB"

echo
if [ "$total_fail" = 0 ]; then
  echo "ALL SUITES OK"
else
  echo "SOME SUITES FAILED"
  exit 1
fi
