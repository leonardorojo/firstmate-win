# lib/common.sh — base utilities for the firstmate-win wrapper (fmw)
#
# Runtime: WSL (bash). This wrapper adapts the WSL/Windows boundary for
# Firstmate: repositories and worktrees ALWAYS live under /mnt/<drive>/.
#
# Principles:
#   - small and composable (an adaptation layer, not an orchestrator)
#   - fail-closed on anything destructive
#   - WSL git is the sole owner of the worktree lifecycle

FMW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FMW_HOME="$(cd "$FMW_LIB_DIR/.." && pwd)"

# --- state directories (overridable for tests) ---
FMW_STATE="${FMW_STATE:-$FMW_HOME/state}"
FMW_TASKS_DIR="${FMW_TASKS_DIR:-$FMW_STATE/tasks}"
FMW_ARCHIVE_DIR="${FMW_ARCHIVE_DIR:-$FMW_STATE/archive}"
FMW_LOCKS_DIR="${FMW_LOCKS_DIR:-$FMW_STATE/locks}"
FMW_PROJECTS_DIR="${FMW_PROJECTS_DIR:-$FMW_HOME/config/projects}"
FMW_PROFILES_DIR="${FMW_PROFILES_DIR:-$FMW_HOME/profiles}"
FMW_SHIMS_DIR="${FMW_SHIMS_DIR:-$FMW_HOME/bin/shims}"

# Firstmate home (the cloned installation; defaults to ~/firstmate)
FMW_FIRSTMATE_HOME="${FMW_FIRSTMATE_HOME:-$HOME/firstmate}"

FMW_VERSION="0.1.0"
FMW_ROOT_REQUIRED="/mnt/"          # every repo/worktree must live under /mnt/<drive>/

# --- log / error ---
fmw_log() { printf 'fmw: %s\n' "$*" >&2; }
fmw_die() { fmw_log "ERROR: $*"; exit 1; }

# fmw_need <cmd...> — require binaries to be present
fmw_need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || fmw_die "requires '$c' on PATH (WSL runtime)"
  done
}

# fmw_ensure_dirs — create the wrapper state structure
fmw_ensure_dirs() {
  mkdir -p "$FMW_TASKS_DIR" "$FMW_ARCHIVE_DIR" "$FMW_LOCKS_DIR" "$FMW_PROJECTS_DIR" \
    || fmw_die "could not create fmw state directories"
  # the Firstmate upstream does not create its state/data dirs on a fresh
  # clone; fmw owns the integration contract, so it ensures them
  mkdir -p "$FMW_FIRSTMATE_HOME/state" "$FMW_FIRSTMATE_HOME/data" \
    || fmw_die "could not create Firstmate state/data directories ($FMW_FIRSTMATE_HOME)"
}

# fmw_is_inside_wsl — detect the WSL runtime (wslpath is the canonical probe)
fmw_is_inside_wsl() { command -v wslpath >/dev/null 2>&1; }

# fmw_now_utc — ISO-8601 UTC timestamp for metadata
fmw_now_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# fmw_yesno <question> — yes/no prompt (interactive only)
fmw_yesno() {
  local resp
  printf 'fmw: %s [y/N] ' "$1" >&2
  read -r resp || return 1
  [[ "$resp" == [yY]* ]]
}
