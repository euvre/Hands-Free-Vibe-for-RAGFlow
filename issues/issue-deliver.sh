#!/usr/bin/env bash
# issue-deliver.sh — script task.md step 9 (delivery) end-to-end, no LLM:
#   full-tree snapshot backup → fix branch → commit → push to fork.
# PR creation + ci label + reviewers are NOT done here any more: post-deliver.sh
# enqueues them into the gh outbox and the background gh-recorder (1-min timer)
# performs the gh writes, then replies the PR link to the originating thread.
# Exit 0 = the branch is on the fork; stdout is unused.
#
#   issue-deliver.sh -b <branch> -m <commit-msg-file> -t <pr-title> -d <pr-body-file> [-i <message_id>]
#
# Safety:
#   * before touching anything, the whole working tree (untracked included)
#     is snapshotted into refs/backup/deliver-<ts> — recoverable even if the
#     branch/commit steps later fail; the newest 20 snapshots are kept
#   * the branch is committed locally before any push attempt
#   * every step appends to logs/deliver.log
#
# Env overrides: DELIVER_WORKDIR — post-deliver.sh passes the task's worktree
# here (required). For testing only: DELIVER_REMOTE.
set -euo pipefail
HFV_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$HFV_DIR/config.sh"

WORKDIR="${DELIVER_WORKDIR:-$RAGFLOW_MAIN}"
PUSH_REMOTE="${DELIVER_REMOTE:-$FORK_REMOTE}"
BACKUP_PREFIX="backup/deliver-"
LOG="${DELIVER_LOG:-$HFV_DIR/logs/deliver.log}"

usage() {
  echo "usage: issue-deliver.sh -b <branch> -m <commit-msg-file> -t <pr-title> -d <pr-body-file> [-i <message_id>]" >&2
  exit 1
}

BRANCH=""; MSG=""; TITLE=""; BODY=""; MID=""
while getopts ":b:m:t:d:i:" o; do
  case $o in
    b) BRANCH=$OPTARG ;;
    m) MSG=$OPTARG ;;
    t) TITLE=$OPTARG ;;
    d) BODY=$OPTARG ;;
    i) MID=$OPTARG ;;
    *) usage ;;
  esac
done
[[ -z "$BRANCH" || -z "$MSG" || -z "$TITLE" || -z "$BODY" ]] && usage
[[ -s "$MSG" ]] || { echo "commit message file missing or empty: $MSG" >&2; exit 1; }
[[ -s "$BODY" ]] || { echo "PR body file missing or empty: $BODY" >&2; exit 1; }
[[ "$BRANCH" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]*$ ]] || { echo "invalid branch name: $BRANCH" >&2; exit 1; }

cd "$WORKDIR"
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "$(dirname "$LOG")"
log() { echo "[$TS] mid=${MID:-} $*" >> "$LOG"; }

# --- 0) snapshot backup: index (incl. untracked after add -A) → tree → commit → ref
git add -A
# Guard: the task-worktree pool lives under $RAGFLOW_MAIN/wt/, inside the repo —
# a delivery staged at the wrong directory would sweep it into the commit.
# A delivery containing wt/ paths is always garbage: abort, never push it.
if git diff --cached --name-only | grep -q '^wt/'; then
  echo "deliver aborted: staged changes include wt/ worktree paths — the delivery is running at the repo root, not the task worktree" >&2
  log "FAILED guard: wt/ paths staged (worktree sweep) — delivery aborted"
  exit 1
fi
TREE=$(git write-tree)
BACKUP_COMMIT=$(git commit-tree "$TREE" -p HEAD -m "backup: pre-deliver snapshot $TS")
git update-ref "refs/${BACKUP_PREFIX}${TS}" "$BACKUP_COMMIT"
# keep the newest 20 backup refs only
git for-each-ref --format='%(refname)' "refs/${BACKUP_PREFIX}*" | sort | head -n -20 \
  | while read -r ref; do git update-ref -d "$ref"; done
log "backup refs/${BACKUP_PREFIX}${TS}=$(git rev-parse --short "$BACKUP_COMMIT")"

# --- 1) branch + commit (staged work rides along; skip commit if tree is clean)
# NOTE: this script assumes the worktree was cleaned by the pre-run stage
# (run-task.sh pre-clean): pristine origin/main, empty index. Leftover-state
# recovery belongs there, not here.
# Stale-branch recovery: a branch left behind by a
# FAILED delivery of an earlier attempt makes `git checkout $BRANCH` abort on
# the new attempt's staged changes ("would be overwritten by checkout"),
# turning one transient failure into a permanent one. The stale branch's
# commit is already preserved in the refs/backup/deliver-* snapshot above, so
# deleting and recreating the branch from HEAD loses nothing.
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  if ! git checkout -q "$BRANCH" 2>>"$LOG"; then
    log "branch $BRANCH: checkout conflicted with staged work — dropping stale branch (kept in refs/backup/deliver-*)"
    git branch -D "$BRANCH" >>"$LOG" 2>&1
    git checkout -qb "$BRANCH"
  fi
else
  git checkout -qb "$BRANCH"
fi
if git diff --cached --quiet; then
  # An empty staged set means the task's edits never reached this workdir;
  # pushing HEAD would ship an unrelated tip. Abort.
  echo "deliver aborted: nothing staged at $WORKDIR — the task's edits live in its worktree, not here" >&2
  log "FAILED guard: empty staged set — refusing to push the bare HEAD"
  exit 1
else
  git commit -q -F "$MSG"
fi
SHA=$(git rev-parse --short HEAD)
log "branch $BRANCH commit $SHA"

# --- 2) push (retry: transient TLS/network failures must not kill a delivery)
pushed=0
for i in 1 2 3; do
  if git push -u "$PUSH_REMOTE" "$BRANCH" >>"$LOG" 2>&1; then
    pushed=1
    break
  fi
  log "push attempt $i failed (see stderr above); backing off 5s"
  sleep 5
done
if [[ "$pushed" != 1 ]]; then
  echo "push to $PUSH_REMOTE/$BRANCH failed" >&2
  log "FAILED push"
  exit 1
fi

# --- 3) PR creation is NOT done here: the gh write belongs to the background
# gh-recorder (outbox kind pr_create, drained within a minute). This script's
# contract ends at "branch pushed"; post-deliver.sh enqueues the PR creation
# (with title/body/mid/reviewers) and the recorder replies the PR link to the
# originating thread. Idempotency (reusing an existing PR for the same head)
# lives in the recorder's pr_create handler.
log "pushed branch=$BRANCH commit=$SHA (PR creation delegated to gh-recorder)"
