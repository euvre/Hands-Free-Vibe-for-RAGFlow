#!/usr/bin/env bash
# browser-ensure-login.sh <base-url> [profile-dir] — session keep-alive run
# BEFORE the LLM starts. Was: every run spent its first browser iterations
# discovering the login page and re-filling the same form. Now: headless
# chrome on the SAME profile dir the browser MCP will reuse — a still-valid
# session skips the dance entirely; an expired one is refreshed through the
# sanctioned form login (browser-login.py; the task file's hard-rule path,
# script-driven — no API login, no token planting).
#
# Profile default: the browser MCP's own userDataDir (container:
# ~/.cache/chrome-devtools-mcp/profile, bind-mounted from the slot root on the
# host). Never runs while a --remote-debugging-port chrome is alive (the MCP's
# browser) — the profile Singleton would collide.
#
# Prints one LOGIN_* line (for the pre-flight section); always exit 0.
set -u
DIR="$HOME/hands-free-vibe"
BASE="${1:-http://127.0.0.1:9222}"
PROFILE="${2:-$HOME/.cache/chrome-devtools-mcp/profile}"

if ! curl -sf -o /dev/null --max-time 5 "$BASE/"; then
  echo "LOGIN_SKIP $BASE unreachable — services not up; the task's failure paths apply"
  exit 0
fi
if pgrep -f -- '--remote-debugging-port' >/dev/null 2>&1; then
  echo "LOGIN_SKIP chrome already running (browser MCP active) — profile left alone"
  exit 0
fi
mkdir -p "$PROFILE"
out="$(timeout 150 uv run --with playwright python "$DIR/framework/browser-login.py" "$BASE" "$PROFILE" 2>&1)"
line="$(grep -E '^LOGIN_' <<<"$out" | tail -1)"
if [[ -z "$line" ]]; then
  line="LOGIN_FAILED $(tail -2 <<<"$out" | tr '\n' ' ' | head -c 200)"
fi
echo "$line"
exit 0
