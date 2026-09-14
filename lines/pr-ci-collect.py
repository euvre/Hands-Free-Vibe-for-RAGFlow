#!/usr/bin/env python3
"""pr-ci-collect.py — candidate collector for the pr-ci line (CI-failure fix).

Each tick answers: which of OUR open PRs currently have failing GitHub
Actions checks, are NOT conflicting (conflicts are the rebase line's turf),
are NOT mid-run (pending checks settle on their own), and are not inside the
cooldown / retry budget?

Ledger (issues/pr-ci.json), keyed by PR number:
  {"sha": head sha last attempted, "same_sha_attempts": int,
   "day": "YYYY-MM-DD", "day_count": int, "last_at": ms, "fails": [names]}

Subcommands:
  collect           → TSV rows: num \t branch \t url \t mid \t fails(csv)
  resolve <num>     → same row for ONE PR (manual path via `hfv pr ci <N>`):
                      cooldown/budget bypassed, but the PR must still be OPEN,
                      non-conflicting and have failing actions checks right now
  stamp <num> <sha> → record one fix attempt (win or lose) after the LLM stage
"""
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime

DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # repo root (this file lives in lines/)
sys.path.insert(0, DIR)
from hfv_config import load  # noqa: E402

CFG = load()
REPO = CFG["GITHUB_REPO"]
OWN = CFG["OWN_LOGIN"]
LEDGER = os.path.join(DIR, "issues", "pr-ci.json")
ISSUES = os.path.join(DIR, "issues", "issues.jsonl")
COOLDOWN_MS = int(CFG.get("CI_FIX_COOLDOWN_MINUTES", "90")) * 60_000
MAX_SAME_SHA = int(CFG.get("CI_FIX_MAX_ATTEMPTS", "2"))
MAX_PER_DAY = int(CFG.get("CI_FIX_MAX_PER_DAY", "3"))

PR_REF = re.compile(r"(?:pull/|#)(\d+)")


def log(msg):
    sys.stderr.write("pr-ci-collect: %s\n" % msg)


def now_ms():
    return int(time.time() * 1000)


def run(cmd, timeout=60):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout
    except Exception as e:
        log("cmd failed (%s): %s" % (cmd[0], e))
        return 1, ""


def load_ledger():
    if os.path.exists(LEDGER):
        try:
            return json.load(open(LEDGER))
        except Exception:
            pass
    return {}


def save_ledger(d):
    tmp = LEDGER + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=1, sort_keys=True)
    os.replace(tmp, LEDGER)


def mid_for(num):
    """Best-effort issue message_id for this PR (empty when untracked)."""
    if not os.path.exists(ISSUES):
        return ""
    try:
        for line in open(ISSUES):
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            m = PR_REF.search(r.get("pr") or "")
            if m and int(m.group(1)) == num:
                return r.get("message_id", "")
    except Exception:
        pass
    return ""



def failing_checks(num):
    """→ (state, [failed check names]); state ∈ fail / pending / none.
    Only GitHub Actions checks count (CodeRabbit & co. have no run link)."""
    rc, out = run(["gh", "pr", "checks", str(num), "--repo", REPO,
                   "--json", "bucket,name,link"])
    if rc != 0 or not out.strip():
        return "none", []
    try:
        checks = json.loads(out)
    except Exception:
        return "none", []
    actions = [c for c in checks if "/actions/runs/" in (c.get("link") or "")]
    if not actions:
        return "none", []
    fails = sorted(c["name"] for c in actions
                   if (c.get("bucket") or "") == "fail")
    if fails:
        return "fail", fails
    if any((c.get("bucket") or "") == "pending" for c in actions):
        return "pending", []
    return "none", []


def row(num, branch, url, fails, scope="own"):
    return "%d\t%s\t%s\t%s\t%s\t%s" % (num, branch, url, mid_for(num),
                                       ",".join(fails), scope)


