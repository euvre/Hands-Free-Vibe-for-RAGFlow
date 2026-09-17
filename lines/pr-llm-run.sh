#!/usr/bin/env bash
# pr-llm-run.sh — shared LLM-stage runner for the PR follow-up lines.
# Sourced (not executed) by pr-rebase-line.sh / pr-review-line.sh.
#
# Why a shared helper: both line scripts need the exact same "launch one
# cline stage" machinery — prompt placeholder substitution, per-attempt log
# file, hard timeout, and quota/transient retry classification (identical to
# run-task.sh's semantics). Previously that code lived as two near-identical
# run_llm() copies (differing only in the log tag); this file is the single
# home for it.
#
# Provides:
#   run_llm <tmpl> <timeout-s> <tag> <worktree> <pr-num> <branch> <url> <mid>
# Template placeholders substituted before launch:
#   __PR_URL__ __PR_NUM__ __BRANCH__ __MID__ __WORKDIR__
# Requires globals from the caller: LOG_DIR, CLINE_BIN.
# (Model selection is owned HERE since the multi-key rotation: MODEL_BASE
# carries -P/-m and run_llm rotates -k across API_KEYS on quota failures —
# an exhausted key is swapped immediately, the billing-cycle wait engages
# only once the whole list is drained. Key material is never logged.)

# Site config (retry timings): loaded from the repo root regardless of the
# sourcing caller's own paths.
_PR_LLM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"  # repo root (this file lives in lines/)
source "$_PR_LLM_DIR/config.sh"

