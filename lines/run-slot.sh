#!/usr/bin/env bash
# run-slot.sh — host-side launcher for ONE parallel worker slot (no DinD).
#
# Invoked as ExecStart of cline-feishu-triage@<n>.service (issue line), or as
# `run-slot.sh 9 run-feat.sh` from cline-feishu-feat.service (containerized
# one-shot feat worker — slot 9 is reserved for feat, no timer attached).
# Pipeline:
#   1. slot bootstrap — per-slot ragflow clone (object-shared with the host
#      repo via --reference; remotes mirrored verbatim so host-side delivery
#      pushes exactly like from ragflow4), per-slot caches, worker image,
#      sibling service stack through the regular host docker socket
#   2. docker run --rm hfv-worker → docker/worker-entrypoint.sh (socat port
#      table + readiness waits) → run-task.sh with HFV_SLOT exported
#
# The LLM run itself (cline, chrome, ragflow py/go/web stacks) happens INSIDE
# the container on container-localhost: ports 9380/9383/9384/9222 exist only
# there → zero host port conflicts across slots and with the host dev stack.
#
# Slot teardown is deliberately NONE by default: the svc stack idles like the
# host stack (volumes persist, warm next tick). `run-slot.sh <n> --down`
# stops a slot's stack without dropping data.
set -u
SLOT="${1:-}"
[[ "$SLOT" =~ ^[0-9]+$ ]] || { echo "usage: run-slot.sh <slot-number> [--down|--purge|<in-worker-script.sh>]" >&2; exit 1; }
DOWN=0; [[ "${2:-}" == "--down" ]] && DOWN=1
PURGE=0; [[ "${2:-}" == "--purge" ]] && PURGE=1
# Second positional argument: which script the worker container runs (default
# the issue line's run-task.sh; "run-feat.sh" turns the slot into a one-shot
# feat worker — same clone/svc-stack/worker machinery, different task file
# inside). Plain basenames only — the value is interpolated into a container
# path, never allow traversal.
SCRIPT="run-task.sh"
case "${2:-}" in
  ""|--down|--purge) ;;
  *) SCRIPT="$2" ;;
esac
[[ "$SCRIPT" =~ ^[a-z0-9-]+\.sh$ ]] || { echo "run-slot.sh: bad script name '$SCRIPT'" >&2; exit 1; }

export HFV_SLOT="$SLOT"
HFV_DIR="$HOME/hands-free-vibe"
source "$HFV_DIR/config.sh"   # exports HFV_SUF; points RAGFLOW_MAIN at the slot clone

SLOT_ROOT="$HOME/hfv-slots/slot$SLOT"
SVC_PROJECT="hfv-svc-$SLOT"
LOG_DIR="$HFV_DIR/logs"
mkdir -p "$LOG_DIR"   # SLOT_ROOT is only created on the run path, not by --down/--purge
log() { echo "[$(date +%Y%m%d-%H%M%S)] slot$SLOT: $*" >> "$LOG_DIR/daemon.log"; }

if (( DOWN || PURGE )); then
  docker compose -p "$SVC_PROJECT" --env-file "$RAGFLOW_HOST_REPO/docker/.env" \
    -f "$HFV_DIR/docker/svc-compose.yml" stop
  log "svc stack stopped (volumes kept; ragflow clone and caches untouched)"
  (( PURGE )) || exit 0
  # --purge: drop volumes + the slot root (clone, caches, chrome profile).
  # hfv-slot owns the timer/worker teardown; this is the data half.
  docker compose -p "$SVC_PROJECT" --env-file "$RAGFLOW_HOST_REPO/docker/.env" \
    -f "$HFV_DIR/docker/svc-compose.yml" down -v --remove-orphans
  docker network rm "hfv-net-$SLOT" >/dev/null 2>&1 || true
  rm -rf "$SLOT_ROOT"
  log "slot purged: volumes dropped, network removed, clone and caches deleted"
  exit 0
fi

# --- 0) no-task gate -------------------------------------------------------
# The pre group (ExecStartPre=pre-task.sh) already ran issue-select: no
# current.json ⇔ nothing to do this tick. Rest WITHOUT the svc stack or a
# throwaway worker — dozens of idle ticks/day/slot must not cold-start ES
# (~1-2min) nor churn a container for a run-task.sh that would only log
# "resting" and exit. The .rested marker keeps post-task a no-op, identical
# to run-task.sh's own resting path. Combined with the idle-TTL stop in
# pre-task.sh, an idle slot's whole svc stack stays DOWN at ~0 RAM until
# real work arrives (run-slot.sh's compose up below re-ups it warm).
# The gate applies to the issue line only: a feat run's input is
# feat/current-feature.md (staged by `hfv feat -f`), not an issue selection.
if [[ "$SCRIPT" == "run-task.sh" && ! -s "$HFV_DIR/issues/current$HFV_SUF.json" ]]; then
  touch "$LOG_DIR/.rested$HFV_SUF"
  log "no issue this tick — svc stack and worker skipped entirely"
  exit 0
