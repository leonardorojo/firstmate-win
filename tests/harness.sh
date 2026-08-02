# tests/harness.sh — mini test runner for the fmw wrapper
#   t_begin <name> / t_ok / t_fail / t_assert_eq / t_assert_true / t_assert_false
#   t_summary at the end; exit != 0 on failures.

# wrapper bootstrap: the suites use the lib/ functions and the bin/fmw CLI
FMW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
for _lib in common config paths safety projects worktrees windows runtime; do
  . "$FMW_LIB_DIR/$_lib.sh"
done
unset _lib

# tmux isolation: each suite runs against its OWN socket; the user's real
# server (firstmate session, live agents) stays untouched. new-session /
# kill-server inside a suite only reach the isolated socket.
export TMUX_TMPDIR="/tmp/fmw-test-tmux"
mkdir -p "$TMUX_TMPDIR"

# invocation of the real CLI with the sandbox environment (exported variables)
fmw() { bash "$FMW_HOME/bin/fmw" "$@"; }

TESTS_RUN=0
TESTS_FAILED=0
TESTS_CURRENT=""

t_begin() { TESTS_CURRENT="$1"; echo "== $1 =="; }
t_ok()   { TESTS_RUN=$((TESTS_RUN+1)); echo "   ok: $1"; }
t_fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); echo "   FAIL: $1"; }

t_assert_eq() {
  if [ "$1" = "$2" ]; then t_ok "$3"; else t_fail "$3 (got '$1', want '$2')"; fi
}
t_assert_ne() {
  if [ "$1" != "$2" ]; then t_ok "$3"; else t_fail "$3 (both '$1')"; fi
}
t_assert_true() {
  if "$@" >/dev/null 2>&1; then t_ok "$*"; else t_fail "$* (expected success)"; fi
}
t_assert_false() {
  if "$@" >/dev/null 2>&1; then t_fail "$* (expected failure)"; else t_ok "$*"; fi
}
t_assert_file() {
  if [ -f "$1" ]; then t_ok "$2"; else t_fail "$2 (missing file: $1)"; fi
}

t_summary() {
  echo "== summary $TESTS_CURRENT: $TESTS_RUN tests, $TESTS_FAILED failures =="
  [ "$TESTS_FAILED" = 0 ]
}

# --- test sandbox ---------------------------------------------------------
# The whole sandbox lives under FMW_TESTLAB (default: /mnt/c/FirstmateWorktrees/
# TestLab, the agreed laboratory zone; override with FMW_TESTLAB). The tests
# never touch the real fmw state.

FMW_TESTLAB="${FMW_TESTLAB:-/mnt/c/FirstmateWorktrees/TestLab}"
FMW_SANDBOX="$FMW_TESTLAB/fmw-home"

# fmw_test_clean_sandbox — fail-closed preventive cleanup of the test sandbox.
# Deletes ONLY FMW_TESTLAB. Before deleting it verifies that the canonical
# path resolves EXACTLY to that path (basename TestLab + dirname
# /mnt/c/FirstmateWorktrees); no broad patterns: literal rm over the already
# verified path. Never touches other C:\FirstmateWorktrees folders.
fmw_test_clean_sandbox() {
  local root="/mnt/c/FirstmateWorktrees"
  local sandbox="$FMW_TESTLAB"
  [ -e "$sandbox" ] || return 0   # nothing to clean (not an error)
  local canon
  canon="$(readlink -f "$sandbox" 2>/dev/null)" || {
    echo "FATAL: could not resolve the canonical path of '$sandbox'; nothing deleted" >&2
    return 1
  }
  case "$canon" in
    "$root/TestLab") ;;
    *)
      echo "FATAL: '$sandbox' does not resolve to '$root/TestLab' (canonical: '$canon'); nothing deleted" >&2
      return 1
      ;;
  esac
  [ "$(basename "$canon")" = "TestLab" ] || { echo "FATAL: unexpected basename: $(basename "$canon")" >&2; return 1; }
  [ "$(dirname "$canon")" = "$root" ] || { echo "FATAL: unexpected dirname: $(dirname "$canon")" >&2; return 1; }
  rm -rf -- "$canon"
}

