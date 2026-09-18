#!/usr/bin/env python3
"""Record issue-raised PRs' GitHub outcomes into ClickHouse (cline.prs).

Reads the LOCAL gh-store snapshots (lines/gh-store/pr-<n>.json + the sibling
pr-<n>-comments.jsonl) maintained by gh-recorder's every-minute scan — this
tool NEVER calls GitHub. A row is appended only when a PR's outcome tuple
changes (state / merged / conversation counts / head oid), so every row is a
real transition. Unlike the 90-day run telemetry (cline.runs & friends) this
table has NO TTL: final states (MERGED / CLOSED) are the long-term record of
what became of the PRs the issue/feat pipelines raised.

Per PR we record:
  merged          1 iff GitHub state == MERGED (被合并与否)
  conversations   issue comments + review submissions + inline review
                  comments (GitHub 上的对话数量: channel histogram of the
                  reconciled 3-channel comments JSONL; falls back to the
                  snapshot's gh-shaped comment/review list lengths)

Run standalone for a backfill, or from gh-recorder after each scan pass.
Env: PR_OUTCOMES_DRY_RUN=1 prints what would be inserted, writes nothing.
"""
import fcntl
import glob
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # repo root
sys.path.insert(0, DIR)
from hfv_config import load as _load_hfv  # noqa: E402

CH = _load_hfv()["CLICKHOUSE_HTTP"]
GH_STORE = os.path.join(DIR, "lines", "gh-store")
DRY_RUN = os.environ.get("PR_OUTCOMES_DRY_RUN") == "1"

DDL = """CREATE TABLE IF NOT EXISTS cline.prs (
    pr UInt32,
    title String,
    url String,
    state String,
    merged UInt8,
    merged_at Nullable(DateTime),
    closed_at Nullable(DateTime),
    issue_comments UInt32,
    reviews UInt32,
    review_comments UInt32,
    conversations UInt32,
    head_oid String,
    scanned_at DateTime DEFAULT now()
) ENGINE = MergeTree ORDER BY (pr, scanned_at)"""


def ch_query(query, body=None):
    url = CH + "?query=" + urllib.parse.quote(query)
    # always POST: GET implies readonly mode on the HTTP interface
    req = urllib.request.Request(url, data=body.encode() if body is not None else b"")
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode()


def _dt(iso):
    """ISO-8601 gh timestamp -> ClickHouse DateTime string (UTC), None if empty."""
    if not iso:
        return None
    return iso.replace("T", " ").replace("Z", "").split(".")[0]


def _conv_counts(num, snap):
    """(issue_comments, reviews, review_comments) from the reconciled 3-channel
    comments JSONL; falls back to the snapshot's gh-shaped lists (no inline)."""
    jsonl = os.path.join(GH_STORE, "pr-%d-comments.jsonl" % num)
    counts = {"issue": 0, "review": 0, "inline": 0}
    try:
        with open(jsonl) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    ch = json.loads(line).get("channel")
                except Exception:
                    continue
                if ch in counts:
                    counts[ch] += 1
        return counts["issue"], counts["review"], counts["inline"]
    except OSError:
        return (len(snap.get("comments") or []),
                len(snap.get("reviews") or []), 0)


def _outcome_row(snap):
    num = int(snap.get("num") or 0)
    if not num or not snap.get("state"):
        return None
    ic, rv, rc = _conv_counts(num, snap)
    state = snap.get("state") or ""
    return {
        "pr": num,
        "title": snap.get("title") or "",
        "url": snap.get("url") or "",
        "state": state,
        "merged": 1 if state == "MERGED" else 0,
        "merged_at": _dt(snap.get("merged_at") or ""),
        "closed_at": _dt(snap.get("closed_at") or ""),
        "issue_comments": ic,
        "reviews": rv,
        "review_comments": rc,
        "conversations": ic + rv + rc,
        "head_oid": snap.get("head_oid") or "",
    }


def _last_path(num):
    return os.path.join(GH_STORE, "pr-%d-outcome.json" % num)


# the dedupe key: anything whose change is worth a new ClickHouse row
_KEY = ("state", "merged", "issue_comments", "reviews", "review_comments",
        "head_oid")


def main():
    # a manual run must not interleave with an in-flight recorder pass — take
    # the recorder's flock. The recorder itself invokes us mid-pass with
    # PR_OUTCOMES_FROM_RECORDER=1 (it already holds the lock; flocking then
    # would deadlock the pass).
    if os.environ.get("PR_OUTCOMES_FROM_RECORDER") != "1":
        fd = os.open(os.path.join(DIR, "lines", ".gh-recorder.lock"),
                     os.O_CREAT | os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("pr_outcomes: recorder pass in flight — skipped")
            return 0
    rows, skipped = [], 0
    for path in sorted(glob.glob(os.path.join(GH_STORE, "pr-*.json"))):
        base = os.path.basename(path)
        if not re.fullmatch(r"pr-\d+\.json", base):
            continue  # pr-<n>-comments.jsonl / -outcome.json siblings
        try:
            snap = json.load(open(path))
        except Exception:
            continue
        row = _outcome_row(snap)
        if not row:
            continue
        last = None
        try:
            last = json.load(open(_last_path(row["pr"])))
        except Exception:
            pass
        if last and all(last.get(k) == row[k] for k in _KEY):
            skipped += 1
            continue  # no transition since the last recorded row
        rows.append(row)

    if rows:
        body = "\n".join(json.dumps(r, ensure_ascii=False) for r in rows)
        if DRY_RUN:
            print("DRY RUN — would insert %d row(s):" % len(rows))
            print(body)
            return 0
        ch_query(DDL)
        ch_query("INSERT INTO cline.prs FORMAT JSONEachRow", body)
        for r in rows:  # mark emitted only after the insert succeeded
            tmp = _last_path(r["pr"]) + ".tmp"
            with open(tmp, "w") as f:
                json.dump(r, f, ensure_ascii=False)
            os.rename(tmp, _last_path(r["pr"]))
    print("pr_outcomes: %d transition(s) recorded, %d PR(s) unchanged"
          % (len(rows), skipped))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (urllib.error.URLError, OSError) as e:
        # ClickHouse being down must never take the recorder with it
        print("pr_outcomes: clickhouse unreachable, skipped (%s)" % e)
        sys.exit(0)
