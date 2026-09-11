#!/usr/bin/env bash
# Wrapper for lark-mcp launched by MCP hosts (Cline / VS Code).
# lark-mcp persists OAuth user access tokens in an AES-encrypted local store;
# the AES key lives in the system keyring via keytar -> libsecret -> D-Bus
# Secret Service. MCP hosts spawn servers without the desktop session env, so
# keytar fails with "Cannot autolaunch D-Bus without X11 $DISPLAY" and the
# token store falls back to volatile memory. Pin the session env here so the
# persistent store works, and log every invocation for diagnosis.

export HOME="${HOME:-/home/inf}"
export PATH="/home/inf/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
export DISPLAY="${DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

LOG=/tmp/lark-mcp-wrapper.log
{
  echo "===== $(date '+%F %T') wrapper invoked (pid $$, ppid $PPID)"
  echo "DISPLAY=$DISPLAY DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
} >>"$LOG" 2>&1

exec /usr/bin/node \
  /home/inf/.npm-global/lib/node_modules/@larksuiteoapi/lark-mcp/dist/cli.js \
  "$@" 2>>"$LOG"
