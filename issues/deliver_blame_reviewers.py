#!/usr/bin/env python3
"""deliver_blame_reviewers.py — recommend extra PR reviewers from git blame.

Given a delivery branch, walk the diff's hunks and blame the OLD (base-side)
lines being changed: the people who last touched that code are the natural
reviewers. Emails are mapped to GitHub logins via the noreply-address
convention (<id>+<login>@users.noreply.github.com) with a cached
`gh api search/users` fallback for real addresses. The result is intersected
with team-map.json (only team members make sense as reviewers), excluding the
fork account, the fixed reviewer (the merge owner), and bots.

Usage: deliver_blame_reviewers.py <workdir> <base-ref> <head-ref>
Prints: comma-separated logins (empty when none) on stdout.
Diagnostics go to stderr. This tool NEVER fails the delivery: any internal
error degrades to an empty list.
"""
import json
import os
import re
import subprocess
import sys
from collections import Counter

DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(DIR, ".."))
from hfv_config import load  # noqa: E402

CFG = load()
TEAM_MAP = os.path.join(DIR, "..", "team-map.json")
EMAIL_CACHE = os.path.join(DIR, ".gh-email-cache.json")
MAX_FILES = 10        # blame only the most-touched files (diff-line count)
# Cap the EXTRA (blame-informed) reviewer requests per PR — the merge owner is always
# requested separately by the deliver script. Configurable via hfv.conf.
MAX_REVIEWERS = int(CFG.get("BLAME_MAX_REVIEWERS", "1"))
BOT_RE = re.compile(r"(?i)(\[bot\]$|bot$|^github-actions$|^coderabbit)")
NOREPLY_RE = re.compile(r"^(?:\d+\+)?([^@+]+)@users\.noreply\.github\.com$")
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def log(msg):
    sys.stderr.write("blame-reviewers: %s\n" % msg)


def git(workdir, *args):
    p = subprocess.run(["git", "-C", workdir] + list(args),
                       capture_output=True, text=True, timeout=120)
    if p.returncode != 0:
        raise RuntimeError("git %s failed: %s" % (args[0], p.stderr.strip()[:200]))
    return p.stdout


def changed_hunks(workdir, base, head):
    """→ {path: [(base_start, base_count), ...]} for text files, diff-line counted."""
    out = git(workdir, "diff", "--unified=0", "--diff-filter=ACMRT",
              "%s...%s" % (base, head))
    files = {}
    cur = None
    for line in out.splitlines():
        if line.startswith("+++ b/"):
            cur = line[6:]
            files.setdefault(cur, [])
        elif line.startswith("+++"):
            cur = None
        elif cur and line.startswith("@@"):
            m = HUNK_RE.match(line)
            if not m:
                continue
            start = int(m.group(1))
            count = int(m.group(2) or "1")
            if count > 0:  # pure additions have no base-side lines to blame
                files[cur].append((start, count))
    return files


def blame_emails(workdir, base, path, start, count):
    """→ Counter of author emails over the given base-side line range."""
    end = start + count - 1
    out = git(workdir, "blame", "--line-porcelain", "-L", "%d,%d" % (start, end),
              base, "--", path)
    emails = Counter()
    for line in out.splitlines():
        if line.startswith("author-mail "):
            emails[line[12:].strip("<> ")] += 1
    return emails


def load_json(path, default):
    try:
        return json.load(open(path))
    except Exception:
        return default


def save_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def email_to_login(email, cache):
    """→ GitHub login or None. Noreply addresses parse offline; real emails
    hit the search API once and cache the result (including negative hits)."""
    m = NOREPLY_RE.match(email)
    if m:
        return m.group(1)
    if email in cache:
        return cache[email] or None
    login = ""
    try:
        p = subprocess.run(
            ["gh", "api", "-X", "GET", "search/users", "-f", "q=%s in:email" % email,
             "--jq", ".items[0].login // \"\""],
            capture_output=True, text=True, timeout=30)
        if p.returncode == 0:
            login = p.stdout.strip()
    except Exception:
        pass
    cache[email] = login
    return login or None


def main():
    if len(sys.argv) != 4:
        sys.stderr.write(__doc__)
        return 2
    workdir, base, head = sys.argv[1], sys.argv[2], sys.argv[3]
    try:
        team = {m["github"] for m in load_json(TEAM_MAP, {}).get("members", [])
                if m.get("github")}
    except Exception as e:
        log("team-map unreadable (%s) — no recommendations" % e)
        print("")
        return 0
    excluded = {CFG.get("OWN_LOGIN", ""), CFG.get("PR_REVIEWER", "")}
    # People who must never be auto-requested (hfv.conf: BLAME_REVIEWER_EXCLUDE).
    excluded |= {x.strip() for x in
                 CFG.get("BLAME_REVIEWER_EXCLUDE", "").split(",") if x.strip()}
    try:
        files = changed_hunks(workdir, base, head)
    except Exception as e:
        log("diff failed (%s) — no recommendations" % e)
        print("")
        return 0
    if not files:
        log("no blamable hunks (pure additions?)")
        print("")
        return 0
    # Blame the most-touched files only, to bound runtime and API traffic.
    by_lines = sorted(files.items(),
                      key=lambda kv: -sum(c for _, c in kv[1]))[:MAX_FILES]
    email_score = Counter()
    for path, hunks in by_lines:
        for start, count in hunks:
            try:
                email_score.update(blame_emails(workdir, base, path, start, count))
            except Exception as e:
                log("blame %s@%d skipped (%s)" % (path, start, e))
    cache = load_json(EMAIL_CACHE, {})
    login_score = Counter()
    for email, score in email_score.most_common(20):
        login = email_to_login(email, cache)
        if login:
            login_score[login] += score
    try:
        save_json(EMAIL_CACHE, cache)
    except Exception:
        pass
    picks = [login for login, _ in login_score.most_common()
             if login in team and login not in excluded and not BOT_RE.search(login)]
    picks = picks[:MAX_REVIEWERS]
    log("emails=%d logins=%d picks=%s"
        % (len(email_score), len(login_score), ",".join(picks) or "none"))
    print(",".join(picks))
    return 0


if __name__ == "__main__":
    sys.exit(main())
