#!/usr/bin/env bash
# issue-prune.sh — delete TERMINAL-FINISHED issues (state merged/closed only)
# older than the sliding window (WINDOW_DAYS, default 7 days) from
# issues.jsonl, together with their attachment dirs.
# Records in any other state (open / done / abandoned / fail) are NEVER
# pruned by age: a done record's PR may still be open and needs pr-follow
# (review nudges), an open record is still in play. The lifecycle is
#   done --(PR merged / issue closed by issue-sync)--> merged/closed
#       --(this prune after WINDOW_DAYS)--> removed
# With completion recorded as a state flip (issue-sync.sh), pruning is the
# single place records (and their attachments) eventually leave the store.
# Standalone-runnable; the recorder wrapper calls it at the end of every
# recording pass.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config"
WINDOW_DAYS="${WINDOW_DAYS:-7}"
STORE="$DIR/issues.jsonl"
[ -f "$STORE" ] || exit 0

python3 - "$STORE" "$WINDOW_DAYS" <<'PYEOF'
import fcntl, json, os, shutil, sys, time
store, days = sys.argv[1], int(sys.argv[2])
# Shared store lock (see issue_recorder.py STORE_LOCK): serialize whole-store
# rewrites against recorder / pr-follow / sync / select / pre-claim writers.
_lock = open(os.path.join(os.path.dirname(store), ".store.lock"), "w")
fcntl.flock(_lock, fcntl.LOCK_EX)
cutoff = int(time.time() * 1000) - days * 86400 * 1000
adir = os.path.join(os.path.dirname(store), "attachments")
# Only merged/closed records are prunable: they are the truly finished
# states. done keeps its open PR followable; open/abandoned/fail stay too.
PRUNABLE = ("merged", "closed")
kept, removed = [], 0
for line in open(store):
    line = line.strip()
    if not line:
        continue
    try:
        r = json.loads(line)
    except Exception:
        continue
    if r.get("state") in PRUNABLE and r.get("create_time", 0) < cutoff:
        removed += 1
        shutil.rmtree(os.path.join(adir, str(r.get("message_id"))), ignore_errors=True)
    else:
        kept.append(r)
tmp = store + ".tmp"
with open(tmp, "w") as f:
    for r in kept:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
os.replace(tmp, store)
print(f"pruned={removed} kept={len(kept)} window_days={days}")
PYEOF
