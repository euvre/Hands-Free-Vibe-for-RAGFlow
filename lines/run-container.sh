#!/usr/bin/env bash
# run-container.sh — one task per throwaway container off the golden image
# hfv-task:latest: no fixed numbered slot, no per-slot timer, no per-slot
# clone. The golden image is a frozen base for parallel task containers: every
# container starts from the same pinned world, and nothing a task mutates
# flows back into the image (no docker commit). Code and caches stay
# bind-mounted on the host (delivery needs host credentials). Golden updates
# go through the manual bootstrap flow (install.sh), never as a task side
# effect.
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

# options:
#   --wt <path>  reuse an existing line-managed worktree (no create/reap/remove
#                here; the caller owns its lifecycle) — the PR lines' worktrees
#   --creds      the LLM stage may push/comment: pass GH_TOKEN through, mount
#                the real gh config ro, and shadow the minimal worker gitconfig
#                with a GH_TOKEN-backed credential helper. Default containers
#                stay credential-less.
WT_OVERRIDE=""
CREDS=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --wt)    WT_OVERRIDE="${2:-}"; shift 2 ;;
    --creds) CREDS=1; shift ;;
    *) echo "usage: run-container.sh [--wt <worktree>] [--creds] <script.sh>" >&2; exit 1 ;;
  esac
done
SCRIPT="${1:-}"
[[ "$SCRIPT" =~ ^[a-z0-9-]+\.sh$ ]] || { echo "usage: run-container.sh [--wt <worktree>] [--creds] <script.sh>" >&2; exit 1; }
[[ "$CREDS" == 0 || -n "${GH_TOKEN:-}" ]] || { echo "--creds needs GH_TOKEN in env (host: gh auth token)" >&2; exit 1; }

if [[ -z "$(docker images -q "$GOLDEN")" ]]; then
  log "golden image $GOLDEN missing — build it: docker build -f docker/Dockerfile.task -t hfv-task:base docker/, then bootstrap-commit once"
  exit 1
fi

# --- worktree ---------------------------------------------------------------
if [[ -n "$WT_OVERRIDE" ]]; then
  WT="$WT_OVERRIDE"
  [[ -d "$WT" ]] || { echo "worktree missing: $WT" >&2; exit 1; }
else
WT="$RAGFLOW_MAIN/wt/task-$TS${HFV_SLOT:+-s$HFV_SLOT}"
git -C "$RAGFLOW_MAIN" fetch -q origin main >>"$LOG_DIR/daemon.log" 2>&1 || true
# Reap task worktrees/husks older than 48h: a live delivery is consumed by
# post-deliver within minutes, so anything this old is dead. Root-owned files
# inside a husk may refuse deletion — best-effort; they stay invisible to git
# via the main clone's info/exclude.
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
fi
# Idle per-PR e2e groups: env-up e2e mode is manual-only now, but any group
# that does get brought up must not sit for hours — reap when idle (no live
# stage container) beyond the TTL. Runs on every task/stage launch (both the
# issue path above and the PR-line --wt path land here).
bash "$HFV_DIR/framework/pr-e2e.sh" reap >>"$LOG_DIR/daemon.log" 2>&1 || true
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
# runtime assets not in git: deepdoc models + NLTK data. Symlink the clone's
# copies into the worktree (the clone is mounted at the same path in-container,
# so the links resolve there).
for d in rag/res/deepdoc ragflow_deps/nltk_data; do
  if [[ -e "$RAGFLOW_MAIN/$d" && ! -e "$WT/$d" ]]; then
    mkdir -p "$WT/$(dirname "$d")"
    ln -s "$RAGFLOW_MAIN/$d" "$WT/$d"
  fi
