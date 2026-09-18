#!/usr/bin/env bash
# post-sheet.sh — write the delivery back to the Feishu issue sheet once the
# PR actually exists. post-deliver.sh only ENQUEUES the PR creation into the
# outbox; gh-recorder lands it within a minute and drops tasks/<task_id>/pr.
# Wait for that file (bounded), then fill the sheet (PR link into 备注,
# 研发负责 <- @肖毅 when empty). Bugs not registered in the sheet are left
# alone by issue-sheet.py. A timeout here is backstopped by issue-sync.sh's
# done-flip, which re-runs the same fill once the PR link shows in the thread.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"  # repo root (this script lives in lines/)
SUF=""
[[ -n "${HFV_SLOT:-}" ]] && SUF="-s$HFV_SLOT"
CUR="$DIR/issues/current${SUF}.json"
[[ -s "$CUR" ]] || exit 0

# no deliverables staged this run (task ended before the deliver step) — the
# wait below would be pure waste; nothing to write back either way.
[[ -n "$(ls -A "$DIR/deliver$SUF" 2>/dev/null)" ]] || exit 0

read -r MID TID <<<"$(python3 -c "import json;d=json.load(open('$CUR'));print(d.get('message_id',''),d.get('task_id') or '')" 2>/dev/null || true)"
[[ -n "${MID:-}" && -n "${TID:-}" ]] || exit 0
case "$MID" in om_*) ;; *) exit 0 ;; esac  # gh- records have no Feishu sheet row

PR_FILE="$DIR/tasks/$TID/pr"
for _ in $(seq 1 15); do
  [[ -s "$PR_FILE" ]] && break
  sleep 10
done
[[ -s "$PR_FILE" ]] || exit 0  # outbox slow — issue-sync's done-flip backstops

python3 "$DIR/issues/issue-sheet.py" deliver "$MID" "$(cat "$PR_FILE")" \
  >>"$DIR/logs/daemon.log" 2>&1 || true
