#!/usr/bin/env bash
# post-scan.sh — scan 线 post 组：任务结束后按序执行的收尾作业（单项失败不阻塞）。
#  1. 结果回写 scan/state.json（桶命中率 / 零命中计数 / 窗口自适应扩张）
#  2. 复现成功 → report.md 发飞书群（scan-notify.py，新消息；扫描线没有原话题）
#  3. 交付产物齐全 → feat 线同款发布：push 分支到 fork → gh outbox 排队建 PR
#     （--dm-owner 把 PR 链接 DM 给合并负责人，recorder 落盘 tasks/<id>/pr）
#     → 等到 PR 链接后发群消息补链
#  4. 归档 deliver → scan/archive/<scan_id>/，清 current-N.json
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"  # repo root (this script lives in lines/)
source "$DIR/config.sh"
SLOT="${HFV_SCAN_INST:-1}"
LOG_DIR="$DIR/logs"
LOG="$LOG_DIR/daemon.log"
CUR="$DIR/scan/current-$SLOT.json"
DELIVER="$DIR/scan/deliver-$SLOT"
NOTIFY="python3 $DIR/scan/scan-notify.py"

log() { echo "[$(date +%Y%m%d-%H%M%S)] post-scan: $*" >> "$LOG"; }
# SCAN_POST_DRY=1: 演练模式 —— 群通知与 GitHub 写入全部只记日志不执行
# （窗口状态回写照常，它本来就是本地状态）。
DRY="${SCAN_POST_DRY:-}"
notify() {
  if [[ "$DRY" == 1 ]]; then log "DRY notify: ${1:0:120}…"; return 0; fi
  $NOTIFY "$1" >>"$LOG" 2>&1 || log "group notify FAILED (rc=$?): ${1:0:80}…"
}

# run-scan rested this tick (no batch selected, no LLM run): consume the
# marker and skip entirely.
if [[ -f "$LOG_DIR/.rested-scan-$SLOT" ]]; then
  rm -f "$LOG_DIR/.rested-scan-$SLOT"
  log "skipped (tick rested, no run)"
  exit 0
fi

[[ -s "$CUR" ]] || { log "no current-$SLOT.json — nothing to settle"; exit 0; }
SCAN_ID="$(python3 -c "import json;print(json.load(open('$CUR')).get('scan_id',''))" 2>/dev/null || true)"
SCAN_ID="${SCAN_ID:-scan-unknown-$SLOT}"
OUTCOME="$(python3 -c "import json;print(json.load(open('$DELIVER/result.json')).get('outcome',''))" 2>/dev/null || true)"
OUTCOME="${OUTCOME:-unknown}"

# 1. fold the outcome into the adaptive-window state (bucket stats, zero-hit
#    streak, auto expansion) — runs for every outcome including unknown.
python3 "$DIR/scan/scan-select.py" report --slot "$SLOT" >>"$LOG" 2>&1 || true

# 2. group report for a reproduced bug
if [[ "$OUTCOME" == reported && -s "$DELIVER/report.md" ]]; then
  # backstop for the report.md backfill acceptance check (scan-task.md step 7):
  # placeholder wording left in the file means the agent shipped a mid-work
  # draft — still send (the reproduction body is valuable), but warn loudly.
  if grep -qE '待 step 7 回填|修复后更新|见下方|待补充|TBD' "$DELIVER/report.md"; then
    log "$SCAN_ID: WARN report.md still has placeholder sections (backfill missed) — sending anyway"
  fi
  notify "【bug 扫描】$SCAN_ID 复现并确认了一个仓库缺陷：

$(cat "$DELIVER/report.md")"
fi

# 3. delivery (feat-line mode): the in-container agent already committed the
#    fix on its branch; the host publishes. Incomplete staging = the run never
#    reached delivery — say so when a reproduced bug lost its fix.
BRANCH_FILE="$DELIVER/branch.txt"
TITLE_FILE="$DELIVER/pr-title.txt"
BODY_FILE="$DELIVER/pr-body.md"
MSG_FILE="$DELIVER/commit-msg.txt"
BRANCH=""
[[ -s "$BRANCH_FILE" ]] && BRANCH="$(tr -d '[:space:]' < "$BRANCH_FILE")"

if [[ -s "$TITLE_FILE" && -s "$BODY_FILE" && -s "$MSG_FILE" && -n "$BRANCH" \
      && "$BRANCH" =~ ^[a-zA-Z0-9/_-]+$ ]] \
   && git -C "$RAGFLOW_MAIN" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  if [[ "$DRY" == 1 ]]; then
    log "DRY delivery: would push $BRANCH and enqueue pr-create (task-id $SCAN_ID)"
  elif git -C "$RAGFLOW_MAIN" push "$FORK_REMOTE" "refs/heads/$BRANCH:refs/heads/$BRANCH" >>"$LOG" 2>&1; then
    if python3 "$DIR/lines/gh-outbox.py" pr-create --branch "$BRANCH" \
         --title "$(head -1 "$TITLE_FILE")" --body-file "$BODY_FILE" \
         --dm-owner --task-id "$SCAN_ID" --reviewers "$MERGE_OWNER_LOGIN" >>"$LOG" 2>&1; then
      log "$SCAN_ID: branch $BRANCH pushed, PR creation enqueued"
      # wait (bounded) for the recorder to land the PR, then append the link
      # to the group report thread of this scan round
      PR_FILE="$DIR/tasks/$SCAN_ID/pr"
      for _ in $(seq 1 15); do [[ -s "$PR_FILE" ]] && break; sleep 10; done
      if [[ -s "$PR_FILE" ]]; then
        notify "【bug 扫描】$SCAN_ID 修复已交付 PR：$(cat "$PR_FILE")（分支 $BRANCH）"
      else
        notify "【bug 扫描】$SCAN_ID 分支 $BRANCH 已推送，PR 创建排队中（gh-recorder 稍后送达）。"
      fi
    else
      log "$SCAN_ID: outbox enqueue FAILED for $BRANCH"
      notify "【bug 扫描】$SCAN_ID 交付失败：分支 $BRANCH 已推送但 PR 创建未能登记，需人工 gh pr create。"
    fi
  else
    log "$SCAN_ID: push to $FORK_REMOTE/$BRANCH FAILED"
    notify "【bug 扫描】$SCAN_ID 交付失败：push $BRANCH 被拒绝（非快进/网络），需人工处理。"
  fi
elif [[ "$OUTCOME" == reported ]]; then
  log "$SCAN_ID: reported but staging incomplete (branch='$BRANCH') — fix not published"
  notify "【bug 扫描】$SCAN_ID 已复现确认缺陷，但修复交付不完整（分支/PR 文件缺失），详见日志。"
fi

# 4. archive + clean
ARCHIVE="$DIR/scan/archive/$SCAN_ID-$(date +%H%M%S)"
if [[ -d "$DELIVER" ]] && [[ -n "$(ls -A "$DELIVER" 2>/dev/null)" ]]; then
  mkdir -p "$ARCHIVE"
  cp -a "$DELIVER"/. "$ARCHIVE"/ 2>/dev/null || true
fi
rm -rf "$DELIVER"
rm -f "$CUR"
log "$SCAN_ID settled (outcome=$OUTCOME, archived=$(basename "$ARCHIVE"))"
exit 0
