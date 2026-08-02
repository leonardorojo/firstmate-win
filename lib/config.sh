# lib/config.sh — shell-safe configuration loading/writing (.conf)
#
# Security rules:
#   - Never eval or source external files.
#   - Files are parsed line by line against an allowlist of keys.
#   - Only files created by the wrapper are loaded (projects and tasks).
#   - Atomic writes: temp file in the same directory + mv.

# --- allowlists (keys accepted per artifact type) ---
FMW_PROJECT_CONF_KEYS=(
  PROJECT_NAME PROJECT_WINDOWS_PATH PROJECT_WSL_PATH
  PROJECT_WORKTREE_WINDOWS_ROOT PROJECT_WORKTREE_WSL_ROOT
  PROJECT_PROFILE REGISTERED_AT
)
FMW_TASK_CONF_KEYS=(
  TASK_ID PROJECT_NAME
  REPOSITORY_WSL_PATH REPOSITORY_WINDOWS_PATH
  WORKTREE_WSL_PATH WORKTREE_WINDOWS_PATH WORKTREE_ROOT
  BRANCH BASE_REF CREATED_AT CREATED_BY_FMW
  FIRSTMATE_TASK_ID FIRSTMATE_BACKEND FIRSTMATE_ENDPOINT
  STATE ARCHIVED_AT ABANDONED_AT ABANDON_REASON
)

# fmw_conf_load <file> <allowlist...>
#   Load key=value pairs into environment variables of the current shell.
#   Rejects keys outside the allowlist, invalid lines and missing files.
fmw_conf_load() {
  local file="$1"; shift
  local -a allowed=("$@")
  local line key val ok k
  [ -f "$file" ] || { fmw_log "config not found: $file"; return 1; }
  while IFS= read -r line; do
    line="${line%%#*}"                                   # comment
    line="${line%\"${line##*[![:space:]]}\"}"              # rtrim
    [ -z "$line" ] && continue
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
      val="${val#\'}"; val="${val%\'}"                   # strip single quotes
      ok=0
      for k in "${allowed[@]}"; do
        [ "$k" = "$key" ] && { ok=1; break; }
      done
      [ "$ok" = 1 ] || { fmw_log "key not allowed in $file: $key"; return 1; }
      printf -v "$key" '%s' "$val"
    else
      fmw_log "invalid line in $file: $line"
      return 1
    fi
  done < "$file"
  return 0
}

# fmw_conf_write_atomic <file> <key=value...>
#   Write a .conf file atomically (temp + mv).
fmw_conf_write_atomic() {
  local file="$1"; shift
  local dir tmp kv
  dir="$(dirname "$file")"; mkdir -p "$dir" || return 1
  tmp="$dir/.$(basename "$file").$$.tmp"
  : > "$tmp" || return 1
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$tmp" || { rm -f "$tmp"; return 1; }
  done
  mv -f "$tmp" "$file"
  return 0
}

# fmw_conf_value <file> <KEY> — read a single key WITHOUT mutating the shell.
#   Minimal read-only parser (grep + cut + strip quotes). Unlike
#   fmw_conf_load it never sets shell variables, so it is safe to call in
#   loops over several configs (fmw_conf_load in a loop would leave the
#   shell variables of the LAST config behind — a cross-project leak).
fmw_conf_value() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "'"
}

# fmw_conf_quote <value> — quote a value for .conf (single quotes)
fmw_conf_quote() { printf "'%s'" "$1"; }

# Installation configuration is parsed by the same allowlisted .conf parser.
# It is deliberately separate from project/task state while sharing the parser,
# atomic writer, and rejection rules above.
FMW_PORTABLE_CONFIG_KEYS=(
  FIRSTMATE_ROOT FM_HOME FMW_REPOS_ROOT FMW_WORKTREES_ROOT
  TREEHOUSE_BIN WINDOWS_DOTNET WINDOWS_MSBUILD
)

fmw_config_default_file() {
  printf '%s\n' "${FMW_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/firstmate-win/config.conf}"
}

fmw_config_file_valid() {
  local file="$1"
  [ -f "$file" ] || return 0
  # Validation must not leak parsed config keys into the caller's environment.
  (fmw_conf_load "$file" "${FMW_PORTABLE_CONFIG_KEYS[@]}" >/dev/null)
}

fmw_config_file_value() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  fmw_conf_value "$file" "$key"
}

