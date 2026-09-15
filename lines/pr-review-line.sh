#!/usr/bin/env bash
# pr-review-line.sh — the REVIEW line of the PR follow-up (own timer, own
# lock, per-PR worktree pool wt/review-<n> on the shared ragflow4 clone).
#
# Each tick:
#   1. collect (script): all done-PRs with NEW actionable comments/reviews
#      (non-bot, non-own, not all-positive), plus the unreplied-item watchdog
#      (post-done reviewer items no own reply has @mentioned since — one-shot
#      re-queue per item; see pr-follow.py). All-positive sets are stamped
#      and skipped by the collector.
#   2. for every candidate, serially: dedicated worktree (ragflow4/wt/review-<pr>)
#      → review LLM task (pr-review-task.md, English; the invalid-comment
#      reply duty lives in the prompt: reply politely WITH the basis) →
#      stamp comment_check_at → DM every PR reviewer on Feishu
#      ("该 PR 已处理评审意见", via feishu-dm.py) → clean worktree.
# Serial inside the line; parallel with the REBASE line (same ragflow4 clone —
# separate locks, separate wt/ namespaces; git-side locks serialize fetches).
set -u
# Re-exec from a private snapshot so editing this file mid-run cannot corrupt
# the interpreter's byte stream.
if [[ -z "${HFV_EXEC_SNAPSHOT:-}" ]]; then
  HFV_EXEC_SNAPSHOT="$(mktemp /tmp/hfv-exec-snap.XXXXXX.sh)" || exit 1
  cat -- "$0" > "$HFV_EXEC_SNAPSHOT" || exit 1
  export HFV_EXEC_SNAPSHOT
  exec bash "$HFV_EXEC_SNAPSHOT" "$@"
fi
CUR_PR=""
# Kill recovery: a line killed mid-stage (CUR_PR set) drops its status file and
# stops the stage's golden container (its name carries the per-run suffix).
trap 'rm -f "$HFV_EXEC_SNAPSHOT" "${CUR_FILE:-}"; if [[ -n "${CUR_PR:-}" && -n "${DIR:-}" ]]; then docker rm -f $(docker ps -q --filter "name=-spr-review-$CUR_PR") >>"${LOG_DIR:-/dev/null}" 2>&1 || true; fi' EXIT
# Anchor to the daemon home, NOT dirname "$0": after the exec-guard re-exec
# above, $0 IS the /tmp snapshot, so dirname resolves to /tmp.
DIR="$HOME/hands-free-vibe"
LOG_DIR="$DIR/logs"
# Per-instance sharding: N parallel instances of this line (hfv scale
# review <N>) each own lock pr-review-<inst>.lock and take the candidates
# where (( (idx-1) % N == INST-1 )). Unnumbered run: INST=1, N=1 = all.
INST="${HFV_INST:-1}"
N_INST=1
[[ -f "$DIR/.scale-review" ]] && N_INST="$(cat "$DIR/.scale-review" 2>/dev/null)"
[[ "$N_INST" =~ ^[0-9]+$ && "$N_INST" -ge 1 ]] || N_INST=1
LOCK_FILE="$DIR/pr-review-$INST.lock"
CUR_FILE="$DIR/.current-review-$INST"
source "$DIR/config.sh"
CLONE="$RAGFLOW_MAIN"
WTROOT="$CLONE/wt"
TMPL="$DIR/prompts/pr-review-task.md"
DM="$DIR/tools/feishu-dm.py"
QUOTA_PATTERN='usage limit|billing cycle|quota.{0,40}(refresh|exceed|exhaust)|insufficient.{0,20}quota|使用上限|限额.{0,20}重置|额度.{0,20}(耗尽|不足)'
TRANSIENT_PATTERN='rate.?limit|too many requests|\b429\b|overloaded|temporarily unavailable|service unavailable|\b50[23]\b|try again later|high load|capacity exceeded|out of capacity|timed out|负载|限流|稍后重试'

