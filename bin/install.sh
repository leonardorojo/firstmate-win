#!/usr/bin/env bash
# bin/install.sh — user-space installer for firstmate-win (fmw) inside WSL.
#
#   bash bin/install.sh [--dry-run]
#
# What it does (all user-space; NO sudo, NO Windows global PATH, NO changes
# to the Firstmate upstream):
#   1. Verifies system prerequisites (git, tmux, flock, wslpath, realpath)
#      and WSL access to /mnt/c; fails with the exact install command when
#      something is missing.
#   2. Verifies a native Linux Node/npm on PATH and the pi shim target.
#   3. Installs tasks-axi via the user npm prefix (default
#      ~/.local/npm-global) and links it into ~/.local/bin.
#   4. Links ~/.local/bin/pi -> <repo>/bin/shims/pi (the fmw shim).
#   5. Adds the user-local bin dirs to ~/.bashrc (backup first, idempotent).
#   6. Creates the default Windows worktree root (C:\FirstmateWorktrees).
#   7. Verifies the Firstmate upstream (~/firstmate) and reports the manual
#      steps it cannot do for you (Pi authentication, Firstmate setup).
#
# Idempotent: safe to re-run; partial installations are detected and
# reported with actionable messages. --dry-run prints every step without
# changing anything.
set -euo pipefail

# --- defaults (configurable via environment) ---
FMW_INSTALL_HOME="${FMW_INSTALL_HOME:-$HOME}"
FMW_LOCAL_BIN="${FMW_LOCAL_BIN:-$FMW_INSTALL_HOME/.local/bin}"
FMW_NPM_PREFIX="${FMW_NPM_PREFIX:-$FMW_INSTALL_HOME/.local/npm-global}"
FMW_FIRSTMATE_HOME="${FMW_FIRSTMATE_HOME:-$FMW_INSTALL_HOME/firstmate}"
FMW_REPO="${FMW_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FMW_WORKTREE_ROOT_WINDOWS="${FMW_WORKTREE_ROOT_WINDOWS:-C:\\FirstmateWorktrees}"
FMW_BASHRC="${FMW_BASHRC:-$FMW_INSTALL_HOME/.bashrc}"

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

step() { echo "==> $*"; }
ok()   { echo "    [ok] $*"; }
warn() { echo "    [warn] $*"; }
fail() { echo "    [ERROR] $*" >&2; exit 1; }
would() { [ "$DRY" = 1 ] && echo "    [dry-run] would: $*" || true; }
run() {
  if [ "$DRY" = 1 ]; then
    echo "    [dry-run] $*"
  else
    "$@"
  fi
}

echo "fmw installer (Sprint 7) — user-space, idempotent"
echo "  install home : $FMW_INSTALL_HOME"
echo "  repo         : $FMW_REPO"
echo "  firstmate    : $FMW_FIRSTMATE_HOME"
[ "$DRY" = 1 ] && echo "  MODE         : dry-run (nothing will change)"

# --- 1. system prerequisites -------------------------------------------------
step "1/8 system prerequisites (WSL)"
require() {
  local cmd="$1" hint="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd present"
  else
    fail "$cmd missing — $hint"
  fi
}
require bash  "already running (this is bash)"
require git   "sudo apt-get install -y git"
require tmux  "sudo apt-get install -y tmux"
require flock "sudo apt-get install -y util-linux"
require wslpath "reinstall WSL: wsl --install (or wsl.exe --update)"
require realpath "sudo apt-get install -y coreutils"

