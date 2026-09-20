#!/usr/bin/env bash
# docker-prune.sh — Docker build-cache housekeeping (cline-feishu-docker-prune.timer,
# weekly; also called right after the image build in install.sh).
#
# The build cache is the one unbounded docker growth on this host: every
# hfv-task image rebuild and every ad-hoc build leaves its layers behind,
# and nothing ever removes them (measured: 123.8G after a few weeks).
# Layers older than PRUNE_UNTIL (default 72h) are reclaimed; newer layers
# stay so incremental rebuilds keep their cache hits. Images, containers
# and volumes are NEVER touched (the golden image and the idle per-PR
# service groups live there).
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"   # repo root (this script lives in framework/)
LOG_DIR="$DIR/logs"
mkdir -p "$LOG_DIR"
log() { echo "[$(date +%Y%m%d-%H%M%S)] docker-prune: $*" >> "$LOG_DIR/daemon.log"; }

command -v docker >/dev/null || exit 0
UNTIL="${DOCKER_PRUNE_UNTIL:-72h}"

out="$(docker builder prune -af --filter "until=$UNTIL" 2>&1)" || {
  log "builder prune failed: $(echo "$out" | tail -1)"
  exit 0
}
reclaimed="$(echo "$out" | grep -i 'reclaimed' || echo 'Total reclaimed space: 0B (nothing older than 72h)')"
log "$reclaimed (cache older than $UNTIL)"
exit 0
