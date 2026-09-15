#!/usr/bin/env bash
# pr-rebase-line.sh — the REBASE line of the PR follow-up (own timer, own
# lock, per-PR worktree pool wt/rebase-<n> on the shared ragflow4 clone).
#
# Each tick:
#   1. collect (script): all conflicted done-PRs outside the 4h cooldown.
#      Conflict-free PRs never enter (the task's whole point is conflicts;
#      conflict-free rebases are handled by the manual fast-path / CI).
#   2. for every candidate, serially: prepare a dedicated worktree
#      (ragflow4/wt/rebase-<pr>) → run the rebase LLM task (pr-rebase-task.md,
#      English) → stamp rebase_fix_at (win or lose) → clean the worktree.
# Serial inside the line (one LLM at a time protects quota and the shared
# clone); parallel with the REVIEW line (same ragflow4 clone — separate lock,
# separate namespace: wt/rebase-<n> here vs wt/review-<n> there).
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
trap 'rm -f "$HFV_EXEC_SNAPSHOT" "${CUR_FILE:-}"; if [[ -n "${CUR_PR:-}" && -n "${DIR:-}" ]]; then docker rm -f $(docker ps -q --filter "name=-spr-rebase-$CUR_PR") >>"${LOG_DIR:-/dev/null}" 2>&1 || true; fi' EXIT
# Anchor to the daemon home, NOT dirname "$0": after the exec-guard re-exec
# above, $0 IS the /tmp snapshot, so dirname resolves to /tmp.
# Same convention as run-task.sh.
DIR="$HOME/hands-free-vibe"
LOG_DIR="$DIR/logs"
# Per-instance sharding: N parallel instances of this line (hfv scale
# rebase <N>) each own lock pr-rebase-<inst>.lock and take the candidates
# where (( (idx-1) % N == INST-1 )). Unnumbered run: INST=1, N=1 = all.
INST="${HFV_INST:-1}"
N_INST=1
[[ -f "$DIR/.scale-rebase" ]] && N_INST="$(cat "$DIR/.scale-rebase" 2>/dev/null)"
[[ "$N_INST" =~ ^[0-9]+$ && "$N_INST" -ge 1 ]] || N_INST=1
LOCK_FILE="$DIR/pr-rebase-$INST.lock"
CUR_FILE="$DIR/.current-rebase-$INST"
source "$DIR/config.sh"
CLONE="$RAGFLOW_MAIN"
WTROOT="$CLONE/wt"
TMPL="$DIR/prompts/pr-rebase-task.md"
QUOTA_PATTERN='usage limit|billing cycle|quota.{0,40}(refresh|exceed|exhaust)|insufficient.{0,20}quota|使用上限|限额.{0,20}重置|额度.{0,20}(耗尽|不足)'
TRANSIENT_PATTERN='rate.?limit|too many requests|\b429\b|overloaded|temporarily unavailable|service unavailable|\b50[23]\b|try again later|high load|capacity exceeded|out of capacity|timed out|负载|限流|稍后重试'

mkdir -p "$LOG_DIR" "$WTROOT"
log() { echo "[$(date +%Y%m%d-%H%M%S)] pr-rebase-line: $*" >> "$LOG_DIR/daemon.log"; }

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "lock busy, skipping this tick"
  exit 0
fi

# Manual delegation (pr-follow.sh rebase <N>): exactly one PR, no collect.
SINGLE=()
if [[ "${1:-}" == "--single" ]]; then
  SINGLE=("$2" "$3" "$4" "${5:-}")
  CANDS="$(printf '%s\t%s\t%s\t%s' "${SINGLE[@]}")"
else
  [[ -x "$CLINE_BIN" && -s "$TMPL" ]] || { log "cline CLI or template missing, skipping"; exit 0; }
  CANDS="$(python3 "$DIR/lines/pr-follow.py" collect rebase 2>>"$LOG_DIR/daemon.log")"