mkdir -p "$LOG_DIR" "$WTROOT"
log() { echo "[$(date +%Y%m%d-%H%M%S)] pr-review-line: $*" >> "$LOG_DIR/daemon.log"; }

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "lock busy, skipping this tick"
  exit 0
fi

# Manual delegation (pr-follow.sh review <N>): exactly one PR, no collect.
SINGLE=()
if [[ "${1:-}" == "--single" ]]; then
  SINGLE=("$2" "$3" "$4" "${5:-}")
  CANDS="$(printf '%s\t%s\t%s\t%s' "${SINGLE[@]}")"
else
  [[ -x "$CLINE_BIN" && -s "$TMPL" ]] || { log "cline CLI or template missing, skipping"; exit 0; }
  CANDS="$(python3 "$DIR/lines/pr-follow.py" collect review 2>>"$LOG_DIR/daemon.log")"
fi
[[ -z "$CANDS" ]] && exit 0
# Model selection (incl. multi-key quota rotation) is owned by pr-llm-run.sh.
source "$DIR/lines/pr-llm-run.sh"

prepare_worktree() { # <pr-num> <branch> → echoes worktree dir
  local num="$1" branch="$2" wt="$WTROOT/review-$num"
  # fetch the PR branch first: worktree add from $FORK_REMOTE/<branch> needs the
  # ref present locally (the clone may not have seen this branch yet).
  git -C "$CLONE" fetch -q "$FORK_REMOTE" "$branch" >>"$LOG_DIR/daemon.log" 2>&1 || \
    git -C "$CLONE" fetch -q "$FORK_REMOTE" >>"$LOG_DIR/daemon.log" 2>&1 || true
  if ! git -C "$CLONE" worktree list --porcelain | grep -q "^worktree $wt$"; then
    # Self-heal: an unregistered leftover dir makes `worktree add` fail with
    # "already exists" on every later tick (half-removed worktree residue).
    git -C "$CLONE" worktree prune >>"$LOG_DIR/daemon.log" 2>&1 || true
    [[ -d "$wt" ]] && rm -rf "$wt" >>"$LOG_DIR/daemon.log" 2>&1 || true
    git -C "$CLONE" worktree add --detach "$wt" "$FORK_REMOTE/$branch" >>"$LOG_DIR/daemon.log" 2>&1 \
      || { log "worktree add failed for pr-$num"; return 1; }
    local d
    # NOTE: no .venv symlink — the e2e group builds the venv in-container
    # (glibc-matched; a host-built venv ImportErrors there).
    for d in web/node_modules; do
      [[ -e "$CLONE/$d" && ! -e "$wt/$d" ]] && ln -s "$CLONE/$d" "$wt/$d" 2>/dev/null || true
    done
  fi
  # Build the tokenizer static lib IN the worktree: upstream --run always
  # re-runs build_cpp, and a copied cmake-build-release carries the clone's
  # absolute paths in CMakeCache.txt (cmake refuses to reuse it), so the old
  # cp-prebuilt shortcut broke every e2e bring-up (PR#19221 audit rounds 2-3).
  # A fresh in-tree build also performs the ragtokre2_ rename itself.
  if [[ ! -f "$wt/internal/binding/cpp/cmake-build-release/librag_tokenizer_c_api.a" ]]; then
    ( cd "$wt" && bash build.sh --cpp ) >>"$LOG_DIR/daemon.log" 2>&1 \
      || { log "cpp build failed for pr-$num"; return 1; }
  fi
  # deepdoc models are gitignored runtime assets: the Go server's in-process
  # DeepDoc backend fails fast without them — symlink the clone's copy.
  if [[ ! -e "$wt/rag/res/deepdoc/layout.onnx" && -e "$CLONE/rag/res/deepdoc/layout.onnx" ]]; then
    rm -rf "$wt/rag/res/deepdoc"
    ln -s "$CLONE/rag/res/deepdoc" "$wt/rag/res/deepdoc"
  fi
  echo "$wt"
}

