#!/usr/bin/env python3
"""issue-quota-demote.py — demote an LLM-quota-failed issue instead of failing it.

run-task.sh gives up a run when the quota retry budget is exhausted (kind=quota
give-up) and drops logs/.quota-dead$SUF; post-task.sh consumes the marker and
calls this script. The picked issue did nothing wrong — burning its
select_count toward the terminal "fail" state (MAX_PICKS in issue-select.sh)
turned a shared quota outage into per-issue damage on 2026-08-26 night (two
issues were failed after three quota-dead picks each). Instead:

  * select_count -= 1 (floor 0)  — the quota pick never happened
  * priority_penalty += 1        — demoted one class in issue-select.sh's sort
                                   key (priority_penalty, create_time), so
                                   healthier issues get the slots first while
                                   quota recovers
  * state stays open             — re-picked from the demoted class forever;
                                   quota can no longer march it into fail

The record is identified via issues/current$SUF.json (the selection this run
held). Best-effort by design: missing store/current/message_id just logs and
exits 0 — a demotion is an optimization, never worth failing post-task over.
"""
import fcntl
import json
import os
import sys
import time

base_dir = os.path.dirname(os.path.abspath(__file__))
store = os.path.join(base_dir, "issues.jsonl")
log_dir = os.path.join(base_dir, "..", "logs")
os.makedirs(log_dir, exist_ok=True)


def log(msg):
    with open(os.path.join(log_dir, "daemon.log"), "a") as f:
        f.write("[%s] %s\n" % (time.strftime("%Y%m%d-%H%M%S"), msg))


_suf = ("-s" + os.environ["HFV_SLOT"]) if os.environ.get("HFV_SLOT") else ""
current = os.path.join(base_dir, "current%s.json" % _suf)

if not os.path.exists(store) or not os.path.exists(current):
    log("issue-quota-demote: store or current%s.json missing, nothing to demote" % _suf)
    sys.exit(0)

mid = ""
try:
    mid = json.load(open(current)).get("message_id", "")
except Exception:
    pass
if not mid:
    log("issue-quota-demote: current%s.json carries no message_id, nothing to demote" % _suf)
    sys.exit(0)

# Shared store lock (same discipline as issue-select.sh / issue-release.py).
_lock = open(os.path.join(base_dir, "..", "locks", ".store.lock"), "w")
fcntl.flock(_lock, fcntl.LOCK_EX)

records = []
for line in open(store):
    line = line.strip()
    if line:
        try:
            records.append(json.loads(line))
        except Exception:
            pass

hit = [r for r in records if r.get("message_id") == mid]
if not hit:
    log("issue-quota-demote: %s not in store (dropped?), nothing to demote" % mid)
    sys.exit(0)

r = hit[0]
r["select_count"] = max(0, r.get("select_count", 0) - 1)
r["priority_penalty"] = r.get("priority_penalty", 0) + 1
if r.get("state") == "fail":
    # Defensive heal: the fail-flip runs on the NEXT tick's select pass, so a
    # fail here means ordering changed and a quota path left a terminal state
    # behind — undo it rather than strand the record.
    r["state"] = "open"
    r.pop("fail_time", None)
    log("issue-quota-demote: %s was already fail (ordering?), healed back to open" % mid)

tmp = store + ".tmp"
with open(tmp, "w") as f:
    for rec in records:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
os.replace(tmp, store)
log("issue-quota-demote: %s un-counted the quota pick, priority_penalty=%d (stays open)"
    % (mid, r["priority_penalty"]))
