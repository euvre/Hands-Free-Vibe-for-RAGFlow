#!/usr/bin/env bash
# mcp-cleanup.sh — kill MCP server processes leaked by FINISHED cline runs.
#
# Leak mechanism: cline CLI spawns stdio MCP servers (lark-mcp ~600MB RSS,
# chrome-devtools, filesystem). When the CLI exits, these servers are
# reparented to the user's systemd manager but never die, so every daemon
#
# Safe criterion: kill ONLY orphans — processes whose parent is a systemd
# instance (user manager or PID 1). MCP servers of LIVE hosts (running
# cline, VS Code, CLion) still have their host as parent and are never
# touched. Called at the start of every runner so each new task first
# reclaims the previous task's leftovers.
set -u
DAEMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"  # repo root (this script lives in framework/)
LOG_DIR="$DAEMON_DIR/logs"

# Command signatures of the MCP servers configured in cline_mcp_settings.json
# (+ the leaked `sh -c ... jsonrpc initialize` handshake wrappers).
PATTERN='lark-mcp|chrome-devtools-mcp|server-filesystem|jsonrpc.*initialize'

# Slot workers run as `exec docker run --rm --name hfv-worker-sN ... -v
# <slot>/chrome-profile:...` — the docker CLIENT's PPID is the user systemd
# (an "orphan parent") and its argv matches PATTERN via the mount path, so
# orphan-PPID matching alone would SIGTERM LIVE container clients. A victim
# must be an actual MCP server process, never a container-runtime client.
victim_ok() { # victim_ok <pid> — false => must NOT be killed
  local cmd0
  cmd0="$(tr '\0' '\n' </proc/"$1"/cmdline 2>/dev/null | head -1)"
  case "$cmd0" in
    *docker|*podman|*nerdctl|*ctr) return 1 ;;
  esac
  ! grep -qa 'hfv-worker-s' /proc/"$1"/cmdline 2>/dev/null
}

# parent pids that mark a process as orphaned (systemd --user / pid 1; "tini"
# = PID 1 inside hfv-worker slot containers, where MCP servers leaked by a
# finished cline run reparent to the container init)
orphan_parents() { ps -eo pid,comm | awk '$2=="systemd" || $2=="init" || $2=="tini" {print $1}' | sort -u; }

PARENTS="$(orphan_parents)"
declare -a VICTIMS=()
kill_victim() { # kill_victim <pid> <sig>
  # capture the cmdline BEFORE the kill: after TERM+grace the process is reaped
  # and /proc/<pid>/cmdline is gone (empty log lines + stderr noise otherwise)
  local desc
  desc="$(printf '%s: ' "$1"; tr '\0' ' ' </proc/"$1"/cmdline 2>/dev/null | cut -c1-90)"
  kill "$2" "$1" 2>/dev/null || return 1
  VICTIMS+=("$desc")
  return 0
}
for pid in $(pgrep -f "$PATTERN"); do
  ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  [[ -z "$ppid" ]] && continue
  if grep -qx "$ppid" <<<"$PARENTS"; then
    victim_ok "$pid" || continue
    kill_victim "$pid" -TERM
  fi
done

# SIGTERM grace: anything still alive after 5s gets SIGKILL
sleep 5
for pid in $(pgrep -f "$PATTERN"); do
  ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  [[ -z "$ppid" ]] && continue
  if grep -qx "$ppid" <<<"$PARENTS"; then
    victim_ok "$pid" || continue
    kill_victim "$pid" -KILL
  fi
done

if (( ${#VICTIMS[@]} > 0 )); then
  {
    echo "[$(date +%Y%m%d-%H%M%S)] mcp-cleanup: killed ${#VICTIMS[@]} orphaned MCP process(es):"
    for v in "${VICTIMS[@]}"; do echo "  $v"; done
  } >> "$LOG_DIR/daemon.log"
fi
exit 0
