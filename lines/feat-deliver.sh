#!/usr/bin/env bash
# feat-deliver.sh — host-side publish step for the containerized feat run
# (cline-feishu-feat@<inst>.service ExecStartPost; HFV_FEAT_INST selects the
# per-instance staging dir feat/deliver-<inst>).
#
# Trust split (same as the issue line's post-deliver.sh): the in-worker LLM
# has NO git/gh credentials (gitconfig.worker is deliberately minimal); it
# stages branch + PR files under feat/deliver/ and THIS script publishes from
# the slot clone with the host's credentials:
#
#   push branch to fork → enqueue PR creation (+ci label +merge-owner reviewer)
#   into the gh outbox → the background gh-recorder creates the PR and DMs the
#   merge owner the link.
#
# Idempotent and quiet: an absent/incomplete staging dir means the feat run
# never reached delivery — one daemon.log line and exit 0 (the run log holds
# the LLM's own blocker statement; feat is human-triggered, the human reads).
set -u
DIR="$HOME/hands-free-vibe"
source "$DIR/config.sh"
LOG_DIR="$DIR/logs"
FEAT_INST="${HFV_FEAT_INST:-1}"
FDIR="$DIR/feat/deliver-$FEAT_INST"
# the feat container's worktree is removed on task end; the branch it
# committed lives on in the shared git store of the main clone.
SLOT_REPO="$RAGFLOW_MAIN"
DM="$DIR/tools/feishu-dm.py"

log() { echo "[$(date +%Y%m%d-%H%M%S)] feat-deliver: $*" >> "$LOG_DIR/daemon.log"; }
dm() { python3 "$DM" dm-owner "$1" >>"$LOG_DIR/daemon.log" 2>&1 || true; }

# --- staging gate ------------------------------------------------------------
BRANCH_FILE="$FDIR/branch.txt"
TITLE_FILE="$FDIR/pr-title.txt"
BODY_FILE="$FDIR/pr-body.md"
MSG_FILE="$FDIR/commit-msg.txt"
if [[ ! -s "$BRANCH_FILE" || ! -s "$TITLE_FILE" || ! -s "$BODY_FILE" || ! -s "$MSG_FILE" ]]; then
  log "staging incomplete/absent under $FDIR — feat run did not reach delivery; nothing published"
  [[ -d "$FDIR" ]] && dm "本次 feat 任务未产出可交付的 PR（交付文件不完整），详见日志。"
  exit 0
fi

BRANCH="$(tr -d '[:space:]' < "$BRANCH_FILE")"
TITLE="$(head -1 "$TITLE_FILE")"
[[ "$BRANCH" =~ ^[a-zA-Z0-9/_-]+$ ]] || { log "bad branch name '$BRANCH' — refused"; exit 0; }

if [[ ! -d "$SLOT_REPO/.git" ]]; then
  log "slot clone $SLOT_REPO missing — cannot publish"
  dm "feat 交付失败：slot 克隆缺失（$BRANCH 未推送，提交仍在原 worker 上下文中）。"
  exit 0
fi

# --- publish: push → PR → label/reviewer (one atomic group) -------------------
if ! git -C "$SLOT_REPO" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  log "branch $BRANCH not found in $SLOT_REPO — the worker never committed it"
  dm "feat 交付失败：分支 $BRANCH 不存在于 slot 克隆。"
  exit 0
fi

if ! git -C "$SLOT_REPO" push "$FORK_REMOTE" "refs/heads/$BRANCH:refs/heads/$BRANCH" >>"$LOG_DIR/daemon.log" 2>&1; then
  log "push to $FORK_REMOTE/$BRANCH FAILED (non-ff or network) — nothing else attempted"
  dm "feat 交付失败：push $BRANCH 被拒绝（远端已存在非快进历史？），需人工处理。"
  exit 0
fi

# PR creation (+ ci label + merge-owner reviewer + the DM with the PR link) is
# a GitHub write — enqueue it for the background gh-recorder (1-min timer,
# retried with backoff, idempotent against an existing PR for the same head).
if python3 "$DIR/lines/gh-outbox.py" pr-create --branch "$BRANCH" --title "$TITLE" \
     --body-file "$BODY_FILE" --dm-owner --reviewers "$MERGE_OWNER_LOGIN" \
     >>"$LOG_DIR/daemon.log" 2>&1; then
  log "branch pushed; PR creation enqueued (recorder DMs the merge owner the link)"
  dm "feat 任务分支已推送：$BRANCH —— PR 创建已排队，链接稍后由 gh-recorder 送达。"
else
  log "outbox enqueue FAILED for $BRANCH — nothing will create the PR"
  dm "feat 交付失败：分支已推送但 PR 创建任务未能登记（$BRANCH），需人工 gh pr create。"
fi
rm -rf "$FDIR"

exit 0
