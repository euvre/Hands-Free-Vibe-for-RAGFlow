#!/usr/bin/env bash
# post-reply.sh — send the thread replies the main task staged as files.
# The main task NEVER sends messages itself: it writes reply text into
# deliver/reply-<message_id>.md and this post step delivers each file into
# its own thread (self-routing by filename, so a stale file can never be sent
# to the wrong issue). Pure script, no LLM.
#
# Each file is consumed (deleted) after one send attempt — success or failure.
# A file whose message_id no longer exists in issues.jsonl (record dropped /
# handed over in the meantime) is removed without sending.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"  # repo root (this script lives in lines/)
SUF=""
[[ -n "${HFV_SLOT:-}" ]] && SUF="-s$HFV_SLOT"
DELIVER_DIR="$DIR/deliver$SUF"
STORE="$DIR/issues/issues.jsonl"
REPLY_SCRIPT="$DIR/issues/issue-reply.py"
LOG_DIR="$DIR/logs"

# No run happened this tick (post-task handles the marker; double-check here).
if [[ -f "$LOG_DIR/.rested$SUF" ]]; then
  exit 0
fi

shopt -s nullglob
files=("$DELIVER_DIR"/reply-*.md)
[[ ${#files[@]} -eq 0 ]] && exit 0

TS="$(date +%Y%m%d-%H%M%S)"
for f in "${files[@]}"; do
  mid="$(basename "$f")"; mid="${mid#reply-}"; mid="${mid%.md}"
  if [[ ! "$mid" =~ ^om_ ]]; then
    echo "[$TS] post-reply: malformed reply file $(basename "$f") — removed without sending" >> "$LOG_DIR/daemon.log"
    rm -f "$f"
    continue
  fi
  if [[ ! -s "$f" ]]; then
    rm -f "$f"
    continue
  fi
  if [[ -s "$STORE" ]] && ! grep -q "\"message_id\": *\"$mid\"" "$STORE"; then
    echo "[$TS] post-reply: $mid no longer in store — reply dropped" >> "$LOG_DIR/daemon.log"
    rm -f "$f"
    continue
  fi
  if "$REPLY_SCRIPT" "$mid" < "$f" >>"$LOG_DIR/daemon.log" 2>&1; then
    echo "[$TS] post-reply: sent reply for $mid" >> "$LOG_DIR/daemon.log"
  else
    echo "[$TS] post-reply: FAILED to send reply for $mid (file consumed)" >> "$LOG_DIR/daemon.log"
  fi
  rm -f "$f"
done
