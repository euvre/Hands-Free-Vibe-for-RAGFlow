#!/usr/bin/env python3
"""issue-mark-done.py — flip a store record to done LOCALLY at delivery time.

The done flip used to depend on two asynchronous external signals: the
gh-recorder creating the PR and replying its link into the thread, then the
next post group's issue-sync pass reading that link. Between delivery and
that flip the record stayed open and pickable — the next tick re-selected
the same issue and delivered a duplicate PR (tasks 346/347 → PRs
#19853/#19857; upstream closed the second with "already fixed in other
PRs"). This script closes that window: post-deliver.sh calls it the moment
the PR creation is enqueued.

issue-sync.sh's thread-side scan still runs afterwards and backfills the
concrete PR url into the record (it keys off the PR link appearing in the
thread); the state itself is already terminal here.

usage: issue-mark-done.py <message_id> [pr_ref]
Idempotent: terminal records (done/merged/closed/abandoned/fail) untouched;
the delivered_at stamp is written once. A missing record is a logged no-op.
ISSUES_DIR env override for tests.
"""
import fcntl
import json
import os
import sys
import time

BASE = os.environ.get("ISSUES_DIR") or os.path.dirname(os.path.abspath(__file__))
STORE = os.path.join(BASE, "issues.jsonl")
LOG = os.path.join(BASE, "..", "logs", "daemon.log")
LOCK = os.path.join(BASE, "..", "locks", ".store.lock")
TERMINAL = ("done", "merged", "closed", "abandoned", "fail")


def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            f.write("[%s] issue-mark-done: %s\n" % (time.strftime("%Y%m%d-%H%M%S"), msg))
    except Exception:
        pass


def main():
    if len(sys.argv) < 2:
        print("usage: issue-mark-done.py <message_id> [pr_ref]", file=sys.stderr)
        return 1
    mid = sys.argv[1]
    pr_ref = sys.argv[2] if len(sys.argv) > 2 else ""
    if not os.path.exists(STORE):
        return 0

    lock = open(LOCK, "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        records = []
        for line in open(STORE):
            line = line.strip()
            if line:
                try:
                    records.append(json.loads(line))
                except Exception:
                    pass
        now = int(time.time() * 1000)
        for r in records:
            if r.get("message_id") != mid:
                continue
            if r.get("state") in TERMINAL:
                log("%s already %s — untouched" % (mid, r.get("state")))
                return 0
            r["state"] = "done"
            r.setdefault("delivered_at", now)
            if pr_ref:
                r["delivered_pr"] = pr_ref  # branch name; URL backfilled by issue-sync
            log("%s -> done (delivered_pr=%s)" % (mid, pr_ref or "-"))
            break
        else:
            log("%s not in store — nothing marked" % mid)
            return 0
        tmp = STORE + ".tmp"
        with open(tmp, "w") as f:
            for r in records:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        os.replace(tmp, STORE)
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
