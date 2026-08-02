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

# fmw_win_ps_quote <value> — quote one literal for a PowerShell single-quoted string.
# This is data quoting only; it never turns a caller-provided string into a shell
# command or invokes eval.
fmw_win_ps_quote() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

# fmw_win_resolve_executable <name> — resolve a configured or PATH Windows tool.
# Returns a WSL-runnable path and never scans the filesystem.
fmw_win_resolve_executable() {
  local requested="$1" candidate=""
  case "$requested" in
    dotnet.exe|dotnet) candidate="${FMW_CFG_WINDOWS_DOTNET:-}" ;;
    msbuild.exe|MSBuild.exe|msbuild) candidate="${FMW_CFG_WINDOWS_MSBUILD:-}" ;;
    powershell.exe|pwsh.exe|powershell) candidate="$(command -v powershell.exe 2>/dev/null || command -v pwsh.exe 2>/dev/null || true)" ;;
  esac
  [ -n "$candidate" ] || candidate="$requested"
  case "$candidate" in
    [A-Za-z]:[\\/]*|\\\\*) candidate="$(fmw_path_to_wsl "$candidate" 2>/dev/null || true)" ;;
  esac
  if [ "${candidate#/}" != "$candidate" ]; then
    [ -x "$candidate" ] || { fmw_log "Windows executable is not runnable: $candidate"; return 1; }
    printf '%s\n' "$candidate"
    return 0
  fi
  candidate="$(command -v "$candidate" 2>/dev/null || true)"
  [ -n "$candidate" ] || { fmw_log "Windows executable not found: $requested"; return 1; }
  printf '%s\n' "$candidate"
}

# fmw_win_validate_cwd <wsl-path> — validate and convert a Windows-backed cwd.
# The conversion is performed even for direct execution so the report and the
# Windows backend share one explicit path contract.
fmw_win_validate_cwd() {
  local cwd="$1" win
  fmw_path_is_absolute_wsl "$cwd" || { fmw_log "cwd must be an absolute WSL path: $cwd"; return 1; }
  [ -d "$cwd" ] || { fmw_log "cwd does not exist or is not a directory: $cwd"; return 1; }
  fmw_path_is_windows_mounted "$cwd" || { fmw_log "cwd must be on a Windows-mounted path (/mnt/<drive>): $cwd"; return 1; }
  fmw_path_reject_native_wsl "$cwd" >/dev/null || return 1
  win="$(fmw_path_to_windows "$cwd" 2>/dev/null || true)"
  [ -n "$win" ] || { fmw_log "could not convert cwd with wslpath -w: $cwd"; return 1; }
  FMW_WIN_CWD_WSL="$cwd"
  FMW_WIN_CWD_WINDOWS="$win"
  export FMW_WIN_CWD_WSL FMW_WIN_CWD_WINDOWS
}

# fmw_win_exec <cwd> <backend> <report:0|1> <executable> <args...>
# Execute one Windows binary with individual arguments. Direct execution keeps
# stdout/stderr untouched and runs from the WSL cwd; WSL interop supplies the
# corresponding Windows cwd. The explicit PowerShell backend uses literal
# single-quoted data and an argument array, never a concatenated command line.
fmw_win_exec() {
  local cwd="$1" backend="$2" report="$3" requested="$4"
  shift 4
  local resolved rc script ps_bin arg
  resolved="$(fmw_win_resolve_executable "$requested")" || return 1
  FMW_WIN_EXECUTABLE_WSL="$resolved"
  FMW_WIN_EXECUTABLE_WINDOWS="$(fmw_path_to_windows "$resolved" 2>/dev/null || printf '%s' "$resolved")"
  export FMW_WIN_EXECUTABLE_WSL FMW_WIN_EXECUTABLE_WINDOWS
  if [ "$report" = 1 ]; then
    printf 'fmw-report cwd-wsl=%q cwd-windows=%q executable=%q backend=%s\n' \
      "$FMW_WIN_CWD_WSL" "$FMW_WIN_CWD_WINDOWS" "$resolved" "$backend" >&2
  fi
  case "$backend" in
    direct)
      (
        cd -- "$cwd" || exit 1
        "$resolved" "$@"
      )
      rc=$?
      if [ "$report" = 1 ]; then printf 'fmw-report exit-code=%s\n' "$rc" >&2; fi
      return "$rc"
      ;;
    powershell)
      ps_bin="$(fmw_win_resolve_executable powershell.exe)" || return 1
      script="Set-Location -LiteralPath $(fmw_win_ps_quote "$FMW_WIN_CWD_WINDOWS")"$'\n'
      script+='$args = @('$'\n'
      for arg in "$@"; do script+="  $(fmw_win_ps_quote "$arg")"$'\n'; done
      script+=')'$'\n'
      script+="& $(fmw_win_ps_quote "$FMW_WIN_EXECUTABLE_WINDOWS") @args"$'\n'
      script+='exit $LASTEXITCODE'$'\n'
      "$ps_bin" -NoProfile -NonInteractive -Command "$script"
      rc=$?
      if [ "$report" = 1 ]; then printf 'fmw-report exit-code=%s\n' "$rc" >&2; fi
      return "$rc"
      ;;
    *) fmw_log "unknown Windows execution backend: $backend"; return 2 ;;
  esac
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
