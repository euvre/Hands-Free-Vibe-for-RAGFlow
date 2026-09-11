#!/usr/bin/env bash
# pr-follow.sh — PR follow-up state-machine backstop + manual single-shot entries.
#
# After the split (pr-rebase-line.sh / pr-review-line.sh, each with its own
# timer + lock), THIS script's auto mode is the state machine only:
#   reconcile (pr-follow.py): flip merged/closed, re-check both needs.
#
# Manual mode (hfv pr-rebase / pr-review <pr-num>): ONE stage on ONE
# explicit PR. Conflict-free rebases are handled by a ~15s script (no LLM);
# real conflicts / reviews delegate to the dedicated line helpers.
#
# Concurrency — THREE locks, three independent parallel lines, all on the
# shared ragflow4 workspace (separate wt/ namespaces; git serializes refs):
#   issue line:  run.lock       (run-task.sh / run-feat.sh; ragflow4 main worktree; dev services)
#   rebase line: pr-rebase.lock (pr-rebase-line.sh; ragflow4 wt/rebase-<n> pool)
#   review line: pr-review.lock (pr-review-line.sh; ragflow4 wt/review-<n> pool)
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"  # repo root (this script lives in lines/)
LOG_DIR="$DIR/logs"
# Per-instance lock (hfv scale follow <N>). The auto pass is a seconds-long
# whole-store sweep — one instance covers it; extra instances only add
# manual-delegation capacity (hfv pr follow rebase|review <pr>).
INST="${HFV_INST:-1}"
LOCK_FILE="$DIR/pr-follow-$INST.lock"
DM="$DIR/tools/feishu-dm.py"
source "$DIR/config.sh"

mkdir -p "$LOG_DIR"
log() { echo "[$(date +%Y%m%d-%H%M%S)] pr-follow: $*" >> "$LOG_DIR/daemon.log"; }

MODE=auto
MANUAL_ACTION=""
case "${1:-auto}" in
  auto) ;;
  rebase|review)
    MODE=manual
    MANUAL_ACTION="$1"
    [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "usage: pr-follow.sh $1 <pr-num>" >&2; exit 2; }
    ;;
  *) echo "usage: pr-follow.sh [auto|rebase <pr-num>|review <pr-num>]" >&2; exit 2 ;;
esac

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  if [[ "$MODE" == manual ]]; then
    echo "pr-follow: another PR follow-up run is active, try again later" >&2
    exit 1
  fi
  log "lock busy, skipping this tick"
  exit 0
fi
[[ "$MODE" == auto && "$INST" -gt 1 ]] && exit 0

# --- auto mode: pure-script state machine (merged/closed flips only) ---
# The ready-to-merge DM moved to the pr_flag state machine (fresh→done in
# pr-review-line.sh; rebase-success path in pr-rebase-line.sh).
if [[ "$MODE" == auto ]]; then
  python3 "$DIR/lines/pr-follow.py" reconcile >>"$LOG_DIR/daemon.log" 2>&1 || true
  # Stalled-PR nudge (routing inside pr-follow.py: the merge owner vs assigned reviewers)
  python3 "$DIR/lines/pr-follow.py" stalled >>"$LOG_DIR/daemon.log" 2>&1 || true
  exit 0
fi

# --- manual single-stage mode ---
RESOLVED="$(python3 "$DIR/lines/pr-follow.py" resolve "$2" 2>>"$LOG_DIR/daemon.log")" || true
[[ -z "$RESOLVED" ]] && { echo "pr-follow: cannot resolve PR #$2 (gh lookup failed)" >&2; exit 1; }
IFS=$'\t' read -r BRANCH PR_URL MID <<<"$RESOLVED"
PR_NUM="$2"
log "manual target action=$MANUAL_ACTION pr=$PR_NUM branch=$BRANCH mid=${MID:-<untracked>}"

# Scripted fast-path: manual rebase on a conflict-free branch (~15s, no LLM).
# Runs in a DETACHED scratch worktree (ragflow4/wt/manual-<n>) — NEVER in
# ragflow4's main worktree: a `checkout -B` there would yank the issue line's
# workspace mid-run. Own namespace, so a concurrent rebase-line round on
# wt/rebase-<n> is never touched either.
if [[ "$MANUAL_ACTION" == "rebase" ]]; then
  python3 "$DIR/lines/pr-follow.py" conflict "$BRANCH" >/dev/null 2>&1
  frc=$?
  if [[ $frc -eq 1 ]]; then
    RBWT="$RAGFLOW_MAIN/wt/manual-$PR_NUM"
    # self-heal any half-removed leftover from a crashed fast-path first
    git -C "$RAGFLOW_MAIN" worktree remove --force "$RBWT" >>"$LOG_DIR/daemon.log" 2>&1 || true
    git -C "$RAGFLOW_MAIN" worktree prune >>"$LOG_DIR/daemon.log" 2>&1 || true
    [[ -d "$RBWT" ]] && rm -rf "$RBWT" >>"$LOG_DIR/daemon.log" 2>&1 || true
    if ( git -C "$RAGFLOW_MAIN" fetch -q origin "$PR_BASE" \
         && git -C "$RAGFLOW_MAIN" fetch -q "$FORK_REMOTE" "$BRANCH" \
         && git -C "$RAGFLOW_MAIN" worktree add --detach "$RBWT" "$FORK_REMOTE/$BRANCH" \
         && git -C "$RBWT" rebase "origin/$PR_BASE" \
         && git -C "$RBWT" push --force-with-lease "$FORK_REMOTE" "HEAD:$BRANCH" ) >>"$LOG_DIR/daemon.log" 2>&1; then
      git -C "$RAGFLOW_MAIN" worktree remove --force "$RBWT" >>"$LOG_DIR/daemon.log" 2>&1 || true
      [[ -n "$MID" ]] && python3 "$DIR/lines/pr-follow.py" stamp "$MID" rebase_fix_at >>"$LOG_DIR/daemon.log" 2>&1 || true
      log "rebase fast-path (no conflicts): pr=$PR_NUM scripted"
      echo "pr-rebase #$PR_NUM: conflict-free, rebased + pushed by script (no LLM)"
      exit 0
    else
      # leave nothing behind: the delegated line starts from a clean worktree
      git -C "$RAGFLOW_MAIN" worktree remove --force "$RBWT" >>"$LOG_DIR/daemon.log" 2>&1 || true
      git -C "$RAGFLOW_MAIN" worktree prune >>"$LOG_DIR/daemon.log" 2>&1 || true
      [[ -d "$RBWT" ]] && rm -rf "$RBWT" >>"$LOG_DIR/daemon.log" 2>&1 || true
      log "rebase fast-path git chain failed for pr=$PR_NUM — delegating to the line"
    fi
  fi
  # conflicted (or probe unknown): delegate to the rebase line's LLM machinery
  flock -s 9 2>/dev/null || true   # keep our lock through the delegation below
  exec bash "$DIR/lines/pr-rebase-line.sh" --single "$PR_NUM" "$BRANCH" "$PR_URL" "$MID"
else
  exec bash "$DIR/lines/pr-review-line.sh" --single "$PR_NUM" "$BRANCH" "$PR_URL" "$MID"
fi
