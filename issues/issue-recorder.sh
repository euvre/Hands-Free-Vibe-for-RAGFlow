#!/usr/bin/env bash
# issue-recorder.sh — systemd entry for the issue-list background task.
# Does one thing per pass: append new group issues to the store; then, at the
# end, calls the prune script to drop items older than the sliding window.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="/home/inf/hands-free-vibe/logs/issues.log"

mkdir -p "$(dirname "$LOG")"
{
  echo "[$(date +%Y%m%d-%H%M%S)] record pass start"
  python3 "$DIR/issue_recorder.py"
  rc=$?
  # GitHub issue 源（source=github，gh-<number> 记录）：开关在 config
  # （GITHUB_ISSUE_ENABLED）。失败不影响飞书源的 rc。
  if grep -q '^GITHUB_ISSUE_ENABLED=1' "$DIR/config" 2>/dev/null; then
    python3 "$DIR/issue-gh-recorder.py" || true
  fi
  bash "$DIR/issue-prune.sh"
  echo "[$(date +%Y%m%d-%H%M%S)] record pass end rc=$rc"
} >> "$LOG" 2>&1
exit $rc
