#!/usr/bin/env python3
"""pr-audit.py — state machine for the AUDIT line (WE are the reviewer).

The mirror image of pr-follow.py's collector: instead of reacting to comments
on OUR PRs, this finds OTHER people's PRs that await OUR review.

Candidate sources:
  A. review-requested  gh search prs --review-requested <own>: the author (or
     a maintainer) explicitly asked us to review; every open, non-draft PR
     qualifies.
  B. reviewed-by + new head: PRs we already audited through this system whose
     head sha has moved since (the author pushed new commits addressing our
     findings — re-audit the delta). PRs only ever reviewed manually on the
     web (no state record) are NOT picked up: we cannot tell which head that
     manual review saw.

Skip rules (both sources): non-OPEN state, drafts, bot authors, our own PRs,
and any PR whose current headRefOid equals the sha recorded at its last audit
round — same head, same review, nothing new to say.

State file: issues/pr-audit.json
  {"<num>": {"sha": "<headRefOid at audit time>", "at": <ms>,
             "verdict": "LGTM|PROBLEMS|INCOMPLETE|no-verdict|unpublished-*",
             "rounds": <n>}}
A round is stamped by pr-audit-line.sh's POST stage win or lose: "no-verdict"
(LLM produced no protocol file) and "unpublished-*" (comment post failed) are
recorded too, so a broken round does NOT re-fire on every tick against the
same sha.

Subcommands:
  collect                Print candidates as TSV  num<TAB>sha<TAB>url
                         (oldest PR number first; empty output = rest).
  stamp <num> <sha> <verdict>
                         Record one finished audit round.
  show [num]             Dump the state (all, or one PR) for debugging.
"""
import json
import os
import subprocess
import sys
import time

DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # repo root (this file lives in lines/)
sys.path.insert(0, DIR)
from hfv_config import load as _load_hfv  # noqa: E402

_HFV = _load_hfv()
STATE_FILE = os.path.join(DIR, "issues", "pr-audit.json")
GITHUB_REPO = _HFV["GITHUB_REPO"]
OWN_LOGIN = _HFV["OWN_LOGIN"]

BOT_LOGINS = {
    "github-actions", "codecov", "renovate", "dependabot",
    "copilot-pull-request-reviewer", "coderabbitai", "claude",
}


def log(msg):
    print(msg, file=sys.stderr)


def gh_json(args, timeout_s=60):
    try:
        p = subprocess.run(["gh"] + args, capture_output=True, text=True,
                           timeout=timeout_s)
    except Exception:
        return None
    if p.returncode != 0 or not p.stdout.strip():
        return None
    try:
        return json.loads(p.stdout)
    except Exception:
        return None


def load_state():
    if os.path.exists(STATE_FILE):
        try:
            return json.load(open(STATE_FILE))
        except Exception:
            pass
    return {}


def save_state(state):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, ensure_ascii=False, indent=1, sort_keys=True)
    os.replace(tmp, STATE_FILE)


def is_bot(author):
    login = ((author or {}).get("login") or "").lower()
    return login in BOT_LOGINS or login.endswith("bot") or login.endswith("[bot]")


def nums_from(qualifier):
    """Open PR numbers matching one of --review-requested / --reviewed-by."""
    res = gh_json(["search", "prs", "-R", GITHUB_REPO, qualifier, OWN_LOGIN,
                   "--state", "open", "--limit", "20", "--json", "number"])
    out = []
    for it in res or []:
        try:
            n = int(it.get("number") or 0)
        except (TypeError, ValueError):
            continue
        if n > 0:
            out.append(n)
    return out


def pr_meta(num):
    return gh_json(["pr", "view", str(num), "--repo", GITHUB_REPO, "--json",
                    "number,url,state,isDraft,headRefOid,headRefName,author"])


def collect():
    state = load_state()
    requested = set(nums_from("--review-requested"))
    # source B only re-audits PRs this system already saw: a web-manual review
    # leaves no sha baseline, so "head changed" would be pure guesswork.
    reaudit = {n for n in nums_from("--reviewed-by") if str(n) in state}
    picked = []
    for n in sorted(requested | reaudit):
        meta = pr_meta(n)
        if not meta:
            log("collect: pr %d metadata unavailable, skipped" % n)
            continue
        if (meta.get("state") or "").upper() != "OPEN":
            continue
        if meta.get("isDraft"):
            log("collect: pr %d is draft, skipped" % n)
            continue
        author = (meta.get("author") or {}).get("login") or ""
        if author.lower() == OWN_LOGIN or is_bot(meta.get("author")):
            continue
        sha = meta.get("headRefOid") or ""
        url = meta.get("url") or ""
        if not sha or not url:
            continue
        rec = state.get(str(n)) or {}
        if rec.get("sha") == sha:
            # Same head already judged. LGTM/PROBLEMS are FINAL for this sha
            # (the author's next push re-queues via the sha change). But
            # INCOMPLETE means WE could not verify (infra/env broke), so allow
            # exactly one automatic retry per sha (env may have been fixed) —
            # bounded, so a persistently broken env cannot loop. `hfv pr
            # abandon` never touches this: it writes no state, so an abandoned
            # run is always re-selectable via this same rule or a new push.
            if (rec.get("verdict") == "INCOMPLETE"
                    and int(rec.get("retries") or 0) < 1):
                log("collect: pr %d requeued (INCOMPLETE auto-retry 1/1, "
                    "head=%s)" % (n, sha[:10]))
            else:
                continue  # this exact head was already audited
        log("collect: pr %d queued (source=%s, head=%s)" %
            (n, "requested" if n in requested else "reaudit", sha[:10]))
        picked.append((n, sha, url))
    for n, sha, url in picked:
        print("%d\t%s\t%s" % (n, sha, url))


def stamp(num, sha, verdict):
    state = load_state()
    rec = state.get(str(num)) or {"rounds": 0}
    # retries counts per-sha re-audits (reset on every head change); collect
    # uses it to bound INCOMPLETE auto-retries to one per sha.
    retries = int(rec.get("retries") or 0) + 1 if rec.get("sha") == sha else 0
    rec.update({"sha": sha, "at": int(time.time() * 1000),
                "verdict": verdict, "rounds": int(rec.get("rounds") or 0) + 1,
                "retries": retries})
    state[str(num)] = rec
    save_state(state)
    log("stamp: pr %s audited head=%s verdict=%s round=%d" %
        (num, (sha or "?")[:10], verdict, rec["rounds"]))


def main():
    args = sys.argv[1:]
    if args == ["collect"]:
        collect()
    elif len(args) == 4 and args[0] == "stamp":
        num, sha, verdict = args[1], args[2], args[3]
        if not (num.isdigit() and verdict):
            log("stamp: bad arguments")
            return 2
        stamp(num, sha, verdict)
    elif args and args[0] == "show":
        state = load_state()
        if len(args) > 1:
            print(json.dumps(state.get(args[1], {}), ensure_ascii=False, indent=1))
        else:
            for n in sorted(state, key=lambda k: int(k) if k.isdigit() else 0):
                r = state[n]
                print("%s\t%s\t%s\tround=%d" %
                      (n, (r.get("sha") or "?")[:10], r.get("verdict"),
                       int(r.get("rounds") or 0)))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