MODEL_BASE="$(python3 "$_PR_LLM_DIR/tools/model-profile.py" args-base)" || return 1
mapfile -t API_KEYS < <(python3 "$_PR_LLM_DIR/tools/model-profile.py" keylist)
((${#API_KEYS[@]})) || { echo "pr-llm-run: no api keys for the current profile" >&2; return 1; }

# Manual-unlock flags: `hfv pr unlock <line>` writes pr-unlock-<tag>.flag
# here; run_llm's wait loop consumes it and retries immediately WITHOUT
# consuming the retry budget. Same repo root as hfv.sh's DIR by default;
# overridable for isolated tests.
HFV_UNLOCK_FLAG_DIR="${HFV_UNLOCK_FLAG_DIR:-$_PR_LLM_DIR}"

# LLM availability failure classes (retry waiting never consumes the
# per-attempt timeout). Match both English and the provider's Chinese
# variants (e.g. "已达到 5 小时的使用上限。您的限额将在 … 重置。").
QUOTA_PATTERN='usage limit|billing cycle|quota.{0,40}(refresh|exceed|exhaust)|insufficient.{0,20}quota|使用上限|限额.{0,20}重置|额度.{0,20}(耗尽|不足)'
TRANSIENT_PATTERN='rate.?limit|too many requests|\b429\b|overloaded|temporarily unavailable|service unavailable|\b50[23]\b|try again later|high load|capacity exceeded|out of capacity|timed out|负载|限流|稍后重试'

pr_log() { echo "[$(date +%Y%m%d-%H%M%S)] ${LLM_TAG:-pr-llm}: $*" >> "$LOG_DIR/daemon.log"; }

# ---------------------------------------------------------------------------
# Host-side push ownership. Since the outbox migration the in-container agent
# only COMMITS (containers carry no credentials); the push is the line's job,
# done HERE: enqueued after the LLM stage, executed by gh-recorder with the
# host's credentials, and the worktree provably outlives it — the recorder
# refuses a push whose worktree is gone (_is_pool_worktree), so a push the
# agent used to enqueue seconds before stage end died on the next tick.
line_push_record() { # <worktree> <branch> [--force-with-lease] → echoes record id; rc 0 enqueued / 2 nothing-to-push / 1 enqueue failed
  local wt="$1" branch="$2" fwl="${3:-}" id
  # an unfinished rebase/merge or an unmoved HEAD = nothing to push
  if git -C "$wt" rev-parse --verify REBASE_HEAD >/dev/null 2>&1 \
     || git -C "$wt" rev-parse --verify MERGE_HEAD >/dev/null 2>&1; then
    pr_log "line_push: $wt mid-rebase/merge — not pushing"
    return 2
  fi
  git -C "$wt" rev-parse --verify HEAD >/dev/null 2>&1 || return 2
  git -C "$wt" merge-base --is-ancestor HEAD "$FORK_REMOTE/$branch" 2>/dev/null && return 2
  local args=(push --worktree "$wt" --branch "$branch")
  [[ -n "$fwl" ]] && args+=(--force-with-lease)
  id="$(python3 "$_PR_LLM_DIR/lines/gh-outbox.py" "${args[@]}")" || { pr_log "line_push: enqueue failed for $wt"; return 1; }
  printf '%s' "$id"
  return 0
}

wait_outbox_record() { # <record-id> → 0 done / 1 failed-or-timeout
  local id="$1" i
  for i in $(seq 1 60); do   # the recorder ticks every minute; a ~5 min cap never wedges a line
    [[ -f "$_PR_LLM_DIR/lines/gh-outbox/done/$id.json" ]] && return 0
    [[ -f "$_PR_LLM_DIR/lines/gh-outbox/failed/$id.json" ]] && return 1
    sleep 5
  done
  pr_log "wait_outbox_record: $id still pending after ~5 min"
  return 1
}

run_llm() { # <tmpl> <timeout-s> <tag> <worktree> <pr-num> <branch> <url> <mid>
  local tmpl="$1" tmo="$2" tag="$3" wt="$4" num="$5" branch="$6" url="$7" mid="$8"
  local manual_note=""
  LLM_TAG="pr-$tag-line"
  # new LLM stage: reclaim MCP servers leaked by finished runs (orphans only)
  bash "$_PR_LLM_DIR/framework/mcp-cleanup.sh"
  local run_log="$LOG_DIR/run-pr-$tag-$(date +%Y%m%d-%H%M%S).log"
  local prompt
  prompt="$(sed -e "s|__PR_URL__|$url|g" -e "s|__PR_NUM__|$num|g" \
                -e "s|__BRANCH__|$branch|g" -e "s|__MID__|$mid|g" \
                -e "s|__WORKDIR__|$wt|g" \
                -e "s|__GITHUB_REPO__|$GITHUB_REPO|g" \
                -e "s|__FORK_REMOTE__|$FORK_REMOTE|g" \
                -e "s|__MERGE_OWNER_LOGIN__|$MERGE_OWNER_LOGIN|g" \
                -e "s|__PR_BASE__|$PR_BASE|g" \
                -e "s|__HFV_DIR__|$_PR_LLM_DIR|g" "$tmpl")"
  # Framework pre-flight section (optional): a line that pre-launches services
  # (env-up.sh) hands the rendered status section over via ENV_STATUS_SECTION;
  # appended right after the template so the "already done — do not redo"
  # note sits next to the task rules.
  [[ -n "${ENV_STATUS_SECTION:-}" ]] && prompt="$prompt

$ENV_STATUS_SECTION"
  local rc=0 attempt=0 qw=0 tw=0 ow=0 key_idx=0
  : > "$run_log"
  while true; do
    attempt=$((attempt + 1))
    local sl; sl=$(wc -l < "$run_log")
    {
      echo "=== pr-$tag started $(date -Is) pr=$url attempt=$attempt${manual_note} wt=$wt ==="
      manual_note=""
      # < /dev/null: cline (node) otherwise inherits the caller loop's stdin
      # (the <<<"$CANDS" here-string in pr-review-line.sh / pr-rebase-line.sh)
      # and consumes the remaining candidate lines — the classic bash trap that
      # silently caps the loop at ONE PR per tick.
      timeout "$tmo" "$CLINE_BIN" --json --cwd "$wt" -t "$tmo" \
        --auto-approve true $MODEL_BASE -k "${API_KEYS[$key_idx]}" "$prompt" < /dev/null
      rc=$?
      echo "=== pr-$tag finished $(date -Is) exit=$rc attempt=$attempt ==="
    } >> "$run_log" 2>&1
    # rc=0: done. rc=124: our own hard cap fired — real work happened, do not
    # relaunch inside this stage (the cooldown stamp still applies).
    if [[ $rc -eq 0 || $rc -eq 124 ]]; then break; fi
    # error-channel lines only (see run-task.sh: whole-log grep matches
    # prompt text quoting "quota exhausted"); every class retries here,
    # incl. "other" (CLI bugs / pre-JSON crashes) — a relaunch is cheap.
    local kind=""
    local errl
    errl="$(tail -n "+$((sl + 1))" "$run_log" | grep -E '"type":"error"|agent_error' || true)"
    if grep -qiE "$QUOTA_PATTERN" <<<"$errl"; then
      kind=quota; local ws=$QUOTA_RETRY_SECONDS; local wd=$qw; local mw=$QUOTA_MAX_WAIT_SECONDS
    elif grep -qiE "$TRANSIENT_PATTERN" <<<"$errl"; then
      kind=transient; local ws=$TRANSIENT_RETRY_SECONDS; local wd=$tw; local mw=$TRANSIENT_MAX_WAIT_SECONDS
    else
      kind=other; local ws=$OTHER_RETRY_SECONDS; local wd=$ow; local mw=$OTHER_MAX_WAIT_SECONDS
    fi
    # Multi-key rotation: quota → next key, retried NOW (no wait, no budget
    # consumed). The interruptible billing-cycle wait below engages only once
    # the whole list is drained (and that wait refreshes key #1's quota too).
    if [[ "$kind" == quota && $((key_idx + 1)) -lt ${#API_KEYS[@]} ]]; then
      key_idx=$((key_idx + 1))
      pr_log "pr=$num: quota exhausted on key #$key_idx — rotating to key #$((key_idx + 1))/${#API_KEYS[@]}, retrying NOW (no wait)"
      continue
    fi
    if [[ "$kind" == quota && ${#API_KEYS[@]} -gt 1 ]]; then
      pr_log "pr=$num: all ${#API_KEYS[@]} keys quota-exhausted — billing-cycle wait engaged"
      key_idx=0
    fi
    if (( wd >= mw )); then
      pr_log "pr=$num: LLM $kind failure persists after ${wd}s, giving up"
      break
    fi
    pr_log "pr=$num: LLM $kind failure (attempt $attempt), waiting ${ws}s"
    # Interruptible wait: sleep in ≤15s slices so `hfv pr unlock <line>` can
    # cut it short via the flag file (it also kills the running slice for an
    # immediate effect). A manual unlock retries right away WITHOUT consuming
    # the retry budget — the $kind wait accumulator is only bumped after a
    # FULL auto-wait — and is distinctly logged as MANUAL UNLOCK in both
    # daemon.log and the run log, so it never reads as an automatic retry.
    local flag="$HFV_UNLOCK_FLAG_DIR/pr-unlock-$tag.flag"
    local slept=0 manual=0 fts
    while (( slept < ws )); do
      local chunk=$(( ws - slept )); (( chunk > 15 )) && chunk=15
      sleep "$chunk"; slept=$(( slept + chunk ))
      [[ -f "$flag" ]] || continue
      fts="$(head -n1 "$flag" 2>/dev/null || echo 0)"
      rm -f "$flag"
      if (( $(date +%s) - fts <= 300 )); then manual=1; break; fi
      pr_log "pr=$num: stale unlock flag ignored (age $(($(date +%s) - fts))s)"
    done
    if (( manual )); then
      manual_note=" (manual-unlock)"
      pr_log "pr=$num: MANUAL UNLOCK — auto-wait cut at ${slept}s/${ws}s, retrying NOW, retry budget NOT consumed"
      echo "=== pr-$tag manual-unlock $(date -Is): auto-wait cut at ${slept}s/${ws}s (attempt $attempt; retry budget NOT consumed) ===" >> "$run_log"
    else
      if [[ "$kind" == quota ]]; then qw=$((qw + ws)); elif [[ "$kind" == transient ]]; then tw=$((tw + ws)); else ow=$((ow + ws)); fi
    fi
  done
  pr_log "pr=$num $tag stage exit=$rc attempts=$attempt log=$run_log"
  return "$rc"
}
