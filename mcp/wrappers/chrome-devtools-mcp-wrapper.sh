#!/usr/bin/env bash
# Wrapper for chrome-devtools-mcp launched by MCP hosts (Cline / VS Code).
# Pins a known-good environment regardless of what the host process passes,
# and logs every invocation so we can tell "host never called us" apart from
# "server failed after starting".

export HOME="${HOME:-/home/inf}"
export PATH="/home/inf/.nvm/versions/node/v22.23.1/bin:/usr/local/bin:/usr/bin:/bin"
export DISPLAY="${DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# Pick an XAUTHORITY file that actually authorizes against $DISPLAY.
# Host-provided values (e.g. a stale or missing ~/.Xauthority) stop working
# when the display manager rotates credentials, so verify before trusting.
_pick_xauthority() {
  local candidates=("${XAUTHORITY:-}" "$HOME/.Xauthority")
  local f
  for f in "$XDG_RUNTIME_DIR"/xauth_*; do
    [ -f "$f" ] && candidates+=("$f")
  done
  for f in "${candidates[@]}"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    if command -v xdpyinfo >/dev/null 2>&1; then
      if XAUTHORITY="$f" xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        printf '%s\n' "$f"
        return 0
      fi
    else
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}
if _picked="$(_pick_xauthority)"; then
  export XAUTHORITY="$_picked"
else
  export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"
  echo "WARNING: no working XAUTHORITY found for DISPLAY=$DISPLAY" \
    >>/tmp/chrome-devtools-mcp-wrapper.log
fi

LOG=/tmp/chrome-devtools-mcp-wrapper.log
{
  echo "===== $(date '+%F %T') wrapper invoked (pid $$, ppid $PPID)"
  echo "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
} >>"$LOG" 2>&1

exec /home/inf/.nvm/versions/node/v22.23.1/bin/node \
  /home/inf/.npm-global/lib/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js \
  -e /usr/bin/google-chrome \
  --logFile /tmp/chrome-devtools-mcp-server.log "$@" 2>>"$LOG"