def gate(num, sha, led):
    """ledger cooldown/budget gates; returns a skip reason or None."""
    ent = led.get(str(num)) or {}
    now = now_ms()
    if ent.get("sha") == sha:
        if ent.get("same_sha_attempts", 0) >= MAX_SAME_SHA:
            return "sha %s already attempted %dx (budget %d)" % (
                sha[:9], ent["same_sha_attempts"], MAX_SAME_SHA)
        if now - (ent.get("last_at") or 0) < COOLDOWN_MS:
            return "inside %dmin cooldown" % (COOLDOWN_MS // 60000)
    today = datetime.now().strftime("%Y-%m-%d")
    if ent.get("day") == today and ent.get("day_count", 0) >= MAX_PER_DAY:
        return "daily budget exhausted (%dx today)" % ent["day_count"]
    return None


def collect():
    rc, out = run(["gh", "pr", "list", "--repo", REPO, "--author", OWN,
                   "--state", "open", "--limit", "100",
                   "--json", "number,headRefName,headRefOid,url,mergeable"])
    if rc != 0 or not out.strip():
        log("gh pr list failed — no candidates this tick")
        return
    try:
        prs = json.loads(out)
    except Exception:
        log("gh pr list returned unparseable json")
        return
    led = load_ledger()
    for pr in prs:
        num = pr["number"]
        branch = pr.get("headRefName") or ""
        sha = pr.get("headRefOid") or ""
        if not branch or not sha:
            continue
        mg = (pr.get("mergeable") or "").upper()
        if mg == "CONFLICTING":
            log("pr %d: CONFLICTING — rebase line's turf, skip" % num)
            continue
        if mg == "UNKNOWN":
            log("pr %d: mergeable UNKNOWN (GitHub still computing) — skip" % num)
            continue
        state, fails = failing_checks(num)
        if state == "pending":
            log("pr %d: checks still pending — skip" % num)
            continue
        if state != "fail":
            continue
        why = gate(num, sha, led)
        if why:
            log("pr %d: failing (%s) but gated: %s" % (num, ",".join(fails), why))
            continue
        log("pr %d: CI FAILING (%s) -> candidate" % (num, ",".join(fails)))
        print(row(num, branch, pr.get("url") or "", fails))

    # External PRs: we cannot fix or rerun them (no write/label rights on
    # their branches) — surface them for the notify-only path instead.
    rc, out = run(["gh", "pr", "list", "--repo", REPO,
                   "--state", "open", "--limit", "100",
                   "--json", "number,headRefName,headRefOid,url,mergeable,author"])
    if rc != 0 or not out.strip():
        return
    try:
        prs = json.loads(out)
    except Exception:
        return
    for pr in prs:
        if ((pr.get("author") or {}).get("login") or "").lower() == OWN.lower():
            continue
        num = pr["number"]
        branch = pr.get("headRefName") or ""
        sha = pr.get("headRefOid") or ""
        if not branch or not sha:
            continue
        if (pr.get("mergeable") or "").upper() != "MERGEABLE":
            continue
        state, fails = failing_checks(num)
        if state != "fail":
            continue
        why = gate(num, sha, led)
        if why:
            continue
        log("pr %d: external PR CI FAILING (%s) -> notify candidate" % (num, ",".join(fails)))
        print(row(num, branch, pr.get("url") or "", fails, scope="external"))


def resolve(num):
    rc, out = run(["gh", "pr", "view", str(num), "--repo", REPO,
                   "--json", "state,headRefName,url,mergeable"])
    if rc != 0 or not out.strip():
        log("pr %d: gh lookup failed" % num)
        return
    pr = json.loads(out)
    if (pr.get("state") or "").upper() != "OPEN":
        log("pr %d: not OPEN — nothing to fix" % num)
        return
    if (pr.get("mergeable") or "").upper() == "CONFLICTING":
        log("pr %d: CONFLICTING — that is the rebase line's job (hfv pr rebase %d)"
            % (num, num))
        return
    state, fails = failing_checks(num)
    if state != "fail":
        log("pr %d: no failing actions checks right now (state=%s)" % (num, state))
        return
    print(row(num, pr["headRefName"], pr.get("url") or "", fails))


def stamp(num, sha, action="llm"):
    led = load_ledger()
    ent = led.get(str(num)) or {}
    if ent.get("sha") == sha:
        ent["same_sha_attempts"] = ent.get("same_sha_attempts", 0) + 1
    else:
        ent["sha"] = sha
        ent["same_sha_attempts"] = 1
    ent["action"] = action  # "rerun" (label retrip) or "llm" (code fix)
    today = datetime.now().strftime("%Y-%m-%d")
    if ent.get("day") == today:
        ent["day_count"] = ent.get("day_count", 0) + 1
    else:
        ent["day"] = today
        ent["day_count"] = 1
    ent["last_at"] = now_ms()
    led[str(num)] = ent
    save_ledger(led)
    log("stamped pr %d sha=%s action=%s same_sha=%d day_count=%d"
        % (num, sha[:9], action, ent["same_sha_attempts"], ent["day_count"]))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "collect":
        collect()
    elif cmd == "resolve" and len(sys.argv) > 2:
        resolve(int(sys.argv[2]))
    elif cmd == "stamp" and len(sys.argv) > 3:
        stamp(int(sys.argv[2]), sys.argv[3],
              sys.argv[4] if len(sys.argv) > 4 else "llm")
    else:
        sys.stderr.write(__doc__)
        sys.exit(2)
