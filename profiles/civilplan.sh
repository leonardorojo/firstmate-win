# profiles/civilplan.sh — build/test/open profile for CivilPlan
#
# Profile contract (PGM §Profiles): expose
#   fmw_profile_validate / fmw_profile_build / fmw_profile_test / fmw_profile_open
#
# Context available when invoked from a registered worktree:
#   FMW_TASK_ID, FMW_TASK_WORKTREE_WSL, FMW_TASK_WORKTREE_WINDOWS
#   FMW_PROJECT_WSL_PATH, FMW_PROJECT_WINDOWS_PATH
#
# Note: this profile is a reference STUB. It is completed after auditing the
# CivilPlan solution (MSBuild, Tekla, UI). Stubs fail loudly for now.

fmw_profile_validate() {
  local root="${FMW_TASK_WORKTREE_WSL:-$FMW_PROJECT_WSL_PATH}"
  [ -d "$root" ] || return 1
  return 0
}

fmw_profile_build() {
  fmw_log "profile civilplan: build not implemented yet"
  return 2
}

fmw_profile_test() {
  fmw_log "profile civilplan: test not implemented yet"
  return 2
}

fmw_profile_open() {
  fmw_log "profile civilplan: open not implemented yet"
  return 2
}
