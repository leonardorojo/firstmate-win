# lib/windows.sh — running Windows tools from WSL
#
# Contract: propagate stdout/stderr and return EXACTLY the Windows process
# exit code. Never use Linux `dotnet build` as build evidence unless the
# project is explicitly cross-platform.

# fmw_exec_powershell <script...> — run native PowerShell (Windows)
fmw_exec_powershell() {
  fmw_need powershell.exe
  local rc
  powershell.exe -NoProfile -NonInteractive -Command "$@"
  rc=$?
  return "$rc"
}

# fmw_exec_cmd <command...> — run native CMD (Windows)
fmw_exec_cmd() {
  fmw_need cmd.exe
  local rc
  cmd.exe /d /c "$*"
  rc=$?
  return "$rc"
}

# fmw_profile_load <project-name> — load the project config and its profile
#   Exports FMW_PROJECT_* and (when a task is present) FMW_TASK_* as profile context.
fmw_profile_load() {
  local project="$1" task_id="${2:-}" pconf="$FMW_PROJECTS_DIR/$1.conf" profile
  [ -f "$pconf" ] || fmw_die "project not registered: $project"
  fmw_conf_load "$pconf" "${FMW_PROJECT_CONF_KEYS[@]}" || fmw_die "corrupt project config: $pconf"
  profile="$FMW_PROFILES_DIR/$PROJECT_PROFILE.sh"
  [ -f "$profile" ] || fmw_die "profile not found: $profile"
  export FMW_PROJECT_NAME="$PROJECT_NAME"
  export FMW_PROJECT_WSL_PATH="$PROJECT_WSL_PATH"
  export FMW_PROJECT_WINDOWS_PATH="$PROJECT_WINDOWS_PATH"
  if [ -n "$task_id" ]; then
    fmw_task_load "$task_id" || fmw_die "task not registered: $task_id"
    export FMW_TASK_ID="$task_id"
    export FMW_TASK_WORKTREE_WSL="$WORKTREE_WSL_PATH"
    export FMW_TASK_WORKTREE_WINDOWS="$WORKTREE_WINDOWS_PATH"
  else
    unset FMW_TASK_ID FMW_TASK_WORKTREE_WSL FMW_TASK_WORKTREE_WINDOWS 2>/dev/null || true
  fi
  . "$profile"
}

# fmw_build [--task <id>] — authoritative Windows build via profile
fmw_build() {
  local task_id="" project
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) task_id="$2"; shift 2 ;;
      *) fmw_die "unknown argument: $1";;
    esac
  done
  if [ -n "$task_id" ]; then
    fmw_task_load "$task_id" || return 1
    project="$PROJECT_NAME"
  else
    project="$(fmw_project_resolve "")"
  fi
  fmw_profile_load "$project" "$task_id"
  fmw_profile_build
}

# fmw_test [--task <id>] — Windows tests via profile (same contract as build)
fmw_test() {
  local task_id="" project
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) task_id="$2"; shift 2 ;;
      *) fmw_die "unknown argument: $1";;
    esac
  done
  if [ -n "$task_id" ]; then
    fmw_task_load "$task_id" || return 1
    project="$PROJECT_NAME"
  else
    project="$(fmw_project_resolve "")"
  fi
  fmw_profile_load "$project" "$task_id"
  fmw_profile_test
}

# fmw_open <wsl-path> <target> — open a worktree/path in Windows apps
#   target: explorer | vscode | visual-studio
fmw_open() {
  local path="$1" target="$2"
  local win
  win="$(fmw_path_to_windows "$path")" || fmw_die "could not convert: $path"
  case "$target" in
    explorer)
      explorer.exe "$win" >/dev/null 2>&1
      echo "explorer: $win"
      ;;
    vscode)
      if command -v code.exe >/dev/null 2>&1; then
        code.exe "$win" >/dev/null 2>&1
        echo "vscode: $win"
      else
        fmw_die "code.exe not found on PATH (is VS Code installed?)"
      fi
      ;;
    visual-studio)
      local devenv=""
      for d in "/mnt/c/Program Files/Microsoft Visual Studio/18"/*/Common7/IDE/devenv.exe \
               "/mnt/c/Program Files/Microsoft Visual Studio/2022"/*/Common7/IDE/devenv.exe \
               "/mnt/c/Program Files (x86)/Microsoft Visual Studio/2022"/*/Common7/IDE/devenv.exe; do
        [ -f "$d" ] && { devenv="$d"; break; }
      done
      [ -n "$devenv" ] || fmw_die "devenv.exe not found (Visual Studio 18/2022?)"
      powershell.exe -NoProfile -NonInteractive -Command "Start-Process -FilePath '$(fmw_path_to_windows "$devenv")' -ArgumentList '$win'" >/dev/null 2>&1
      echo "visual-studio: $win"
      ;;
    *) fmw_die "unknown target: $target (explorer|vscode|visual-studio)";;
  esac
}
