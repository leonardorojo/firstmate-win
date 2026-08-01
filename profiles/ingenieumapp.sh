# profiles/ingenieumapp.sh — build/test/open profile for IngenieumApp (Windows/.NET)
#
# This is a reference profile for a real Windows/.NET repository. Every tool
# is Windows-only (invoked via WSL interop); Linux `dotnet build` is never
# used as evidence.
#
# BUILD FLOW (validated 2026-07-31 with .NET SDK 10.0.302; the repo README
# orders -p:Platform=x64, but that MISALIGNS restore (win-x64) and build
# (sln mapping to Any CPU -> win-x86) in the net48/UseWPF projects ->
# NETSDK1047; with "Any CPU" they stay aligned: 0 warnings, 0 errors):
#   Restore: nuget restore IngenieumApp.sln
#     (7 projects use legacy packages.config: IA.IU.ModelControls,
#      IA.UI.ComponentsUserDefinition, IA.UI.Rebars, IAppConnect, TeklaBase,
#      Testing, Viewer3D.Core.Tests; MSBuild/dotnet restore does NOT cover them)
#   Build:   dotnet build IngenieumApp.sln -c Debug -p:Platform="Any CPU"
#     (the solution defines "Debug|Any CPU" and "Debug|x64"; with x64 the SDK 10
#      demands net48/win-x86: Microsoft.NET.RuntimeIdentifierInference.targets:63)
#   Tests:   vstest.console over Testing\IA.Testing.NetFramework\
#            bin\Debug\net48\IA.Testing.NetFramework.dll (SDK-style, net48)
#   Deploy (post-build, NOT part of the build): TeklaConnect2025\DeployDebug.bat
#     (copies res\TeklaConnect2025.exe.config to bin\Debug\net48\)
#
# Environment overrides (used by the test suite):
#   INGENIEUMAPP_DOTNET_WIN  (default: C:\Program Files\dotnet\dotnet.exe)
#   INGENIEUMAPP_NUGET_WIN   (default: auto-detection of nuget.exe; "none" = force absence)
#   INGENIEUMAPP_VSTEST_WIN  (default: Visual Studio Community of the author
#                             machine — override per environment)
#   INGENIEUMAPP_CONFIG / INGENIEUMAPP_PLATFORM (default: Debug / "Any CPU")
#
# Contract: fmw_profile_validate / fmw_profile_build / fmw_profile_test /
#   fmw_profile_open (target: explorer|vscode|visual-studio)

INGENIEUMAPP_SLN_NAME="IngenieumApp.sln"
INGENIEUMAPP_DOTNET_WIN="${INGENIEUMAPP_DOTNET_WIN:-C:\Program Files\dotnet\dotnet.exe}"
INGENIEUMAPP_VSTEST_WIN="${INGENIEUMAPP_VSTEST_WIN:-C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\TestWindow\vstest.console.exe}"
INGENIEUMAPP_CONFIG="${INGENIEUMAPP_CONFIG:-Debug}"
INGENIEUMAPP_PLATFORM="${INGENIEUMAPP_PLATFORM:-Any CPU}"

# fmw_profile_nuget_exe — resolve nuget.exe (env override -> common locations
# -> PATH). Always returns a WSL path (runnable by bash); empty (rc=1) when it
# does not exist: the build flow then decides between "packages/ already
# restored" and a clean-checkout error.
fmw_profile_nuget_exe() {
  if [ "${INGENIEUMAPP_NUGET_WIN:-}" = "none" ]; then
    return 1
  fi
  if [ -n "${INGENIEUMAPP_NUGET_WIN:-}" ]; then
    local w
    w="$(fmw_path_to_wsl "$INGENIEUMAPP_NUGET_WIN" 2>/dev/null)" && [ -x "$w" ] && { echo "$w"; return 0; }
  fi
  local c
  for c in \
    "/mnt/c/ProgramData/chocolatey/bin/nuget.exe" \
    "/mnt/c/Program Files (x86)/NuGet/nuget.exe"; do
    [ -f "$c" ] && { echo "$c"; return 0; }
  done
  local found
  found="$(find /mnt/c/Users/*/AppData/Local/Microsoft/WinGet/Packages /mnt/c/Users/*/AppData/Local/Microsoft/WindowsApps -maxdepth 3 -iname 'nuget.exe' 2>/dev/null | head -1)"
  if [ -n "$found" ] && [ -f "$found" ]; then echo "$found"; return 0; fi
  local inpath
  inpath="$(command -v nuget 2>/dev/null || true)"
  if [ -n "$inpath" ]; then echo "$inpath"; return 0; fi
  return 1
}

# fmw_profile_validate — dotnet.exe present and sln reachable; warns (does
# NOT fail) when nuget.exe is missing, because packages/ may already be
# restored
fmw_profile_validate() {
  local dotnet_wsl sln_wsl
  dotnet_wsl="$(fmw_path_to_wsl "$INGENIEUMAPP_DOTNET_WIN")"
  [ -f "$dotnet_wsl" ] \
    || { fmw_log "profile ingenieumapp: dotnet.exe not found: $INGENIEUMAPP_DOTNET_WIN"; return 1; }
  sln_wsl="$FMW_PROJECT_WSL_PATH/$INGENIEUMAPP_SLN_NAME"
  [ -f "$sln_wsl" ] \
    || { fmw_log "profile ingenieumapp: missing $sln_wsl"; return 1; }
  if ! fmw_profile_nuget_exe >/dev/null 2>&1; then
    fmw_log "profile ingenieumapp: warning: nuget.exe not detected; packages.config restore requires the NuGet CLI or Visual Studio (see the repo README)"
  fi
  return 0
}

