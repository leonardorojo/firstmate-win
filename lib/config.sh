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