release_worktree() { # <pr-num>
  local wt="$WTROOT/pr-$1"
  git -C "$CLONE" worktree remove --force "$wt" >>"$LOG_DIR/daemon.log" 2>&1 || true
  git -C "$CLONE" worktree prune >>"$LOG_DIR/daemon.log" 2>&1 || true
  [[ -d "$wt" ]] && rm -rf "$wt" >>"$LOG_DIR/daemon.log" 2>&1 || true
}

notify_reviewers() { # <pr-num> — scriptable GitHub ops stay scripted
  local num="$1" logins
  logins="$(gh pr view "$num" --repo "$GITHUB_REPO" --json reviews,comments \
    --jq '[.reviews[].author.login, .comments[].author.login] | unique | .[]' 2>/dev/null \
    | grep -viE "^($OWN_LOGIN|bot|\[bot\]|github-actions|codecov|renovate|dependabot|coderabbit|copilot)$" || true)"
  [[ -z "$logins" ]] && { log "pr=$num: no external reviewers to notify"; return; }
  # the merge owner routing: when OTHER
  # reviewers exist, the "已处理评审意见" note goes to them only — the merge owner is
  # not spammed with per-comment progress. She is notified only when she is
  # the sole reviewer on the PR.
  local non_owner
  non_owner="$(printf '%s\n' "$logins" | grep -vi "^$MERGE_OWNER_LOGIN$" || true)"
  [[ -n "$non_owner" ]] && logins="$non_owner"
  while read -r gh_login; do
    [[ -n "$gh_login" ]] || continue
    python3 "$DM" dm "$gh_login" "该 PR 已处理评审意见：https://github.com/$GITHUB_REPO/pull/$num" \
      >>"$LOG_DIR/daemon.log" 2>&1 || true
  done <<<"$logins"
}


cand=0
while IFS=$'\t' read -r num branch url mid; do
  cand=$((cand+1)); (( (cand - 1) % N_INST == INST - 1 )) || continue
  [[ "$num" =~ ^[0-9]+$ ]] || continue
  log "review target pr=$num branch=$branch"
  CUR_PR="$num"; echo "$num" > "$CUR_FILE"
  wt="$(prepare_worktree "$num" "$branch")" || continue
  # The LLM stage runs in one throwaway golden container off the frozen base
  # (model providers baked in, services in-container). --creds: this line's
  # agent pushes the fix and comments on the PR itself (its whitelist allows).
  HFV_SLOT="pr-review-$num" PR_TMPL="pr-review-task.md" PR_TAG="review" PR_NUM="$num" PR_BRANCH="$branch" PR_URL="$url" PR_MID="$mid" \
  GH_TOKEN="$(gh auth token 2>/dev/null || true)" \
    bash "$DIR/lines/run-container.sh" --wt "$wt" --creds run-pr-main.sh
  rc=$?
  [[ -n "$mid" ]] && python3 "$DIR/lines/pr-follow.py" stamp "$mid" comment_check_at >>"$LOG_DIR/daemon.log" 2>&1 || true
  # pr_flag state machine: a successfully processed candidate means a HUMAN
  # comment was handled (collect only yields human-actionable candidates).
  # (new|fresh)→done + the merge owner report live inside mark-done.
  if [[ $rc -eq 0 || $rc -eq 124 ]] && [[ -n "$mid" ]]; then
    python3 "$DIR/lines/pr-follow.py" mark-done "$mid" "$num" "$branch" >>"$LOG_DIR/daemon.log" 2>&1 || true
  fi
  CUR_PR=""; rm -f "$CUR_FILE"
  notify_reviewers "$num"
  release_worktree "$num"
  n=$((n + 1))
done <<<"$CANDS"
log "review line done: $n PR(s) this tick"
exit 0
