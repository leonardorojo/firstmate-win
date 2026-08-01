# lib/firstmate.sh — Firstmate integration
#
# Reuses the official Firstmate scripts (fm-brief.sh, fm-spawn.sh,
# fm-send.sh, fm-crew-state.sh) WITHOUT duplicating their orchestration logic.
#
# Worktree delivery: a delegating `treehouse` shim (bin/shims/treehouse)
# intercepts only `treehouse get` inside the fm-<id> window and enters the
# fmw pre-created worktree; `treehouse return` on fmw worktrees is translated
# to `git worktree remove`. Everything else delegates to the real treehouse.

# fmw_firstmate_bin <name> — resolve an official Firstmate script
fmw_firstmate_bin() {
  local name="$1"
  [ -d "$FMW_FIRSTMATE_HOME/bin" ] \
    || { fmw_log "Firstmate not found at $FMW_FIRSTMATE_HOME (is FMW_FIRSTMATE_HOME correct?)"; return 1; }
  [ -f "$FMW_FIRSTMATE_HOME/bin/$name" ] \
    || { fmw_log "missing Firstmate script: $FMW_FIRSTMATE_HOME/bin/$name"; return 1; }
  echo "$FMW_FIRSTMATE_HOME/bin/$name"
}

# fmw_ensure_shim_path — make tmux windows find the shims (treehouse, node).
#   Two mechanisms:
#   1) ~/.local/bin (EFFECTIVE in WSL): every tmux window runs an interactive
#      bash that rebuilds PATH from ~/.bashrc; tmux session/global env does NOT
#      reach the panes (verified: set-environment -g/-t and new-window -e are
#      ignored by the pane shell). Since ~/.local/bin is already FIRST in that
#      PATH, the shims are installed there as symlinks. Local and reversible
#      (just remove the symlinks).
#   2) tmux set-environment (best-effort): for variables tmux does apply to
#      new windows in other configurations.
fmw_ensure_shim_path() {
  [ -x "$FMW_SHIMS_DIR/treehouse" ] || { fmw_log "missing shim: $FMW_SHIMS_DIR/treehouse"; return 1; }

  local lbin shim_name
  lbin="$HOME/.local/bin"
  if [ -d "$lbin" ]; then
    for shim_name in treehouse node; do
      if [ -L "$lbin/$shim_name" ]; then
        continue
      elif [ -e "$lbin/$shim_name" ]; then
        fmw_log "warning: $lbin/$shim_name exists and is NOT a symlink; not touched"
      else
        ln -s "$FMW_SHIMS_DIR/$shim_name" "$lbin/$shim_name" 2>/dev/null \
          && fmw_log "bridge installed: $lbin/$shim_name -> $FMW_SHIMS_DIR/$shim_name" \
          || fmw_log "warning: could not create bridge $lbin/$shim_name"
      fi
    done
  fi

  command -v tmux >/dev/null 2>&1 || { fmw_log "tmux not available; shim provided via ~/.local/bin"; return 0; }
  local cur raw newpath san p
  raw="$(tmux show-environment -g PATH 2>/dev/null || true)"
  cur="${raw#PATH=}"
  # sanitize: remove test-sandbox leftovers (/tmp/fmw-*) and duplicate
  # shim entries accumulated in the previous global PATH (leaks from
  # non-isolated suites)
  san=""
  IFS=: read -r -a parts <<< "$cur"
  for p in "${parts[@]:-}"; do
    [ -n "$p" ] || continue
    case "$p" in
      /tmp/fmw-*|"$FMW_SHIMS_DIR") continue ;;
    esac
    san="${san:+$san:}$p"
  done
  if [ "$san" != "$cur" ]; then
    # healing: the previous global PATH had leaks; write the sanitized one back
    tmux set-environment -g PATH "$san" 2>/dev/null || true
    cur="$san"
  fi
  case "$cur" in
    "$FMW_SHIMS_DIR:"*|"$FMW_SHIMS_DIR") fmw_log "shim already first in tmux global PATH"; return 0 ;;
  esac
  if ! tmux show-environment -g PATH >/dev/null 2>&1; then
    tmux new-session -d -s firstmate 2>/dev/null \
      || { fmw_log "warning: could not start tmux session 'firstmate'"; return 0; }
  fi
  newpath="$FMW_SHIMS_DIR:${cur:-$PATH}"
  if tmux has-session -t firstmate 2>/dev/null; then
    tmux set-environment -t firstmate PATH "$newpath" 2>/dev/null \
      || fmw_log "warning: could not set PATH in the firstmate session"
  fi
  tmux set-environment -g PATH "$newpath" 2>/dev/null \
    || { fmw_log "warning: could not update tmux global PATH"; return 0; }
  fmw_log "treehouse shim armed in tmux PATH (firstmate session + global): $FMW_SHIMS_DIR"
}

