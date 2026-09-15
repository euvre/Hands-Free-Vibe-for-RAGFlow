#!/usr/bin/env python3
"""gh-outbox.py — enqueue a GitHub WRITE for the background gh-recorder.

Every GitHub mutation the pipelines need (PR comment, label add/remove, PR
creation) is enqueued here instead of being executed inline: line scripts
and in-container agents append one JSON record per action, and
gh-recorder.py (systemd timer, every minute) drains the queue. Containers
then need no gh binary and no GH_TOKEN for API writes (git push still uses
the credential helper).

usage:
  gh-outbox.py comment   --pr N --body-file F
  gh-outbox.py label     --pr N [--add L] [--remove L]     (both = retrip)
  gh-outbox.py pr-create --branch B --title T --body-file F --mid M
                         [--task-id T] [--reviewers u1,u2]

Each command prints the outbox id on stdout and exits 0 once the record is
durably queued (atomic tmp+rename). A nonzero exit means the action was NOT
queued and the caller must surface the failure itself.
"""
import argparse
import json
import os
import random
import string
import sys
import time

DIR = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(DIR, "gh-outbox")


def enqueue(rec):
    rec.setdefault("attempts", 0)
    rec["created"] = int(time.time() * 1000)
    rid = "%d-%s" % (rec["created"], "".join(
        random.choices(string.ascii_lowercase + string.digits, k=8)))
    rec["id"] = rid
    pend = os.path.join(OUT, "pending")
    os.makedirs(pend, exist_ok=True)
    # in-container enqueuers run as a different uid than the host-side
    # recorder — the queue dir and every record must be cross-uid writable
    try:
        os.chmod(pend, 0o777)
    except OSError:
        pass
    tmp = os.path.join(pend, ".%s.tmp" % rid)
    with open(tmp, "w") as f:
        json.dump(rec, f, ensure_ascii=False)
    os.rename(tmp, os.path.join(pend, rid + ".json"))
    try:
        os.chmod(os.path.join(pend, rid + ".json"), 0o666)
    except OSError:
        pass
    print(rid)
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="kind", required=True)

    c = sub.add_parser("comment", help="post one PR comment")
    c.add_argument("--pr", type=int, required=True)
    c.add_argument("--body-file", required=True)

    l = sub.add_parser("label", help="add/remove a PR label (both = retrip)")
    l.add_argument("--pr", type=int, required=True)
    l.add_argument("--add", default="")
    l.add_argument("--remove", default="")

    p = sub.add_parser("pr-create", help="create the PR for an already-pushed branch")
    p.add_argument("--branch", required=True)
    p.add_argument("--title", required=True)
    p.add_argument("--body-file", required=True)
    p.add_argument("--mid", default="",
                   help="issue message_id — the PR-link reply goes to that thread")
    p.add_argument("--dm-owner", action="store_true",
                   help="feat line: DM the merge owner the PR link instead")
    p.add_argument("--task-id", default="")
    p.add_argument("--reviewers", default="",
                   help="comma-separated reviewer logins (merge owner first)")

    a = ap.parse_args()
    if a.kind == "label" and not (a.add or a.remove):
        ap.error("label needs --add and/or --remove")
    if a.kind == "pr-create" and not (a.mid or a.dm_owner):
        ap.error("pr-create needs --mid or --dm-owner (who gets the PR link)")

    rec = {"kind": a.kind.replace("-", "_")}
    if a.kind == "comment":
        rec.update(pr=a.pr, body=open(a.body_file).read())
    elif a.kind == "label":
        rec.update(pr=a.pr, add=a.add, remove=a.remove)
    else:
        rec.update(branch=a.branch, title=a.title,
                   body=open(a.body_file).read(), mid=a.mid,
                   dm_owner=bool(a.dm_owner),
                   task_id=a.task_id, reviewers=a.reviewers)
    return enqueue(rec)


if __name__ == "__main__":
    sys.exit(main())
