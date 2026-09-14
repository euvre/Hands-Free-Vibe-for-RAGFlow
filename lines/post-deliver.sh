#!/usr/bin/env bash
# post-deliver.sh — post-run delivery: call issue-deliver.sh (no LLM) to create
# the PR from the files the main task wrote into deliver/, then reply in the
# Feishu thread with the PR link and a root-cause summary.
#
# Skipped entirely when the main task rested (no issue selected) or when the
# deliver/ files are absent (main task did not reach the delivery step, or
# failed earlier — issue-sync/post-task already handles those states).
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"  # repo root (this script lives in lines/)
source "$DIR/framework/source.sh"
SUF=""
[[ -n "${HFV_SLOT:-}" ]] && SUF="-s$HFV_SLOT"
DELIVER_DIR="$DIR/deliver$SUF"
ISSUE_FILE="$DIR/issues/current${SUF}.json"
DELIVER_SCRIPT="$DIR/issues/issue-deliver.sh"
REPLY_SCRIPT="$DIR/issues/issue-reply.py"
LOG_DIR="$DIR/logs"

mkdir -p "$LOG_DIR"

# run-task rested this tick (no issue to process, no LLM run happened).
if [[ -f "$LOG_DIR/.rested$SUF" ]]; then
  exit 0
fi

# No issue selected — nothing to deliver.
if [[ ! -s "$ISSUE_FILE" ]]; then
  echo "post-deliver: no current.json, skipped" >> "$LOG_DIR/daemon.log"
  exit 0
fi

MID="$(python3 -c "import json;print(json.load(open('$ISSUE_FILE')).get('message_id',''))" 2>/dev/null || true)"
if [[ -z "$MID" ]]; then
  echo "post-deliver: no message_id in current.json, skipped" >> "$LOG_DIR/daemon.log"
  exit 0
fi

# Ownership gate: the staged files must belong to THIS issue. run-task.sh
# stamps .owner.json when the run starts and archives foreign leftovers; this
# re-check is defense in depth: a swapped current.json must never lend one
# issue's mid to another issue's files. Mismatch or missing stamp ⇒ archive,
# never ship.
OWNER_MID="$(python3 -c "import json;print(json.load(open('$DELIVER_DIR/.owner.json')).get('message_id',''))" 2>/dev/null || true)"
if [[ "$OWNER_MID" != "$MID" ]]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  TID="$(python3 -c "import json;print(json.load(open('$ISSUE_FILE')).get('task_id') or 'unattributed')" 2>/dev/null || true)"
  TID="${TID:-unattributed}"
  if find "$DELIVER_DIR" -mindepth 1 -maxdepth 1 ! -name '.owner.json' 2>/dev/null | grep -q .; then
    DEST="$DIR/tasks/$TID/deliver-orphan-$TS"
    mkdir -p "$DEST"
    find "$DELIVER_DIR" -mindepth 1 -maxdepth 1 ! -name '.owner.json' -exec mv {} "$DEST/" \;
    echo "[$TS] post-deliver: deliver$SUF owner ($OWNER_MID) != current ($MID) — files archived to $DEST, NOT shipped" >> "$LOG_DIR/daemon.log"
  else
    echo "[$TS] post-deliver: deliver$SUF unstamped/foreign (owner=$OWNER_MID current=$MID), dir empty — skipped" >> "$LOG_DIR/daemon.log"
  fi
  rm -f "$ISSUE_FILE"
  exit 0
fi

# Deliver files must all exist and be non-empty.
BRANCH_FILE="$DELIVER_DIR/branch.txt"
MSG_FILE="$DELIVER_DIR/commit-msg.txt"
TITLE_FILE="$DELIVER_DIR/pr-title.txt"
BODY_FILE="$DELIVER_DIR/pr-body.md"