# fmw_task_conf_set <id> KEY=VAL... — update a task conf (atomic)
#   Reloads the conf, applies the overrides and rewrites keeping the order.
fmw_task_conf_set() {
  local id="$1"
  shift
  fmw_task_load "$id" || return 1
  local -a out=()
  local k v pair
  for k in "${FMW_TASK_CONF_KEYS[@]}"; do
    v="${!k:-}"
    for pair in "$@"; do
      if [[ "$pair" == "$k="* ]]; then
        v="${pair#*=}"
        v="${v#\'}"; v="${v%\'}"
      fi
    done
    [ -n "$v" ] && out+=("$k='$v'")
  done
  fmw_conf_write_atomic "$FMW_TASKS_DIR/$id.conf" "${out[@]}" \
    || { fmw_log "could not update state/tasks/$id.conf"; return 1; }
}

# fmw_task_brief <id> [--scout] — create/update the brief via fm-brief.sh
fmw_task_brief() {
  local id="${1:-}"
  [ -n "$id" ] || fmw_die "usage: fmw task brief <id> [--scout]"
  local scout=0
  for a in "$@"; do [ "$a" = "--scout" ] && scout=1; done
  fmw_task_load "$id" || return 1
  local brief_bin repo_name
  brief_bin="$(fmw_firstmate_bin fm-brief.sh)" || return 1
  repo_name="$(basename "$REPOSITORY_WSL_PATH")"
  local rc=0
  if [ "$scout" = 1 ]; then
    "$brief_bin" "$id" "$repo_name" --scout || rc=$?
  else
    "$brief_bin" "$id" "$repo_name" || rc=$?
  fi
  [ "$rc" = 0 ] || fmw_die "fm-brief.sh failed (rc=$rc)"
  echo "brief: $FMW_FIRSTMATE_HOME/data/$id/brief.md (task=$id repo=$repo_name scout=$scout)"
}

