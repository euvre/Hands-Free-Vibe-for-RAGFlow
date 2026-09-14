#!/usr/bin/env bash
# issue-deliver.sh — script task.md step 9 (delivery) end-to-end, no LLM:
#   full-tree snapshot backup → fix branch → commit → push to fork →
#   PR to origin/main + ci label + reviewer (the merge owner), applied and VERIFIED
#   (label/reviewer retried up to 3x; unverified PR is a failure).
# Prints the PR URL on stdout (exit 0) so step 10 can reply with it.
#
#   issue-deliver.sh -b <branch> -m <commit-msg-file> -t <pr-title> -d <pr-body-file> [-i <message_id>]
#
# Safety:
#   * before touching anything, the whole working tree (untracked included)
#     is snapshotted into refs/backup/deliver-<ts> — recoverable even if the
#     branch/commit steps later fail; the newest 20 snapshots are kept
#   * the branch is committed locally before any push/PR attempt
#   * PR create is idempotent: an existing PR for the head is reused
#   * every step appends to logs/deliver.log
#
# Env overrides: DELIVER_WORKDIR — post-deliver.sh passes the task's worktree
# here (REQUIRED for container-era runs; delivering at the main root swept the
# wt/ pool into PRs on 2026-09-14). For testing only: DELIVER_REMOTE,
# DELIVER_PR_REPO, DELIVER_GH (path to a gh shim).
set -euo pipefail
HFV_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$HFV_DIR/config.sh"

WORKDIR="${DELIVER_WORKDIR:-$RAGFLOW_MAIN}"
PUSH_REMOTE="${DELIVER_REMOTE:-$FORK_REMOTE}"
PR_REPO="${DELIVER_PR_REPO:-$GITHUB_REPO}"
GH="${DELIVER_GH:-gh}"
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
# Hard guard (2026-09-14): the worktree pool lives under $RAGFLOW_MAIN/wt/ and
# host-side delivery runs at the main root — a plain `git add -A` there sweeps
# every sibling worktree into the commit (PRs #19553/#19554/#19581 shipped
# 4.6k-file wt/** dumps). A delivery containing wt/ paths is ALWAYS garbage:
# abort loudly instead of pushing a polluted branch.
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
  # An empty staged set means the agent's edits never reached THIS workdir
  # (e.g. host post group delivering at the main root while the task worked in
  # a wt/ worktree). Pushing HEAD would ship an unrelated rolling tip — abort.
  echo "deliver aborted: nothing staged at $WORKDIR — the task's edits live in its worktree, not here" >&2
  log "FAILED guard: empty staged set — refusing to push the bare rolling HEAD"
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

# --- 3) PR (idempotent: reuse the existing PR for this head if any)
PR_URL="$($GH pr list --repo "$PR_REPO" --head "$FORK_REMOTE:$BRANCH" --json url --jq '.[0].url' 2>/dev/null || true)"
[[ "$PR_URL" =~ ^https:// ]] || PR_URL=""
if [[ -z "$PR_URL" ]]; then
  PR_URL="$($GH pr create --repo "$PR_REPO" --base "$PR_BASE" --head "$FORK_REMOTE:$BRANCH" \
            --title "$TITLE" --body-file "$BODY")" || {
    echo "gh pr create failed (push succeeded: $PUSH_REMOTE/$BRANCH@$SHA)" >&2
    log "FAILED pr create"
    exit 1
  }
fi
NUM="${PR_URL##*/}"
log "pr $PR_URL"

# --- 3.5) blame-informed extra reviewers (best-effort, NEVER blocks delivery):
# people who last touched the lines this PR changes and are in team-map.json.
# the merge owner stays the fixed, REQUIRED reviewer; blame picks are additive only.
EXTRA_REVIEWERS="$(python3 "$HFV_DIR/issues/deliver_blame_reviewers.py" "$WORKDIR" "origin/$PR_BASE" HEAD 2>>"$LOG" || true)"
EXTRA_REVIEWERS="${EXTRA_REVIEWERS//$'\n'/}"
log "blame reviewers: ${EXTRA_REVIEWERS:-<none>}"
REVIEWERS="$PR_REVIEWER"
[[ -n "$EXTRA_REVIEWERS" ]] && REVIEWERS="$PR_REVIEWER,$EXTRA_REVIEWERS"

# --- 4) atomic label+reviewer, verified with retry
ok=0
for i in 1 2 3; do
  $GH pr edit "$NUM" --repo "$PR_REPO" --add-label "$PR_LABEL" --add-reviewer "$REVIEWERS" >/dev/null 2>&1 || true
  VERDICT="$($GH pr view "$NUM" --repo "$PR_REPO" --json labels,reviewRequests 2>/dev/null | python3 -c '
import json, sys
want_label, want_rev = sys.argv[1], sys.argv[2]
try:
    d = json.load(sys.stdin)
except Exception:
    print("no"); raise SystemExit
ok_label = any(l.get("name") == want_label for l in d.get("labels", []))
ok_rev = any(r.get("login") == want_rev for r in d.get("reviewRequests", []))
print("yes" if ok_label and ok_rev else "no")' "$PR_LABEL" "$PR_REVIEWER" 2>/dev/null || echo no)"
  if [[ "$VERDICT" == "yes" ]]; then ok=1; break; fi
  sleep 2
done
# Extra (blame) reviewers are best-effort: GitHub silently drops requests for
# non-collaborators, so verify-and-log them WITHOUT blocking the delivery.
if [[ -n "$EXTRA_REVIEWERS" ]]; then
  GOT="$($GH pr view "$NUM" --repo "$PR_REPO" --json reviewRequests --jq '[.reviewRequests[].login] | join(",")' 2>/dev/null || true)"
  IFS=',' read -ra WANT_EXTRA <<< "$EXTRA_REVIEWERS"
  for r in "${WANT_EXTRA[@]}"; do
    case ",$GOT," in
      *,"$r",*) log "blame reviewer $r: requested ok" ;;
      *) log "blame reviewer $r: NOT in reviewRequests (likely not a collaborator) — tolerated" ;;
    esac
  done
fi
if [[ "$ok" != 1 ]]; then
  echo "label/reviewer verification failed after retries: $PR_URL" >&2
  echo "PR exists but is NOT verified ($PR_LABEL label + reviewer $PR_REVIEWER). Do not proceed to step 10; report this URL as the blocker." >&2
  log "FAILED verify pr=$PR_URL"
  exit 1
fi
log "delivered pr=$PR_URL branch=$BRANCH commit=$SHA"

echo "$PR_URL"