done
# prebuilt go server: the launcher only builds when bin/ragflow_server is
# absent, and a cold cgo+ORT link costs minutes per task. Hardlink the main
# clone's fresh build into the worktree (same fs, free); fall back to a copy.
# WARNING: a stale/non-cgo binary here silently breaks the in-process DeepDoc
# backend — rebuild it in a golden container whenever build.sh/ORT change.
if [[ -x "$RAGFLOW_MAIN/bin/ragflow_server" && ! -e "$WT/bin/ragflow_server" ]]; then
  mkdir -p "$WT/bin"
  ln "$RAGFLOW_MAIN/bin/ragflow_server" "$WT/bin/ragflow_server" 2>/dev/null \
    || cp "$RAGFLOW_MAIN/bin/ragflow_server" "$WT/bin/ragflow_server"
fi

log "starting $CTR (script=$SCRIPT wt=$WT)"

# credential mode: GH_TOKEN comes from the caller's env (host `gh auth token`).
# The generated gitconfig shadows the minimal worker one with a GH_TOKEN-backed
# credential helper (the gh keyring does not exist in-container).
CRED_ARGS=()
GITCFG="$HFV_DIR/docker/gitconfig.worker"
if [[ "$CREDS" == 1 ]]; then
  CRED_GIT="$LOG_DIR/.gitconfig-creds-$TS"
  cat "$GITCFG" > "$CRED_GIT"
  printf '[credential "https://github.com"]\n\thelper = "!f() { echo username=oauth2; echo \"password=$GH_TOKEN\"; }; f"\n' >> "$CRED_GIT"
  GITCFG="$CRED_GIT"
  CRED_ARGS=(-e GH_TOKEN="$GH_TOKEN" -v "$HOME/.config/gh:/home/inf/.config/gh:ro")
fi
# PR-stage env passthrough (run-pr-main.sh reads these)
ENV_ARGS=()
for v in PR_TMPL PR_TAG PR_NUM PR_BRANCH PR_URL PR_MID PR_TIMEOUT PR_PREFLIGHT PR_PRE_SECTION; do
  [[ -n "${!v:-}" ]] && ENV_ARGS+=(-e "$v=${!v}")
done

docker run \
  --name "$CTR" \
  --add-host host.docker.internal:host-gateway \
  --shm-size 2g \
  -e HFV_SLOT="${HFV_SLOT:-}" \
  -e RAGFLOW_MAIN="$WT" \
  -e TZ="$(cat /etc/timezone 2>/dev/null || echo Asia/Shanghai)" \
  "${CRED_ARGS[@]}" "${ENV_ARGS[@]}" \
  -v "$HFV_DIR":"$HFV_DIR" \
  -v "$HOME/.cline/data/sessions":"$HOME/.cline/data/sessions" \
  -v "$GITCFG":/home/inf/.gitconfig:ro \
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

# A task container is pure throwaway: no docker commit, no roll-forward, no
# per-run snapshot image. Crash forensics live in the run log on the host.
[[ $rc -ne 0 ]] && log "crash rc=$rc — see run-container-$TS.log"

docker rm "$CTR" >>"$LOG_DIR/daemon.log" 2>&1 || true
# Issue-line delivery happens in ExecStartPost on the host (post-task →
# post-deliver → issue-deliver.sh) and commits the task worktree: when a
# delivery is staged, keep the worktree for post-deliver (it removes it after
# the attempt). Anything else is removed here.
DELIVER_DIR="$HFV_DIR/deliver${HFV_SLOT:+-s$HFV_SLOT}"
if [[ -n "$WT_OVERRIDE" ]]; then
  : # line-managed worktree: the caller owns its lifecycle
elif [[ "$SCRIPT" == "run-task.sh" && -s "$DELIVER_DIR/branch.txt" ]]; then
  log "delivery staged in $DELIVER_DIR — keeping worktree $WT for post-deliver"
else
  git -C "$RAGFLOW_MAIN" worktree remove --force "$WT" >>"$LOG_DIR/daemon.log" 2>&1 || true
fi
git -C "$RAGFLOW_MAIN" worktree prune >>"$LOG_DIR/daemon.log" 2>&1 || true
exit "$rc"
