#!/usr/bin/env python3
"""issue-release.py — clear in-flight markers owned by one parallel line.

issue-select.sh marks the picked record with in_flight_slot=<n> (or "host"
for the legacy host line) so parallel lines never hand the same issue to
two workers. This script clears those markers when a line's run settles —
called from post-task.sh (both the normal ExecStartPost path and the
post-onfail@ backstop).

Crash heal: even if this script never runs, issue-select.sh re-verifies every
in_flight marker against the owning line's run-s<n>.lock / run.lock; a free
lock proves the run is over, so the marker is reclaimed there on the next pass.
"""
import fcntl
import json
import os
import sys

# Host (legacy) line marks its picks as in_flight_slot="host" too — without
# that, a slot could re-pick the issue the host run is actively working.
slot = os.environ.get("HFV_SLOT", "") or "host"

base_dir = os.path.dirname(os.path.abspath(__file__))
store = os.path.join(base_dir, "issues.jsonl")
if not os.path.exists(store):
    sys.exit(0)

# Shared store lock (same discipline as issue-select.sh / issue_recorder.py).
_lock = open(os.path.join(base_dir, ".store.lock"), "w")
fcntl.flock(_lock, fcntl.LOCK_EX)

records = []
for line in open(store):
    line = line.strip()
    if line:
        try:
            records.append(json.loads(line))
        except Exception:
            pass

cleared = 0
for r in records:
    if r.get("in_flight_slot") == slot:
        r.pop("in_flight_slot", None)
        r.pop("in_flight_at", None)
        cleared += 1

if cleared:
    tmp = store + ".tmp"
    with open(tmp, "w") as f:
        for r in records:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(tmp, store)
print(f"issue-release: cleared {cleared} in-flight marker(s) for slot {slot}")