# fmw_task_spawn <id> [--scout] [--harness X] [--model M] [--effort E]
#   Hands the prepared worktree to the normal Firstmate lifecycle
#   (fm-spawn.sh). The treehouse shim resolves the worktree by window fm-<id>.
fmw_task_spawn() {
  local id="" scout=0 harness="" model="" effort=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --scout)   scout=1;   shift ;;
      --harness) harness="$2"; shift 2 ;;
      --model)   model="$2"; shift 2 ;;
      --effort)  effort="$2"; shift 2 ;;
      -*) fmw_die "unknown argument: $1";;
      *) [ -z "$id" ] && id="$1" || fmw_die "too many arguments: $1"; shift ;;
    esac
  done
  [ -n "$id" ] || fmw_die "usage: fmw task spawn <id> [--scout] [--harness X] [--model M] [--effort E]"

  fmw_task_load "$id" || return 1
  [ "$STATE" = "prepared" ] || fmw_die "the task must be in 'prepared' (current state: $STATE)"
  [ -d "$WORKTREE_WSL_PATH" ] || fmw_die "worktree does not exist: $WORKTREE_WSL_PATH"

  # Pi harnesses require a native Linux runtime (fail-closed).
  # Windows Pi (node.exe bridge) is rejected by default.
  case "$harness" in
    pi|pi-signed) fmw_runtime_require_pi_linux || return 1 ;;
  esac

  fmw_ensure_shim_path || return 1

  local spawn_bin
  spawn_bin="$(fmw_firstmate_bin fm-spawn.sh)" || return 1

  local -a args=("$id" "$REPOSITORY_WSL_PATH")
  [ "$scout" = 1 ] && args+=(--scout)
  [ -n "$harness" ] && args+=(--harness "$harness")
  [ -n "$model" ] && args+=(--model "$model")
  [ -n "$effort" ] && args+=(--effort "$effort")

  fmw_log "spawn: $spawn_bin ${args[*]} (worktree delivered by shim)"
  # set -e (bin/fmw): capture rc without aborting — the REAL fm-spawn.sh may
  # return rc!=0 even though the spawn happened (meta published)
  local rc=0
  "$spawn_bin" "${args[@]}" || rc=$?

  if [ "$rc" = 0 ] || [ -f "$FMW_FIRSTMATE_HOME/state/$id.meta" ]; then
    # link Firstmate metadata (state/<id>.meta) to the fmw conf.
    # The REAL fm-spawn.sh may return rc!=0 (e.g. the first busy event does
    # not arrive when the pi ext cannot run WSL scripts from node.exe), but
    # if the meta was published the spawn DID happen: the task becomes spawned.
    local fm_meta="$FMW_FIRSTMATE_HOME/state/$id.meta"
    if [ -f "$fm_meta" ]; then
      # Meta keys: the REAL fm-spawn.sh meta does not publish every key
      # (e.g. backend= is absent with the tmux backend). Missing keys must
      # yield an empty value, NEVER an error: under set -euo pipefail
      # (bin/fmw), a no-match grep inside command substitution used to kill
      # fmw silently (real bug: rc=1 without output and unlinked conf).
      if [ ! -r "$fm_meta" ]; then
        fmw_log "warning: state/$id.meta exists but is not readable; spawn not linkable"
        return 1
      fi
      local wnd backend ep meta_wt endpoint
      wnd="$(grep -E '^window=' "$fm_meta" | head -1 | cut -d= -f2- || true)"
      backend="$(grep -E '^backend=' "$fm_meta" | head -1 | cut -d= -f2- || true)"
      ep="$(grep -E '^endpoint_task_id=' "$fm_meta" | head -1 | cut -d= -f2- || true)"
      # meta worktree different from the registered one => the agent is NOT
      # where fmw believes: fail-closed (do not link) instead of hiding the gap.
      meta_wt="$(grep -E '^worktree=' "$fm_meta" | head -1 | cut -d= -f2- || true)"
      if [ -n "$meta_wt" ] && [ -n "$WORKTREE_WINDOWS_PATH" ]; then
        local meta_wt_u conf_wt_u
        case "$meta_wt" in
          /mnt/*) meta_wt_u="$(fmw_path_canonical "$meta_wt" 2>/dev/null || echo "$meta_wt")" ;;
          *)      meta_wt_u="$(fmw_path_to_wsl "$meta_wt" 2>/dev/null || echo "$meta_wt")" ;;
        esac
        case "$WORKTREE_WINDOWS_PATH" in
          /mnt/*) conf_wt_u="$(fmw_path_canonical "$WORKTREE_WINDOWS_PATH" 2>/dev/null || echo "$WORKTREE_WINDOWS_PATH")" ;;
          *)      conf_wt_u="$(fmw_path_to_wsl "$WORKTREE_WINDOWS_PATH" 2>/dev/null || echo "$WORKTREE_WINDOWS_PATH")" ;;
        esac
        if [ "$meta_wt_u" != "$conf_wt_u" ]; then
          fmw_log "warning: meta points to another worktree ($meta_wt) different from the registered one ($WORKTREE_WINDOWS_PATH); not linking"
          return 1
        fi
      fi
      # invalid endpoint (neither window= nor endpoint_task_id=) => clear reject
      endpoint="${wnd:-${ep:-}}"
      if [ -z "$endpoint" ]; then
        fmw_log "warning: meta without window= or endpoint_task_id=; spawn not linkable"
        return 1
      fi
      fmw_task_conf_set "$id" \
        "STATE='spawned'" \
        "FIRSTMATE_TASK_ID='$id'" \
        "FIRSTMATE_BACKEND='${backend:-tmux}'" \
        "FIRSTMATE_ENDPOINT='$endpoint'" \
        || fmw_log "warning: could not link firstmate metadata in $id.conf"
      if [ "$rc" = 0 ]; then
        echo "spawn OK: task=$id window=${wnd:-unknown} backend=${backend:-tmux}"
      else
        fmw_log "warning: fm-spawn.sh rc=$rc but the meta was published; spawn considered completed"
        echo "spawn OK: task=$id window=${wnd:-unknown} backend=${backend:-tmux} (downstream rc=$rc)"
      fi
      return 0
    elif [ "$rc" = 0 ]; then
      fmw_log "warning: fm-spawn.sh finished OK but there is no state/$id.meta (real spawn?)"
    fi
  fi
  return "$rc"
}

# fmw_task_send <id> <message...> — agent steering via fm-send.sh
fmw_task_send() {
  local id="${1:-}"
  [ -n "$id" ] || fmw_die "usage: fmw task send <id> <message...>"
  shift
  [ $# -gt 0 ] || fmw_die "missing message"
  fmw_task_load "$id" || return 1
  local send_bin
  send_bin="$(fmw_firstmate_bin fm-send.sh)" || return 1
  # fm-send.sh is fail-closed: it requires an explicit FM_HOME to resolve
  # targets. Without the export, real steering failed with "FM_HOME is not set".
  FM_HOME="$FMW_FIRSTMATE_HOME" "$send_bin" "$id" "$@"
}