fmw_test_setup_sandbox() {
  fmw_test_clean_sandbox || return 1
  mkdir -p "$FMW_SANDBOX/state/tasks" "$FMW_SANDBOX/state/archive" "$FMW_SANDBOX/state/locks" \
           "$FMW_SANDBOX/config/projects" "$FMW_SANDBOX/profiles" \
    || { echo "   FATAL: could not create the sandbox ($FMW_SANDBOX)"; return 1; }
  export FMW_STATE="$FMW_SANDBOX/state"
  export FMW_TASKS_DIR="$FMW_SANDBOX/state/tasks"
  export FMW_ARCHIVE_DIR="$FMW_SANDBOX/state/archive"
  export FMW_LOCKS_DIR="$FMW_SANDBOX/state/locks"
  export FMW_PROJECTS_DIR="$FMW_SANDBOX/config/projects"
  export FMW_PROFILES_DIR="$FMW_SANDBOX/profiles"
  export FMW_FIRSTMATE_HOME="$FMW_SANDBOX/fake-firstmate"
  export FMW_SKIP_INTEROP_CHECK=1   # PowerShell interop not exercised in the sandbox
  export FMW_SKIP_RUNTIME_CHECK=1   # pi/pi-signed runtime: the sandbox does not install Pi (see runtime.test.sh)
  mkdir -p "$FMW_FIRSTMATE_HOME/state" "$FMW_FIRSTMATE_HOME/bin" \
    || { echo "   FATAL: could not create the fake Firstmate home"; return 1; }
  fmw_ensure_dirs
  # Isolation guard: every test-owned path MUST live inside the sandbox.
  # A broken setup (e.g. two test processes sharing the sandbox) must abort
  # here instead of silently writing test fakes over the REAL environment —
  # that corrupted ~/firstmate/bin/fm-crew-state.sh once (Sprint 7 incident).
  case "$FMW_FIRSTMATE_HOME" in
    "$FMW_SANDBOX"/*) ;;
    *)
      echo "   FATAL: FMW_FIRSTMATE_HOME ($FMW_FIRSTMATE_HOME) is OUTSIDE the sandbox ($FMW_SANDBOX); refusing to continue (test isolation broken)" >&2
      return 1
      ;;
  esac
}

# fmw_test_assert_sandboxed — hard guard for tests that write fakes into the
# Firstmate home: aborts unless every test-owned path is under the sandbox.
# Call it right before writing fake files if the setup could have failed.
fmw_test_assert_sandboxed() {
  case "$FMW_FIRSTMATE_HOME" in
    "$FMW_SANDBOX"/*) ;;
    *)
      echo "   FATAL: refusing to write test fakes outside the sandbox (FMW_FIRSTMATE_HOME=$FMW_FIRSTMATE_HOME)" >&2
      exit 1
      ;;
  esac
}

# fmw_test_make_repo <dir> — create a disposable git repo with 1 commit
fmw_test_make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "fmw-test@local"
  git -C "$dir" config user.name "fmw-test"
  printf 'base\n' > "$dir/base.txt"
  git -C "$dir" add base.txt
  git -C "$dir" commit -qm "base"
}

# fmw_test_make_profile <name> — profile stub in the sandbox
fmw_test_make_profile() {
  cat > "$FMW_PROFILES_DIR/$1.sh" <<EOF
fmw_profile_validate() { return 0; }
fmw_profile_build() { echo "profile-$1-build"; return 0; }
fmw_profile_test() { echo "profile-$1-test"; return 0; }
fmw_profile_open() { return 0; }
EOF
}

# fmw_test_cleanup — remove ONLY the test sandbox (own resources)
fmw_test_cleanup() {
  # remove test worktrees via git (fail-closed by design)
  local repo="$FMW_TESTLAB/repo"
  if [ -d "$repo" ]; then
    git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' \
      | while IFS= read -r wt; do
          [ "$wt" = "$repo" ] && continue
          git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
        done
    git -C "$repo" worktree prune 2>/dev/null || true
  fi
  rm -rf "$FMW_TESTLAB"
}
