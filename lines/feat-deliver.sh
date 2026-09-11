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
#   push branch to fork → gh pr create → add ci label + reviewer (the merge owner)
#   → verify both → DM the merge owner the outcome → down the slot's svc stack.
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
  # still try to idle-down the slot stack below
  bash "$DIR/lines/run-slot.sh" "${HFV_SLOT:-9}" --down >>"$LOG_DIR/daemon.log" 2>&1 || true
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
  bash "$DIR/lines/run-slot.sh" "${HFV_SLOT:-9}" --down >>"$LOG_DIR/daemon.log" 2>&1 || true
  exit 0
fi

if ! git -C "$SLOT_REPO" push "$FORK_REMOTE" "refs/heads/$BRANCH:refs/heads/$BRANCH" >>"$LOG_DIR/daemon.log" 2>&1; then
  log "push to $FORK_REMOTE/$BRANCH FAILED (non-ff or network) — nothing else attempted"
  dm "feat 交付失败：push $BRANCH 被拒绝（远端已存在非快进历史？），需人工处理。"
  bash "$DIR/lines/run-slot.sh" "${HFV_SLOT:-9}" --down >>"$LOG_DIR/daemon.log" 2>&1 || true
  exit 0
fi

PR_URL="$(gh pr create --repo "$GITHUB_REPO" --base "$PR_BASE" --head "$FORK_REMOTE:$BRANCH" \
          --title "$TITLE" --body-file "$BODY_FILE" 2>>"$LOG_DIR/daemon.log")"
if [[ -z "$PR_URL" ]]; then
  # re-runs / duplicate branches: an open PR for this head may already exist
  PR_URL="$(gh pr list --repo "$GITHUB_REPO" --head "$FORK_REMOTE:$BRANCH" --state open \
            --json url --jq '.[0].url' 2>/dev/null || true)"
fi
if [[ -z "$PR_URL" ]]; then
  log "gh pr create FAILED and no existing PR found for $FORK_REMOTE:$BRANCH"
  dm "feat 交付失败：分支已推送但 PR 创建失败（$BRANCH），需人工 gh pr create。"
  bash "$DIR/lines/run-slot.sh" "${HFV_SLOT:-9}" --down >>"$LOG_DIR/daemon.log" 2>&1 || true
  exit 0
fi
PR_NUM="${PR_URL##*/}"

# label + reviewer, then verify once; one retry (fork permission races happen)
for _ in 1 2; do
  gh pr edit "$PR_NUM" --repo "$GITHUB_REPO" --add-label ci --add-reviewer "$MERGE_OWNER_LOGIN" \
    >>"$LOG_DIR/daemon.log" 2>&1 || true
  ok_label="$(gh pr view "$PR_NUM" --repo "$GITHUB_REPO" --json labels \
              --jq '[.labels[].name] | any(. == "ci")' 2>/dev/null || echo false)"
  ok_rev="$(gh pr view "$PR_NUM" --repo "$GITHUB_REPO" --json reviewRequests \
            --jq "[.reviewRequests[].login] | any(. == \"$MERGE_OWNER_LOGIN\")" 2>/dev/null || echo false)"
  [[ "$ok_label" == "true" && "$ok_rev" == "true" ]] && break
done
[[ "$ok_label" == "true" && "$ok_rev" == "true" ]] \
  || log "pr=$PR_NUM: label/reviewer NOT both in effect after retry (label=$ok_label reviewer=$ok_rev) — fork permissions may block; noted"

log "delivered $PR_URL (branch=$BRANCH)"
dm "feat 任务已交付 PR：$PR_URL（分支 $BRANCH；ci 标签/reviewer 状态：$ok_label/$ok_rev）。"
rm -rf "$FDIR"

# Idle-down the slot's svc stack: feat is one-shot, ~8G of ES/MySQL should not
# linger until the next feat run (volumes kept — warm restart).
bash "$DIR/lines/run-slot.sh" "${HFV_SLOT:-9}" --down >>"$LOG_DIR/daemon.log" 2>&1 || true
exit 0