# executable bits: the public repo tracks scripts as 100644; a clone cannot
# run the shims until the bits are restored (fmw invokes the shims by PATH)
chmod +x "$FMW_REPO/bin/fmw" "$FMW_REPO/bin/install.sh" "$FMW_REPO"/bin/shims/* 2>/dev/null \
  && ok "executable bits restored (bin/fmw, bin/shims/*)" \
  || warn "could not chmod +x the repo scripts (check the clone)"

if [ ! -d /mnt/c ] || ! ls /mnt/c >/dev/null 2>&1; then
  fail "/mnt/c is not accessible — this installer must run inside WSL with a mounted Windows drive"
fi
ok "WSL + /mnt/c accessible"

# --- 2. Linux Node/npm + the fmw node runtime -----------------------------------
step "2/8 Linux Node + npm + fmw node runtime"
node_bin="$(command -v node 2>/dev/null || true)"
if [ -z "$node_bin" ]; then
  fail "node not found on PATH — install native Linux Node and add its bin to PATH, e.g.:
  mkdir -p ~/.local/nodejs && curl -fsSL https://nodejs.org/dist/v22.14.0/node-v22.14.0-linux-x64.tar.xz | tar -xJ -C ~/.local/nodejs --strip-components=2
  (or use nvm: curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash)"
fi
if node -p "process.platform" 2>/dev/null | grep -q win32; then
  fail "node on PATH is a WINDOWS build ($node_bin) — Firstmate needs native Linux Node; ensure ~/.local/nodejs/bin (or nvm) precedes /mnt/c/Program Files/nodejs"
fi
ok "node: $(node --version 2>/dev/null) (native Linux)"
npm_bin="$(command -v npm 2>/dev/null || true)"
[ -n "$npm_bin" ] || fail "npm not found — reinstall Node (npm ships with it)"
ok "npm: $(npm --version 2>/dev/null)"
node_runtime="${FMW_LINUX_NODE:-$FMW_INSTALL_HOME/.local/nodejs/bin/node}"
if [ -x "$node_runtime" ]; then
  ok "fmw node runtime: $node_runtime"
else
  fail "fmw node runtime missing at $node_runtime — the pi shim and fmw doctor require it. Install native Linux Node under ~/.local/nodejs (see the node step above) or set FMW_LINUX_NODE to its path."
fi

# --- 3. tasks-axi (user npm prefix + link) --------------------------------------
step "3/8 tasks-axi (completion gate CLI)"
if command -v tasks-axi >/dev/null 2>&1; then
  ok "tasks-axi present: $(command -v tasks-axi)"
else
  echo "    tasks-axi missing — installing into user prefix $FMW_NPM_PREFIX"
  [ "$DRY" = 1 ] && would "npm install -g --prefix \"$FMW_NPM_PREFIX\" tasks-axi" \
    || npm install -g --prefix "$FMW_NPM_PREFIX" tasks-axi
  mkdir -p "$FMW_LOCAL_BIN"
  [ -e "$FMW_LOCAL_BIN/tasks-axi" ] || \
    run ln -s "$FMW_NPM_PREFIX/bin/tasks-axi" "$FMW_LOCAL_BIN/tasks-axi"
  ok "tasks-axi linked: $FMW_LOCAL_BIN/tasks-axi"
  warn "the tasks-axi global SKILL (npm package 'tasks-axi' installs it on demand) — see its docs; without it the completion gate closes scouts in blocked:"
fi

# --- 4. pi package (npm global, Linux) --------------------------------------------
step "4/8 pi package (@earendil-works/pi-coding-agent)"
node_runtime="${FMW_LINUX_NODE:-$FMW_INSTALL_HOME/.local/nodejs/bin/node}"
pi_cli="$FMW_NPM_PREFIX/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
if [ -f "$pi_cli" ]; then
  ok "pi package present ($pi_cli)"
else
  echo "    pi package missing — installing into user prefix $FMW_NPM_PREFIX"
  [ "$DRY" = 1 ] && would "npm install -g --prefix \"$FMW_NPM_PREFIX\" @earendil-works/pi-coding-agent" \
    || npm install -g --prefix "$FMW_NPM_PREFIX" @earendil-works/pi-coding-agent
  [ -f "$pi_cli" ] || fail "pi package install failed — check the npm output above"
  ok "pi package installed ($pi_cli)"
fi
if [ ! -d "$FMW_INSTALL_HOME/.pi/agent" ]; then
  warn "pi is NOT authenticated yet — run the pi CLI once and authenticate manually (its API key lives in ~/.pi/agent). A scout cannot start without it."
fi

# --- 5. pi shim link -------------------------------------------------------------
step "5/8 pi shim"
pi_link="$FMW_LOCAL_BIN/pi"
if [ -e "$pi_link" ] || command -v pi >/dev/null 2>&1; then
  if command -v pi >/dev/null 2>&1 && [ "$(command -v pi)" != "$pi_link" ]; then
    if file "$(command -v pi)" 2>/dev/null | grep -qiE "windows|PE32|MS-DOS"; then
      fail "pi on PATH is a WINDOWS binary — the fmw shims require native Linux pi (link $pi_link)"
    fi
    warn "pi resolves to $(command -v pi) (not the fmw shim $pi_link); fmw will still arm the shim per-window"
  else
    ok "pi shim link present ($pi_link)"
  fi
else
  mkdir -p "$FMW_LOCAL_BIN"
  run ln -s "$FMW_REPO/bin/shims/pi" "$pi_link"
  ok "linked pi shim -> $FMW_REPO/bin/shims/pi"
  warn "the pi shim delegates to the Firstmate pi CLI — make sure Firstmate is set up (step 6) and AUTHENTICATE pi manually (its API key) before the first scout"
fi

# --- 5. ~/.bashrc PATH (backup first, idempotent) --------------------------------
step "6/8 PATH for user-local bin dirs"
path_dirs=("$FMW_LOCAL_BIN" "$FMW_INSTALL_HOME/.local/nodejs/bin" "$FMW_NPM_PREFIX/bin")
missing_path=0
for d in "${path_dirs[@]}"; do
  grep -qF "export PATH=\"$d:\$PATH\"" "$FMW_BASHRC" 2>/dev/null || { missing_path=1; break; }
done
if [ "$missing_path" = 1 ]; then
  if [ -f "$FMW_BASHRC" ]; then
    backup="$FMW_BASHRC.fmw-backup-$(date +%Y%m%d%H%M%S)"
    run cp "$FMW_BASHRC" "$backup"
    ok "backup: $backup"
  fi
  for d in "${path_dirs[@]}"; do
    if ! grep -qF "export PATH=\"$d:\$PATH\"" "$FMW_BASHRC" 2>/dev/null; then
      run bash -c "printf '%s\n' 'export PATH=\"$d:\$PATH\"' >> \"$FMW_BASHRC\""
      ok "added PATH entry: $d"
    fi
  done
  warn "start a new shell (or 'source ~/.bashrc') for the PATH changes to apply"
else
  ok "PATH entries already present"
fi

# --- 6. Windows worktree root -----------------------------------------------------
step "7/8 Windows worktree root (default $FMW_WORKTREE_ROOT_WINDOWS)"
if [ -d "/mnt/c/FirstmateWorktrees" ]; then
  ok "root present (/mnt/c/FirstmateWorktrees)"
elif [ "$DRY" = 1 ]; then
  would "cmd.exe /c mkdir \"$FMW_WORKTREE_ROOT_WINDOWS\""
  ok "would create $FMW_WORKTREE_ROOT_WINDOWS"
else
  wt_win="$(printf '%s' "$FMW_WORKTREE_ROOT_WINDOWS" | sed 's|\\|\\\\|g')"
  if cmd.exe /c "mkdir \"$wt_win\"" >/dev/null 2>&1; then
    ok "created $FMW_WORKTREE_ROOT_WINDOWS (Windows; worktrees stay on Windows)"
  else
    fallback="C:\\Users\\${USER:-user}\\FirstmateWorktrees"
    fail "could not create $FMW_WORKTREE_ROOT_WINDOWS (root of C: usually needs admin). Use a user-writable root instead, e.g.:
  FMW_WORKTREE_ROOT_WINDOWS=\"$fallback\" bash bin/install.sh
then register projects with --worktree-root 'C:\\Users\\${USER:-user}\\FirstmateWorktrees\\<project>'"
  fi
fi
warn "per-project roots (C:\\FirstmateWorktrees\\<project>) must exist before 'fmw project add --worktree-root <root>'"

# --- 7. Firstmate upstream ---------------------------------------------------------
step "8/8 Firstmate upstream"
if [ -f "$FMW_FIRSTMATE_HOME/bin/fm-spawn.sh" ] && [ -f "$FMW_FIRSTMATE_HOME/bin/fm-crew-state.sh" ]; then
  ok "Firstmate present ($FMW_FIRSTMATE_HOME)"
else
  fail "Firstmate not found at $FMW_FIRSTMATE_HOME — install it first (upstream instructions):
  git clone https://github.com/kunchenguid/firstmate.git \"$FMW_FIRSTMATE_HOME\"
  then follow its own setup (deps, backends, api keys). fmw never modifies it."
fi

echo
echo "=== installation summary ==="
echo "  repo          : $FMW_REPO"
echo "  firstmate     : $FMW_FIRSTMATE_HOME"
echo "  node          : $(node --version 2>/dev/null || echo '?')"
echo "  npm           : $(npm --version 2>/dev/null || echo '?')"
echo "  tasks-axi     : $(command -v tasks-axi 2>/dev/null || echo 'NOT INSTALLED — re-run without --dry-run')"
echo "  pi shim       : $pi_link"
echo
echo "Remaining MANUAL steps (documented in the README):"
echo "  1. Authenticate pi (provide its API key) — required before the first scout."
echo "  2. Register a project: fmw project add --name <P> --windows-path <repo> \\"
echo "       --worktree-root 'C:\\FirstmateWorktrees\\<P>' --profile <profile>"
echo "  3. alias fmw='bash $FMW_REPO/bin/fmw' (optional)"
echo "  4. Run: bash $FMW_REPO/bin/fmw doctor"
[ "$DRY" = 1 ] && echo "  (dry-run: nothing was changed)" || echo "  done."
