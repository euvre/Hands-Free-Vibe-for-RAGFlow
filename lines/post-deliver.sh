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
source "$DIR/config.sh"  # PR_BASE/PR_REVIEWER/FORK_REMOTE for the outbox record
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

# --- worktree resolution: commit in the task's worktree, never the main root --
# run-task.sh stamps the task's worktree into .owner.json; run-container.sh
# keeps that worktree when a delivery is staged. The legacy host line stamps
# the main root itself, which is where host-line edits live.
WORKTREE="$(python3 -c "import json;print(json.load(open('$DELIVER_DIR/.owner.json')).get('worktree') or '')" 2>/dev/null || true)"
drop_worktree() {
  # only ever drop wt/ pool worktrees — never the main clone root
  case "$WORKTREE" in */wt/*) ;; *) return 0 ;; esac
  [[ -d "$WORKTREE" ]] || return 0
  git -C "$RAGFLOW_MAIN" worktree remove --force "$WORKTREE" >>"$LOG_DIR/daemon.log" 2>&1 || true
  git -C "$RAGFLOW_MAIN" worktree prune >>"$LOG_DIR/daemon.log" 2>&1 || true
}

# Deliver files must all exist and be non-empty.
BRANCH_FILE="$DELIVER_DIR/branch.txt"
MSG_FILE="$DELIVER_DIR/commit-msg.txt"
TITLE_FILE="$DELIVER_DIR/pr-title.txt"
BODY_FILE="$DELIVER_DIR/pr-body.md"

for f in "$BRANCH_FILE" "$MSG_FILE" "$TITLE_FILE" "$BODY_FILE"; do
  if [[ ! -s "$f" ]]; then
    echo "post-deliver: missing or empty $f — main task did not complete delivery prep, skipped" >> "$LOG_DIR/daemon.log"
    drop_worktree
    rm -f "$ISSUE_FILE"
    exit 0
  fi
done

# The delivery must commit the task worktree; without a valid stamp there is
# nowhere safe to commit — refuse rather than fall back to the main root.
if [[ -z "$WORKTREE" || ! -d "$WORKTREE" || ! -e "$WORKTREE/.git" ]]; then
  echo "post-deliver: no valid worktree in owner stamp ('$WORKTREE') — NOT delivering at the main root" >> "$LOG_DIR/daemon.log"
  "$REPLY_SCRIPT" "$MID" "交付失败（自动消息）：任务 worktree 记录缺失或已回收，未交付。改动备份在 refs/backup/ 中，可手动恢复。" >> "$LOG_DIR/deliver.log" 2>&1 || true
  rm -f "$ISSUE_FILE"
  exit 0
fi

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

echo "[$(date +%Y%m%d-%H%M%S)] post-deliver: pushing branch=$BRANCH mid=$MID" >> "$LOG_DIR/daemon.log"

DELIVER_WORKDIR="$WORKTREE" bash "$DELIVER_SCRIPT" -b "$BRANCH" -m "$MSG_FILE" -t "$TITLE" -d "$BODY_FILE" -i "$MID" >>"$LOG_DIR/deliver.log" 2>&1
rc=$?

if [[ $rc -ne 0 ]]; then
  echo "[$(date +%Y%m%d-%H%M%S)] post-deliver: issue-deliver.sh failed rc=$rc — replying failure to thread" >> "$LOG_DIR/daemon.log"
  "$REPLY_SCRIPT" "$MID" "交付失败（自动消息）：PR 创建过程出错，详见日志。代码改动已在本地备份（refs/backup/deliver-*，取自任务 worktree 的真实改动），可手动恢复。" >> "$LOG_DIR/deliver.log" 2>&1 || true
  drop_worktree
  rm -f "$ISSUE_FILE"
  exit 0
fi

# The branch is on the fork. PR creation (+ ci label + reviewers + the PR-link
# reply to the originating thread) is a GitHub write — enqueue it for the
# background gh-recorder (drained within a minute, retried with backoff).
# Blame-informed extra reviewers are computed NOW, while the task worktree
# still exists; the merge owner stays the fixed first reviewer.
EXTRA_REVIEWERS="$(python3 "$DIR/issues/deliver_blame_reviewers.py" "$WORKTREE" "origin/$PR_BASE" HEAD 2>>"$LOG_DIR/deliver.log" || true)"
EXTRA_REVIEWERS="${EXTRA_REVIEWERS//$'\n'/}"
REVIEWERS="$PR_REVIEWER"
[[ -n "$EXTRA_REVIEWERS" ]] && REVIEWERS="$PR_REVIEWER,$EXTRA_REVIEWERS"
TASK_ID="$(python3 -c "import json;print(json.load(open('$ISSUE_FILE')).get('task_id') or '')" 2>/dev/null || true)"
if python3 "$DIR/lines/gh-outbox.py" pr-create --branch "$BRANCH" --title "$TITLE" \
     --body-file "$BODY_FILE" --mid "$MID" --task-id "$TASK_ID" \
     --reviewers "$REVIEWERS" >>"$LOG_DIR/daemon.log" 2>&1; then
  echo "[$(date +%Y%m%d-%H%M%S)] post-deliver: PR creation enqueued branch=$BRANCH (recorder replies the PR link)" >> "$LOG_DIR/daemon.log"
  # Delivery is terminal LOCALLY, right now: flip the store record to done
  # without waiting for the PR-link reply + next sync pass. The next tick's
  # issue-select must never re-pick this record (tasks 346/347 → duplicate
  # PRs #19853/#19857 happened inside that window).
  python3 "$DIR/issues/issue-mark-done.py" "$MID" "$BRANCH" >>"$LOG_DIR/daemon.log" 2>&1 || true
else
  # local enqueue failure — nothing will create the PR; report it now
  echo "[$(date +%Y%m%d-%H%M%S)] post-deliver: outbox enqueue FAILED for branch=$BRANCH" >> "$LOG_DIR/daemon.log"
  "$REPLY_SCRIPT" "$MID" "交付失败（自动消息）：分支已推送但 PR 创建任务未能登记，详见日志。分支 $BRANCH 已在远端，可手动建 PR。" >> "$LOG_DIR/deliver.log" 2>&1 || true
fi

echo "[$(date +%Y%m%d-%H%M%S)] post-deliver: branch pushed, PR pending in outbox (mid=$MID)" >> "$LOG_DIR/daemon.log"

# Delivery closes this issue's work: drop the cline-session resume file so no
# later run accidentally continues a finished conversation (see run-task.sh
# "attempt continuity").
rm -f "$LOG_DIR/.last-session-$MID"

# Archive the delivery into the task's context dir (tasks/<id>/) so a later
# follow-up run can build on the previous work. The pr url file is written by
# the gh-recorder when the PR actually exists; title/body are staged now.
if [[ -n "$TASK_ID" ]]; then
  TDIR="$DIR/tasks/$TASK_ID"
  mkdir -p "$TDIR"
  cp -f "$TITLE_FILE" "$TDIR/pr-title.txt" 2>/dev/null || true
  cp -f "$BODY_FILE" "$TDIR/pr-body.md" 2>/dev/null || true
fi

# Clean up the deliver dir, current.json and the task worktree so the next run
# starts fresh (the backup ref written before commit keeps the work recoverable).
drop_worktree
rm -rf "$DELIVER_DIR"
rm -f "$ISSUE_FILE"