for f in "$BRANCH_FILE" "$MSG_FILE" "$TITLE_FILE" "$BODY_FILE"; do
  if [[ ! -s "$f" ]]; then
    echo "post-deliver: missing or empty $f — main task did not complete delivery prep, skipped" >> "$LOG_DIR/daemon.log"
    rm -f "$ISSUE_FILE"
    exit 0
  fi
done

# Verification screenshots: the main task stages them into deliver/shots/ and
# references them from pr-body.md as ![alt](shots/<name>). Upload to the fork's
# pr-assets release and rewrite the references to permanent URLs so they render
# inline in the PR (pure script; failures degrade to text, never block delivery).
TASK_ID="$(python3 -c "import json;print(json.load(open('$ISSUE_FILE')).get('task_id') or '')" 2>/dev/null || true)"
if [[ -d "$DELIVER_DIR/shots" ]]; then
  bash "$DIR/issues/issue-gh-shots.sh" "$BODY_FILE" "$DELIVER_DIR/shots" \
    "t${TASK_ID:-$MID}" >>"$LOG_DIR/deliver.log" 2>&1 || true
fi

BRANCH="$(cat "$BRANCH_FILE" | tr -d '[:space:]')"
TITLE="$(cat "$TITLE_FILE" | head -1)"

echo "[$(date +%Y%m%d-%H%M%S)] post-deliver: creating PR branch=$BRANCH mid=$MID" >> "$LOG_DIR/daemon.log"

PR_URL="$(bash "$DELIVER_SCRIPT" -b "$BRANCH" -m "$MSG_FILE" -t "$TITLE" -d "$BODY_FILE" -i "$MID" 2>>"$LOG_DIR/deliver.log")"
rc=$?

if [[ $rc -ne 0 || -z "$PR_URL" ]]; then
  echo "[$(date +%Y%m%d-%H%M%S)] post-deliver: issue-deliver.sh failed rc=$rc — replying failure to thread" >> "$LOG_DIR/daemon.log"
  "$REPLY_SCRIPT" "$MID" "交付失败（自动消息）：PR 创建过程出错，详见日志。代码改动已在本地备份，可手动恢复。" >> "$LOG_DIR/deliver.log" 2>&1 || true
  rm -f "$ISSUE_FILE"
  exit 0
fi

# Reply in the original thread (or as a comment on the GitHub issue for
# gh- records — issue-reply.py dispatches on the id prefix) with the PR link.
if is_gh "$MID"; then
  REPLY_TEXT="Fix proposed in $PR_URL — root-cause analysis and fix details are in the PR description; it closes this issue when merged."
else
  REPLY_TEXT="已提交 PR：$PR_URL 。根因分析及修复说明详见 PR 描述。"
fi
"$REPLY_SCRIPT" "$MID" "$REPLY_TEXT" >> "$LOG_DIR/deliver.log" 2>&1 || true

echo "[$(date +%Y%m%d-%H%M%S)] post-deliver: PR delivered $PR_URL reply sent" >> "$LOG_DIR/daemon.log"

# Delivery closes this issue's work: drop the cline-session resume file so no
# later run accidentally continues a finished conversation (see run-task.sh
# "attempt continuity").
rm -f "$LOG_DIR/.last-session-$MID"

# Archive the delivery into the task's context dir (tasks/<id>/) so a later
# follow-up run can build on the previous work.
TASK_ID="$(python3 -c "import json;print(json.load(open('$ISSUE_FILE')).get('task_id') or '')" 2>/dev/null || true)"
if [[ -n "$TASK_ID" ]]; then
  TDIR="$DIR/tasks/$TASK_ID"
  mkdir -p "$TDIR"
  echo "$PR_URL" > "$TDIR/pr"
  cp -f "$TITLE_FILE" "$TDIR/pr-title.txt" 2>/dev/null || true
  cp -f "$BODY_FILE" "$TDIR/pr-body.md" 2>/dev/null || true
fi

# Clean up the deliver dir and current.json so the next run starts fresh.
rm -rf "$DELIVER_DIR"
rm -f "$ISSUE_FILE"