# fmw_config_resolve [--key value...] [--profile-config file]
# Resolves one portable installation configuration without sourcing shell code.
# Precedence is explicit CLI > allowlisted environment > user config > optional
# allowlisted profile config > detected/default value.
fmw_config_resolve() {
  local cli_firstmate='' cli_fm_home='' cli_repos='' cli_worktrees=''
  local cli_treehouse='' cli_dotnet='' cli_msbuild='' profile_file=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --firstmate-root) cli_firstmate="$2"; shift 2 ;;
      --fm-home) cli_fm_home="$2"; shift 2 ;;
      --repos-root) cli_repos="$2"; shift 2 ;;
      --worktrees-root) cli_worktrees="$2"; shift 2 ;;
      --treehouse-bin) cli_treehouse="$2"; shift 2 ;;
      --windows-dotnet) cli_dotnet="$2"; shift 2 ;;
      --windows-msbuild) cli_msbuild="$2"; shift 2 ;;
      --profile-config) profile_file="$2"; shift 2 ;;
      --config) FMW_CONFIG_FILE="$2"; shift 2 ;;
      *) fmw_log "unknown configuration option: $1"; return 2 ;;
    esac
  done

  local user_file
  user_file="$(fmw_config_default_file)"
  [ -f "$user_file" ] && fmw_config_file_valid "$user_file" \
    || { [ ! -f "$user_file" ] || { fmw_log "invalid portable config: $user_file"; return 1; }; }
  [ -n "$profile_file" ] && fmw_config_file_valid "$profile_file" \
    || { [ -z "$profile_file" ] || { fmw_log "invalid profile config: $profile_file"; return 1; }; }

  local user profile env_value
  _fmw_cfg_pick() {
    local cli="$1" env_name="$2" key="$3" default="$4"
    if [ -n "$cli" ]; then printf '%s' "$cli"; return; fi
    env_value="${!env_name:-}"
    if [ -n "$env_value" ]; then printf '%s' "$env_value"; return; fi
    user="$(fmw_config_file_value "$user_file" "$key" 2>/dev/null || true)"
    if [ -n "$user" ]; then printf '%s' "$user"; return; fi
    profile="$(fmw_config_file_value "$profile_file" "$key" 2>/dev/null || true)"
    if [ -n "$profile" ]; then printf '%s' "$profile"; return; fi
    printf '%s' "$default"
  }

  FMW_CFG_FIRSTMATE_ROOT="$(_fmw_cfg_pick "$cli_firstmate" FIRSTMATE_ROOT FIRSTMATE_ROOT "${HOME:-}/firstmate")"
  FMW_CFG_FM_HOME="$(_fmw_cfg_pick "$cli_fm_home" FM_HOME FM_HOME "${HOME:-}/firstmate")"
  FMW_CFG_REPOS_ROOT="$(_fmw_cfg_pick "$cli_repos" FMW_REPOS_ROOT FMW_REPOS_ROOT "$(fmw_detect_windows_root 2>/dev/null || true)")"
  FMW_CFG_WORKTREES_ROOT="$(_fmw_cfg_pick "$cli_worktrees" FMW_WORKTREES_ROOT FMW_WORKTREES_ROOT "${FMW_CFG_REPOS_ROOT:+$FMW_CFG_REPOS_ROOT/worktrees}")"
  FMW_CFG_TREEHOUSE_BIN="$(_fmw_cfg_pick "$cli_treehouse" TREEHOUSE_BIN TREEHOUSE_BIN "$(command -v treehouse 2>/dev/null || true)")"
  FMW_CFG_WINDOWS_DOTNET="$(_fmw_cfg_pick "$cli_dotnet" WINDOWS_DOTNET WINDOWS_DOTNET "$(command -v dotnet.exe 2>/dev/null || true)")"
  FMW_CFG_WINDOWS_MSBUILD="$(_fmw_cfg_pick "$cli_msbuild" WINDOWS_MSBUILD WINDOWS_MSBUILD '')"
  export FMW_CFG_FIRSTMATE_ROOT FMW_CFG_FM_HOME FMW_CFG_REPOS_ROOT FMW_CFG_WORKTREES_ROOT
  export FMW_CFG_TREEHOUSE_BIN FMW_CFG_WINDOWS_DOTNET FMW_CFG_WINDOWS_MSBUILD
}
