# lib/runtime.sh — Linux runtime detection (Node/Pi) for firstmate-win (fmw)
#
# The default Pi runtime is native Linux inside WSL.
#   - Linux Node: $FMW_LINUX_NODE or ~/.local/nodejs/bin/node (runtime
#                 installed by the wrapper; ELF x86-64, platform=linux).
#   - Linux Pi:   `pi` must resolve to a Linux binary (outside /mnt/).
#                 The shim bin/shims/pi runs the Linux node directly.
#   - Windows Pi: rejected by default (resolves to /mnt/.../AppData/Roaming/npm
#                 or /mnt/c/Program Files/...). The node.exe bridge remains
#                 only as an explicit fallback (codex/opencode/etc. harnesses).
#
# Output contract:
#   fmw_runtime_node_linux -> prints the Linux node path; rc=0 if it exists and
#                             reports process.platform=linux; rc=1 + FMW_RUNTIME_REASON
#   fmw_runtime_pi_linux   -> prints the pi path; rc=0 if it resolves to Linux;
#                             rc=1 + FMW_RUNTIME_REASON (pi missing or Windows)
#   fmw_runtime_require_pi_linux -> fail-closed: aborts with an actionable
#                             message if Pi is not Linux (unless
#                             FMW_SKIP_RUNTIME_CHECK=1, used by tests/sandbox)

# fmw_runtime_node_linux — locate and verify the native Linux Node
fmw_runtime_node_linux() {
  local candidate plat
  FMW_RUNTIME_REASON=""
  candidate="${FMW_LINUX_NODE:-$HOME/.local/nodejs/bin/node}"
  if [ ! -x "$candidate" ]; then
    FMW_RUNTIME_REASON="Linux Node not found: $candidate (set FMW_LINUX_NODE or install the runtime)"
    return 1
  fi
  plat="$("$candidate" -p 'process.platform' 2>/dev/null || true)"
  if [ "$plat" != "linux" ]; then
    FMW_RUNTIME_REASON="Node at $candidate reports platform=$plat (expected linux)"
    echo "ERROR: $FMW_RUNTIME_REASON"
    return 1
  fi
  echo "$candidate"
  return 0
}

# fmw_runtime_pi_linux — locate Pi and verify it is a Linux runtime
fmw_runtime_pi_linux() {
  local pi_path pi_real shim_real
  FMW_RUNTIME_REASON=""
  FMW_RUNTIME_PI_REAL=""
  pi_path="$(command -v pi 2>/dev/null || true)"
  if [ -z "$pi_path" ]; then
    FMW_RUNTIME_REASON="pi is not on PATH (WSL)"
    echo "ERROR: $FMW_RUNTIME_REASON"
    return 1
  fi
  pi_real="$(readlink -f "$pi_path" 2>/dev/null || echo "$pi_path")"
  FMW_RUNTIME_PI_REAL="$pi_real"
  # Our shim bin/shims/pi is Linux by definition, even though firstmate-win
  # lives under /mnt/c (do not confuse it with a Windows npm shim).
  shim_real="$(readlink -f "$FMW_HOME/bin/shims/pi" 2>/dev/null || echo "$FMW_HOME/bin/shims/pi")"
  if [ "$pi_real" = "$shim_real" ]; then
    if ! fmw_runtime_node_linux >/dev/null; then
      FMW_RUNTIME_REASON="pi shim without a verified Linux Node runtime: $FMW_RUNTIME_REASON"
      echo "ERROR: $FMW_RUNTIME_REASON"
      return 1
    fi
    echo "$pi_path"
    return 0
  fi
  case "$pi_real" in
    /mnt/*)
      FMW_RUNTIME_REASON="Pi resolves to a Windows binary: $pi_real (rejected by default; use the fmw shim bin/shims/pi with Linux Node: npm install -g @earendil-works/pi-coding-agent)"
      echo "ERROR: $FMW_RUNTIME_REASON"
      return 1 ;;
  esac
  if [ ! -x "$pi_real" ]; then
    FMW_RUNTIME_REASON="pi is not executable: $pi_real"
    echo "ERROR: $FMW_RUNTIME_REASON"
    return 1
  fi
  if ! fmw_runtime_node_linux >/dev/null; then
    FMW_RUNTIME_REASON="Linux Node runtime not verified: $FMW_RUNTIME_REASON"
    echo "ERROR: $FMW_RUNTIME_REASON"
    return 1
  fi
  echo "$pi_path"
  return 0
}

# fmw_runtime_require_pi_linux — fail-closed for pi/pi-signed harnesses
fmw_runtime_require_pi_linux() {
  if [ "${FMW_SKIP_RUNTIME_CHECK:-0}" = "1" ]; then
    return 0
  fi
  if ! fmw_runtime_pi_linux >/dev/null; then
    fmw_die "pi harness requires native Linux Pi (WSL). $FMW_RUNTIME_REASON"
  fi
  return 0
}