fi

# --- 1) slot repo: fresh clone if missing ---------------------------------
if [[ ! -d "$RAGFLOW_MAIN/.git" ]]; then
  # --reference borrows the host repo's object store: no re-download of
  # history; the fallback (offline) is a plain local clone.
  git clone --reference-if-able "$RAGFLOW_HOST_REPO" \
      "https://github.com/$GITHUB_REPO.git" "$RAGFLOW_MAIN" 2>>"$LOG_DIR/daemon.log" \
    || git clone "$RAGFLOW_HOST_REPO" "$RAGFLOW_MAIN" >>"$LOG_DIR/daemon.log" 2>&1
  # Mirror the host repo's remotes verbatim (origin/upstream, fork remote,
  # whatever auth URLs the host uses) so post-deliver.sh's push from THIS
  # workdir behaves exactly like a push from ragflow4.
  while read -r rname rurl; do
    [[ -n "$rname" ]] || continue
    if git -C "$RAGFLOW_MAIN" remote | grep -qx "$rname"; then
      git -C "$RAGFLOW_MAIN" remote set-url "$rname" "$rurl"
    else
      git -C "$RAGFLOW_MAIN" remote add "$rname" "$rurl"
    fi
  done < <(git -C "$RAGFLOW_HOST_REPO" remote -v | awk '/\(push\)$/ {print $1, $2}' | sort -u)
  log "ragflow clone created at $RAGFLOW_MAIN"
fi
mkdir -p "$SLOT_ROOT/chrome-profile" "$SLOT_ROOT/uv-cache" "$SLOT_ROOT/go" \
         "$SLOT_ROOT/go-build" "$SLOT_ROOT/npm-cache" "$HFV_DIR/deliver$HFV_SUF"
# A crashed previous run leaves Singleton* lock files in the chrome profile;
# the next Chrome then exits instantly on launch (~150ms onExit in the MCP
# log), which looks like a wedged MCP server and tempts the LLM into killing
# it — permanently losing the session's browser (see playbook.md). Clean ONLY
# the lock files; the profile itself (cookies, login state) stays.
rm -f "$SLOT_ROOT"/chrome-profile/profile*/Singleton* 2>/dev/null || true

# --- 2) worker image (system layer only; built once, shared by slots) -----
if [[ -z "$(docker images -q hfv-worker:latest)" ]]; then
  bash "$HFV_DIR/docker/build-worker.sh" >>"$LOG_DIR/daemon.log" 2>&1 \
    || { log "worker image build failed"; exit 1; }
fi

# --- 3) sibling service stack via the regular host daemon (no DinD) -------
HFV_SLOT="$SLOT" docker compose -p "$SVC_PROJECT" \
  --env-file "$RAGFLOW_HOST_REPO/docker/.env" \
  -f "$HFV_DIR/docker/svc-compose.yml" up -d --remove-orphans \
  || { log "svc stack up failed"; exit 1; }

# --- 4) worker container ---------------------------------------------------
# Same-path bind mounts so every path baked into prompts/configs resolves
# identically inside and outside the container. The docker socket grants
# container management only — no docker daemon runs inside (see README).
DOCKER_GID="$(stat -c %g /var/run/docker.sock 2>/dev/null || echo 0)"
# A previous run killed hard (SIGTERM/SIGKILL mid-flight) can leave its
# hfv-worker-sN container behind (--rm only fires on clean exit); the leftover
# blocks `docker run --name` with exit 125 and wedges the slot for hours.
# The slot lock is already ours here, so any
# namesake container is by definition stale — remove it before recreating.
docker rm -f "hfv-worker-s$SLOT" >/dev/null 2>&1 || true
exec docker run --rm \
  --name "hfv-worker-s$SLOT" \
  --network "hfv-net-$SLOT" \
  --add-host host.docker.internal:host-gateway \
  --group-add "$DOCKER_GID" \
  --shm-size 2g \
  -e HFV_SLOT="$SLOT" \
  -e TZ="$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo Asia/Shanghai)" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HFV_DIR":/home/inf/hands-free-vibe \
  -v "$HOME/.cline/data/sessions":/home/inf/.cline/data/sessions \
  -v "$HFV_DIR/docker/gitconfig.worker":/home/inf/.gitconfig:ro \
  -v "$SLOT_ROOT":/home/inf/hfv-slots/slot"$SLOT" \
  -v "$SLOT_ROOT/chrome-profile":/home/inf/.cache/chrome-devtools-mcp \
  -v "$SLOT_ROOT/uv-cache":/home/inf/.cache/uv \
  -v "$SLOT_ROOT/go":/home/inf/go \
  -v "$SLOT_ROOT/go-build":/home/inf/.cache/go-build \
  -v "$SLOT_ROOT/npm-cache":/home/inf/.npm \
  hfv-worker:latest \
  "/home/inf/hands-free-vibe/lines/$SCRIPT"
