#!/usr/bin/env bash
# run-container.sh — one task per throwaway container off the golden image
# hfv-task:latest: no fixed numbered slot, no per-slot timer, no per-slot
# clone. A task gets a fresh
# container off hfv-task:latest; on clean exit the container is committed back
# (flock-serialized roll-forward), so account state / default model / datasets
# / chrome session all persist via the image. Data lives on the container
# layer; code and caches stay bind-mounted on the host (delivery needs host
# credentials; caches would bloat every commit layer).
#
# usage: run-container.sh <in-container-script.sh>   (basename under lines/)
set -u
HFV_DIR="$HOME/hands-free-vibe"
source "$HFV_DIR/config.sh"
LOG_DIR="$HFV_DIR/logs"
TS="$(date +%Y%m%d-%H%M%S)"
CTR="hfv-task-$TS${HFV_SLOT:+-s$HFV_SLOT}"
GOLDEN="hfv-task:latest"
COMMIT_LOCK="$HFV_DIR/.commit.lock"

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

# --- commit back (serialized; a parallel task must not interleave layers) ---
exec 9>"$COMMIT_LOCK"
flock 9
SNAP="hfv-task:snap-$TS"
docker commit "$CTR" "$SNAP" >>"$LOG_DIR/daemon.log" 2>&1 || true
if [[ $rc -eq 0 ]]; then
  # clean exit: roll the golden forward
  docker tag "$SNAP" "$GOLDEN" >>"$LOG_DIR/daemon.log" 2>&1 \
    && log "golden rolled forward from $CTR (snap=$SNAP)" \
    || log "golden tag FAILED from $SNAP — snapshot kept"
else
  log "crash rc=$rc — snapshot $SNAP kept for forensics, golden NOT rolled"
fi
flock -u 9
exec 9>&-

docker rm "$CTR" >>"$LOG_DIR/daemon.log" 2>&1 || true
git -C "$RAGFLOW_MAIN" worktree remove --force "$WT" >>"$LOG_DIR/daemon.log" 2>&1 || true
git -C "$RAGFLOW_MAIN" worktree prune >>"$LOG_DIR/daemon.log" 2>&1 || true
exit "$rc"
