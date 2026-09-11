#!/usr/bin/env bash
# build-worker.sh — (re)build the hfv-worker image (docker/Dockerfile.worker).
# Safe to re-run; run-slot.sh builds automatically when the image is missing.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
docker build -f "$DIR/Dockerfile.worker" -t hfv-worker:latest "$DIR"