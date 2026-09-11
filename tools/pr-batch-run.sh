#!/usr/bin/env bash
# pr-batch-run.sh — one-shot analysis batch: run the rebase AND review stages
# over a PR list (manual single-stage mode, bypassing scan/cooldown), timing
# each stage wall-clock. Feeds workflow optimization: stages that turn out to
# be pure overhead get scripted out of the LLM (see pr-follow.py scan).
#
# Usage: pr-batch-run.sh <pr-list-file>   (one PR number per line)
# Output: logs/pr-batch-stats.jsonl — one row per stage:
#   {"pr":N,"stage":"rebase|review","start":..,"end":..,"duration_s":..,
#    "exit":..,"iterations":..,"llm_duration_ms":..,"log":"..."}
# The PR-line timer is stopped for the batch and re-enabled at exit (trap), so
# ticks never interleave with our timed runs.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"  # repo root (this script lives in tools/)
LOG_DIR="$DIR/logs"
STATS="$LOG_DIR/pr-batch-stats.jsonl"
LIST="${1:?usage: pr-batch-run.sh <pr-list-file>}"
TIMER="cline-feishu-pr-follow.timer"

log() { echo "[$(date +%Y%m%d-%H%M%S)] pr-batch: $*" >> "$LOG_DIR/daemon.log"; }

# stop the auto timer for the batch; restore no matter how we exit
WAS_ENABLED=0
systemctl --user is-enabled "$TIMER" >/dev/null 2>&1 && WAS_ENABLED=1
systemctl --user stop "$TIMER" 2>/dev/null || true
restore() {
  [[ "$WAS_ENABLED" == 1 ]] && systemctl --user start "$TIMER" >/dev/null 2>&1
  log "batch finished; timer restored=$WAS_ENABLED"
}
trap restore EXIT

: > "$STATS"
log "batch start: $(wc -l < "$LIST") PRs x2 stages; timer stopped"

while read -r num; do
  [[ "$num" =~ ^[0-9]+$ ]] || continue
  for stage in rebase review; do
    # wait for a prior PR-line run to release the lock (rare; timer is off)
    for _ in $(seq 1 90); do
      flock -n "$DIR/pr-follow.lock" -c true 2>/dev/null && break
      sleep 60
    done
    before_log="$(ls -1t "$LOG_DIR"/run-pr-$stage-*.log 2>/dev/null | head -1 || true)"
    s=$(date +%s)
    bash "$DIR/lines/pr-follow.sh" "$stage" "$num" >/dev/null 2>&1
    rc=$?
    e=$(date +%s)
    # identify this run's log: newest stage log that differs from before, or
    # still-newer mtime than our start
    rlog="$(ls -1t "$LOG_DIR"/run-pr-$stage-*.log 2>/dev/null | head -1 || true)"
    if [[ "$rlog" == "$before_log" ]]; then rlog=""; fi
    iters=""; durms=""
    if [[ -n "$rlog" ]]; then
      iters=$(grep -o '"iterations":[0-9]*' "$rlog" | tail -1 | cut -d: -f2)
      durms=$(grep -o '"durationMs":[0-9]*' "$rlog" | tail -1 | cut -d: -f2)
    fi
    printf '{"pr":%s,"stage":"%s","start":%s,"end":%s,"duration_s":%s,"exit":%s,"iterations":%s,"llm_duration_ms":%s,"log":"%s"}\n' \
      "$num" "$stage" "$s" "$e" "$((e - s))" "$rc" "${iters:-null}" "${durms:-null}" "${rlog##*/}" >> "$STATS"
    log "batch: pr=$num stage=$stage duration=$((e - s))s exit=$rc"
  done
done < "$LIST"

# ---- summary (stderr of this script goes to the batch log) ----
python3 - "$STATS" <<'PYEOF'
import json, statistics, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by = {}
for r in rows:
    by.setdefault(r["stage"], []).append(r)
print("==== batch summary ====")
for stage, rs in sorted(by.items()):
    ds = [r["duration_s"] for r in rs]
    ok = [r for r in rs if r["exit"] == 0]
    print(f"{stage}: n={len(rs)} ok={len(ok)} total={sum(ds)}s "
          f"mean={statistics.mean(ds):.0f}s median={statistics.median(ds):.0f}s "
          f"min={min(ds)}s max={max(ds)}s")
    for r in sorted(rs, key=lambda x: -x["duration_s"])[:5]:
        print(f"  slowest: PR {r['pr']} {r['duration_s']}s exit={r['exit']} "
              f"iters={r.get('iterations')} llm_ms={r.get('llm_duration_ms')}")
PYEOF