# fmw_profile_target_dir_win — task worktree when it exists; otherwise the main checkout
fmw_profile_target_dir_win() {
  if [ -n "${FMW_TASK_WORKTREE_WINDOWS:-}" ] && [ -d "$(fmw_path_to_wsl "$FMW_TASK_WORKTREE_WINDOWS")" ]; then
    echo "$FMW_TASK_WORKTREE_WINDOWS"
  else
    echo "$FMW_PROJECT_WINDOWS_PATH"
  fi
}

# fmw_profile_build — reproduces the README flow (with the platform fix
# documented above: "Any CPU", not x64):
#   1) nuget restore <sln>                       (packages.config + PackageReference)
#   2) dotnet build <sln> -c <cfg> -p:Platform="Any CPU"
# When nuget.exe is missing: skips restore only if packages/ already exists
# (the usual machine state); otherwise fails with an actionable message (a
# clean checkout without the NuGet CLI cannot restore the 7 legacy projects).
fmw_profile_build() {
  fmw_profile_validate || return 1
  local dir_win sln_win dotnet_wsl nug rc
  dir_win="$(fmw_profile_target_dir_win)"
  sln_win="$dir_win\\$INGENIEUMAPP_SLN_NAME"

  nug="$(fmw_profile_nuget_exe)"
  if [ -n "$nug" ]; then
    fmw_log "profile ingenieumapp: nuget restore $sln_win"
    "$nug" restore "$sln_win"
    rc=$?
    [ "$rc" = 0 ] || { fmw_log "profile ingenieumapp: restore failed (rc=$rc)"; return "$rc"; }
  else
    local packages_wsl
    packages_wsl="$(fmw_path_to_wsl "$dir_win\\packages")"
    if [ -d "$packages_wsl" ] && [ -n "$(find "$packages_wsl" -mindepth 1 -maxdepth 1 2>/dev/null | head -1)" ]; then
      fmw_log "profile ingenieumapp: nuget.exe not detected; restore skipped (packages/ already restored at $dir_win\\packages)"
    else
      fmw_log "profile ingenieumapp: ERROR: clean checkout without nuget.exe and without packages/ — install the NuGet CLI (winget install Microsoft.NuGet) or restore from Visual Studio (repo README)"
      return 2
    fi
  fi

  dotnet_wsl="$(fmw_path_to_wsl "$INGENIEUMAPP_DOTNET_WIN")"
  fmw_log "profile ingenieumapp: dotnet build $sln_win -c $INGENIEUMAPP_CONFIG -p:Platform=$INGENIEUMAPP_PLATFORM"
  "$dotnet_wsl" build "$sln_win" -c "$INGENIEUMAPP_CONFIG" "-p:Platform=$INGENIEUMAPP_PLATFORM"
  rc=$?
  [ "$rc" = 0 ] || fmw_log "profile ingenieumapp: build failed (rc=$rc)"
  return "$rc"
}

# fmw_profile_test — build + vstest over the test assembly (when it compiled)
fmw_profile_test() {
  fmw_profile_validate || return 1
  fmw_profile_build || return $?
  local vstest_wsl dir_win testdll_win testdll_wsl
  vstest_wsl="$(fmw_path_to_wsl "$INGENIEUMAPP_VSTEST_WIN")"
  dir_win="$(fmw_profile_target_dir_win)"
  testdll_win="$dir_win\\Testing\\IA.Testing.NetFramework\\bin\\$INGENIEUMAPP_CONFIG\\net48\\IA.Testing.NetFramework.dll"
  testdll_wsl="$(fmw_path_to_wsl "$testdll_win")"
  if [ -f "$testdll_wsl" ]; then
    fmw_log "profile ingenieumapp: vstest $testdll_win"
    "$vstest_wsl" "$testdll_win"
    rc=$?
    [ "$rc" = 0 ] || fmw_log "profile ingenieumapp: vstest failed (rc=$rc); if the Actipro BarCode assembly is missing, restore packages.config (README: Testing may fail before running)"
    return "$rc"
  fi
  fmw_log "profile ingenieumapp: no test assembly at $testdll_win; build OK, tests not run"
  return 0
}

# fmw_profile_open <target> — open the worktree/project in Windows apps
fmw_profile_open() {
  local target="${1:-explorer}"
  local dir_win
  dir_win="$(fmw_profile_target_dir_win)"
  case "$target" in
    explorer)
      fmw_open "$(fmw_path_to_wsl "$dir_win")" explorer ;;
    vscode)
      fmw_open "$(fmw_path_to_wsl "$dir_win")" vscode ;;
    visual-studio)
      local sln_win="$dir_win\\$INGENIEUMAPP_SLN_NAME"
      local devenv_wsl=""
      for d in "/mnt/c/Program Files/Microsoft Visual Studio/18"/*/Common7/IDE/devenv.exe \
               "/mnt/c/Program Files/Microsoft Visual Studio/2022"/*/Common7/IDE/devenv.exe \
               "/mnt/c/Program Files (x86)/Microsoft Visual Studio/2022"/*/Common7/IDE/devenv.exe; do
        [ -f "$d" ] && { devenv_wsl="$d"; break; }
      done
      [ -n "$devenv_wsl" ] || { fmw_log "profile ingenieumapp: devenv.exe not found"; return 1; }
      fmw_log "profile ingenieumapp: opening $sln_win in Visual Studio"
      powershell.exe -NoProfile -NonInteractive \
        -Command "Start-Process -FilePath '$(fmw_path_to_windows "$devenv_wsl")' -ArgumentList '$sln_win'" >/dev/null 2>&1
      echo "visual-studio: $sln_win" ;;
    *) fmw_die "unknown target: $target (explorer|vscode|visual-studio)";;
  esac
}