fi
[[ -z "$CANDS" ]] && exit 0
# Model selection (incl. multi-key quota rotation) is owned by pr-llm-run.sh.
source "$DIR/lines/pr-llm-run.sh"

prepare_worktree() { # <pr-num> <branch> → echoes worktree dir
  local num="$1" branch="$2" wt="$WTROOT/rebase-$num"
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


cand=0
while IFS=$'\t' read -r num branch url mid; do
  cand=$((cand+1)); (( (cand - 1) % N_INST == INST - 1 )) || continue
  [[ "$num" =~ ^[0-9]+$ ]] || continue
  log "rebase target pr=$num branch=$branch"
  CUR_PR="$num"; echo "$num" > "$CUR_FILE"
  wt="$(prepare_worktree "$num" "$branch")" || continue
  # --- mechanical half first (pr-rebase-auto.sh): a FULLY CLEAN rebase
  # replayed zero conflicts = semantics untouched — unit-tier gate +
  # --force-with-lease push without an LLM. Conflicts stay LLM work; the
  # auto attempt then leaves the rebase IN PROGRESS and its handover
  # section is injected via ENV_STATUS_SECTION (pr-llm-run.sh).
  auto_out="$(bash "$DIR/framework/pr-rebase-auto.sh" "$num" "$branch" "$wt" 2>>"$LOG_DIR/daemon.log")" && auto_rc=0 || auto_rc=$?
  if [[ $auto_rc -eq 0 ]]; then
    log "pr=$num: clean rebase auto-verified and pushed — LLM skipped"
    [[ -n "$mid" ]] && python3 "$DIR/lines/pr-follow.py" stamp "$mid" rebase_fix_at >>"$LOG_DIR/daemon.log" 2>&1 || true
    [[ -n "$mid" ]] && python3 "$DIR/lines/pr-follow.py" report-if-ready "$mid" "$num" "$branch" >>"$LOG_DIR/daemon.log" 2>&1 || true
    bash "$DIR/framework/pr-e2e.sh" down "$num" >>"$LOG_DIR/daemon.log" 2>&1 || true
    CUR_PR=""; rm -f "$CUR_FILE"
    release_worktree "$num"
    n=$((n + 1))
    continue
  fi
  # The LLM stage runs in one throwaway golden container (frozen base).
  # --creds: the agent force-with-lease pushes the rebased branch itself.
  # No framework pre-flight (parity with the old host stage; the agent may
  # still launch services itself inside its own container). PR_PRE_SECTION
  # carries the auto-rebase handover into the prompt.
  HFV_SLOT="pr-rebase-$num" PR_TMPL="pr-rebase-task.md" PR_TAG="rebase" PR_NUM="$num" PR_BRANCH="$branch" PR_URL="$url" PR_MID="$mid" \
  PR_TIMEOUT=1800 PR_PREFLIGHT=0 PR_PRE_SECTION="$auto_out" \
  GH_TOKEN="$(gh auth token 2>/dev/null || true)" \
    bash "$DIR/lines/run-container.sh" --wt "$wt" --creds run-pr-main.sh
  rc=$?
  # stamps regardless of outcome: cooldown holds even on failure
  [[ -n "$mid" ]] && python3 "$DIR/lines/pr-follow.py" stamp "$mid" rebase_fix_at >>"$LOG_DIR/daemon.log" 2>&1 || true
  # A done-flagged PR that was conflicted at its done moment may now be clean
  # → the merge-readiness report (R1-R4 rules in report-if-ready) probes here.
  if [[ $rc -eq 0 || $rc -eq 124 ]] && [[ -n "$mid" ]]; then
    python3 "$DIR/lines/pr-follow.py" report-if-ready "$mid" "$num" "$branch" >>"$LOG_DIR/daemon.log" 2>&1 || true
  fi
  CUR_PR=""; rm -f "$CUR_FILE"
  release_worktree "$num"
  n=$((n + 1))
done <<<"$CANDS"
log "rebase line done: $n PR(s) this tick"
exit 0
