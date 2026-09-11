#!/usr/bin/env bash
# One-shot watcher: apply the exec-snapshot guard to run-task.sh as soon as no
# run holds run.lock (task #175's run-task.sh is still live — editing the file
# now would corrupt ITS byte stream the same way). Self-deletes on success.
set -u
DIR="/home/inf/hands-free-vibe"
LOG="$DIR/logs/guard-apply.log"
{
  echo "[$(date '+%F %T')] watcher started (pid $$), waiting for run.lock"
  exec 9>"$DIR/run.lock"
  flock 9
  echo "[$(date '+%F %T')] lock acquired (no live run) — patching run-task.sh"
  if python3 "$DIR/tools/.apply-exec-guard.py" && bash -n "$DIR/../lines/run-task.sh"; then
    echo "[$(date '+%F %T')] guard applied, syntax OK — self-destruct"
    flock -u 9
    rm -f "$DIR/tools/.apply-exec-guard.py" "$0"
  else
    echo "[$(date '+%F %T')] FAILED — guard NOT applied, watcher exits; manual fix needed"
    flock -u 9
  fi
} >> "$LOG" 2>&1
