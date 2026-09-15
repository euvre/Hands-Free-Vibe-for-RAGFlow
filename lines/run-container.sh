#!/usr/bin/env bash
# run-container.sh — one task per throwaway container off the golden image
# hfv-task:latest: no fixed numbered slot, no per-slot timer, no per-slot
# clone. The golden image is a FROZEN base for parallel task containers: every
# container starts from the same pinned world (this is what makes N parallel
# containers safe), and NOTHING a task mutates flows back into the image — no
# docker commit write-back (removed 2026-09-14: it was the serialization point
# and a poisoning channel — a root-run container once committed a broken
# ENTRYPOINT into golden). Code and caches stay bind-mounted on the host
# (delivery needs host credentials). Intentional golden updates go through the
# manual bootstrap-commit flow (install.sh), never as a task side effect.
#
# usage: run-container.sh <in-container-script.sh>   (basename under lines/)
set -u
HFV_DIR="$HOME/hands-free-vibe"
source "$HFV_DIR/config.sh"
LOG_DIR="$HFV_DIR/logs"
TS="$(date +%Y%m%d-%H%M%S)"
CTR="hfv-task-$TS${HFV_SLOT:+-s$HFV_SLOT}"
GOLDEN="hfv-task:latest"

log() { echo "[$(date +%Y%m%d-%H%M%S)] run-container: $*" >> "$LOG_DIR/daemon.log"; }

SCRIPT="${1:-}"
[[ "$SCRIPT" =~ ^[a-z0-9-]+\.sh$ ]] || { echo "usage: run-container.sh <script.sh>" >&2; exit 1; }

if [[ -z "$(docker images -q "$GOLDEN")" ]]; then
  log "golden image $GOLDEN missing — build it: docker build -f docker/Dockerfile.task -t hfv-task:base docker/, then bootstrap-commit once"
  exit 1
fi

# --- worktree: one detached worktree per task on the main clone -------------
WT="$RAGFLOW_MAIN/wt/task-$TS${HFV_SLOT:+-s$HFV_SLOT}"
git -C "$RAGFLOW_MAIN" fetch -q origin main >>"$LOG_DIR/daemon.log" 2>&1 || true
# Reap dead task worktrees/husks older than 48h: killed tasks and crashed post
# groups leak them (a live delivery is consumed by post-deliver within minutes,
# so 48h is a generous margin). Root-owned cache files inside container-era
# husks may refuse deletion — best-effort; they stay invisible to git via the
# main clone's info/exclude.
find "$RAGFLOW_MAIN/wt" -maxdepth 1 -mindepth 1 -name 'task-*' -mtime +2 2>/dev/null \
  | while read -r d; do
      git -C "$RAGFLOW_MAIN" worktree remove --force "$d" >>"$LOG_DIR/daemon.log" 2>&1 \
        || { git -C "$RAGFLOW_MAIN" worktree prune; rm -rf "$d" 2>/dev/null || true; }
      log "reaped stale worktree $d"
    done
git -C "$RAGFLOW_MAIN" worktree prune >>"$LOG_DIR/daemon.log" 2>&1 || true
if ! git -C "$RAGFLOW_MAIN" worktree add --detach "$WT" origin/main >>"$LOG_DIR/daemon.log" 2>&1; then
  log "worktree add failed for $WT"
  exit 1
fi
# the worktree's venv/node_modules resolve into the clone's copies
for d in web/node_modules; do
  [[ -e "$RAGFLOW_MAIN/$d" && ! -e "$WT/$d" ]] && ln -s "$RAGFLOW_MAIN/$d" "$WT/$d" 2>/dev/null || true
done

CACHE="$HOME/hfv-cache"
mkdir -p "$CACHE/uv" "$CACHE/go" "$CACHE/go-build" "$CACHE/npm"

# tokenizer static lib: not in git, and a fresh worktree has no cmake build —
# copy just the .a from the main clone (the cmake cache is path-pinned and
# cannot be reused, but the archive itself links fine).
TOKLIB="internal/binding/cpp/cmake-build-release/librag_tokenizer_c_api.a"
if [[ -f "$RAGFLOW_MAIN/$TOKLIB" && ! -f "$WT/$TOKLIB" ]]; then
  mkdir -p "$WT/$(dirname "$TOKLIB")"
  cp "$RAGFLOW_MAIN/$TOKLIB" "$WT/$TOKLIB"
fi

log "starting $CTR (script=$SCRIPT wt=$WT)"
docker run \
  --name "$CTR" \
  --add-host host.docker.internal:host-gateway \
  --shm-size 2g \
  -e HFV_SLOT="${HFV_SLOT:-}" \
  -e RAGFLOW_MAIN="$WT" \
  -e TZ="$(cat /etc/timezone 2>/dev/null || echo Asia/Shanghai)" \
  -v "$HFV_DIR":"$HFV_DIR" \
  -v "$HOME/.cline/data/sessions":"$HOME/.cline/data/sessions" \
  -v "$HFV_DIR/docker/gitconfig.worker":/home/inf/.gitconfig:ro \
  -v "$RAGFLOW_MAIN":"$RAGFLOW_MAIN" \
  -v "$WT":"$WT" \
  -v "$CACHE/uv":/home/inf/.cache/uv \
  -v "$CACHE/go":/home/inf/go \
  -v "$CACHE/go-build":/home/inf/.cache/go-build \
  -v "$CACHE/npm":/home/inf/.npm \
  -v "$HOME/ragflow-native-libs":/home/inf/ragflow-native-libs \
  "$GOLDEN" \
  "$HFV_DIR/lines/$SCRIPT" >>"$LOG_DIR/run-container-$TS.log" 2>&1
rc=$?
log "$CTR exited rc=$rc"

# --- no commit-back: the golden image is a frozen base -----------------------
# A task container is pure throwaway: no docker commit, no roll-forward, no
# per-run snapshot image. Crash forensics live in the run log on the host.
[[ $rc -ne 0 ]] && log "crash rc=$rc (no snapshot: commit-back removed) — see run-container-$TS.log"

docker rm "$CTR" >>"$LOG_DIR/daemon.log" 2>&1 || true
# Issue-line delivery happens in ExecStartPost on the HOST (post-task →
# post-deliver → issue-deliver.sh) but must commit the TASK worktree, not the
# main root: when a delivery is staged, keep the worktree for post-deliver
# (it removes it after the attempt). Anything else is reaped here as before.
DELIVER_DIR="$HFV_DIR/deliver${HFV_SLOT:+-s$HFV_SLOT}"
if [[ "$SCRIPT" == "run-task.sh" && -s "$DELIVER_DIR/branch.txt" ]]; then
  log "delivery staged in $DELIVER_DIR — keeping worktree $WT for post-deliver"
else
  git -C "$RAGFLOW_MAIN" worktree remove --force "$WT" >>"$LOG_DIR/daemon.log" 2>&1 || true
fi
git -C "$RAGFLOW_MAIN" worktree prune >>"$LOG_DIR/daemon.log" 2>&1 || true
exit "$rc"
