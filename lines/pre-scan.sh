#!/usr/bin/env bash
# pre-scan.sh — scan 线 pre 组：任务启动前按序执行的准备作业。
#  1. 遗留补偿：daemon/主机死在 run 中途时 current-N.json / deliver-N 残留 ——
#     本槽位锁空闲即补跑 post-scan.sh（幂等：fold 结果、发群通知、归档），
#     避免半成品交付物被下轮继承。
#  2. 选定本轮扫描批次（scan-select.py，flock 串行化，多槽位并发安全）。
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"  # repo root (this script lives in lines/)
source "$DIR/config.sh"
SLOT="${HFV_SCAN_INST:-1}"
LOG="$DIR/logs/daemon.log"
mkdir -p "$DIR/logs"

# 1. leftover reconcile: the lock is free (no live run) but a previous round
#    died between select and post — rerun the post group to settle it.
if [[ -f "$DIR/scan/current-$SLOT.json" || -n "$(ls -A "$DIR/scan/deliver-$SLOT" 2>/dev/null)" ]]; then
  if flock -n "$DIR/locks/run-scan-$SLOT.lock" -c true 2>/dev/null; then
    echo "[$(date +%Y%m%d-%H%M%S)] pre-scan: reconciling leftover round on slot $SLOT (post-scan rerun)" >> "$LOG"
    HFV_SCAN_INST="$SLOT" bash "$DIR/lines/post-scan.sh" || true
  fi
fi

# 2. pick this round's batch (serialized across slots; a slot with no
#    candidates simply gets no current file and its runner rests).
NSLOTS=1
[[ -f "$DIR/state/.scale-scan" ]] && NSLOTS="$(cat "$DIR/state/.scale-scan" 2>/dev/null)"
[[ "$NSLOTS" =~ ^[0-9]+$ && "$NSLOTS" -ge 1 ]] || NSLOTS=1
(
  flock -w 120 9 || exit 0
  python3 "$DIR/scan/scan-select.py" select --repo "$RAGFLOW_MAIN" \
    --slot "$SLOT" --slots "$NSLOTS" >> "$LOG" 2>&1 || true
) 9>"$DIR/locks/.scan-select.lock"
