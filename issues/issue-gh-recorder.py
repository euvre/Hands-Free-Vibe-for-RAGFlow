#!/usr/bin/env python3
"""issue-gh-recorder.py — GitHub issue source: record label=bug issues into
the same store the Feishu recorder feeds (issues/issues.jsonl).

Source abstraction (2026-08-31): an issue SOURCE is either the Feishu group
(issue_recorder.py, source="feishu", message_id=om_...) or the GitHub issue
tracker (this script, source="github", message_id=gh-<number>). Downstream
(select / assign / run-task / deliver / post-reply / sync) treat message_id
as an opaque key; every Feishu-specific touchpoint dispatches on the
"gh-" prefix instead.

Record rules (all read-only GitHub calls via the gh CLI, host-side auth):
  * open issues with the configured label (default "bug")
  * updated within the sliding WINDOW_DAYS (the prune window uses
    create_time, so older issues would be pruned instantly anyway;
    create_time = updatedAt keeps FIFO freshness = "active bugs first")
  * NOT already assigned to someone (a third party claimed it — parallel to
    the Feishu @-claim check in select)
  * NOT already commented by our own account (we replied / delivered a PR
    before; re-recording after prune would duplicate that work)
  * at most GITHUB_ISSUE_MAX new records per pass (FIFO flood guard)

text_full carries the title, url, body and the most recent comments (capped)
so the LLM run works from current.json exactly like a Feishu issue; reporter
comments are mirrored into `replies` with the same {sender_type, text} shape
the task prompt already reads. Screenshot/video URLs referenced in the body
or comments (markdown images, user-attachments links) are downloaded into
attachments/gh-<number>/ at record time, so the vision pre-pass transcribes
them exactly like Feishu attachments.
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

base_dir = os.path.dirname(os.path.abspath(__file__))
store = os.path.join(base_dir, "issues.jsonl")
GH_BIN = os.environ.get("GH_BIN", "gh")

cfg = {}
for line in open(os.path.join(base_dir, "config")):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        cfg[k.strip()] = v.strip().strip('"')

REPO = cfg.get("GITHUB_ISSUE_REPO", "infiniflow/ragflow")
LABEL = cfg.get("GITHUB_ISSUE_LABEL", "🐞 bug")
# accept both key names (see issue-sync.sh): empty OWN_LOGIN also disabled the
# "we already commented there" re-record backstop.
OWN_LOGIN = cfg.get("OWN_LOGIN") or cfg.get("GITHUB_LOGIN", "")
MAX_NEW = int(cfg.get("GITHUB_ISSUE_MAX", "3") or 3)
WINDOW_MS = int(cfg.get("WINDOW_DAYS", "7") or 7) * 86400 * 1000


def gh_list():
    """Open, labeled issues — newest-updated first. None on any failure
    (a partial GitHub outage must not corrupt the store)."""
    try:
        out = subprocess.run(
            [GH_BIN, "issue", "list", "--repo", REPO, "--label", LABEL,
             "--state", "open", "--limit", "30", "--json",
             "number,title,body,url,updatedAt,assignees,comments,author"],
            capture_output=True, text=True, timeout=60)
        if out.returncode != 0:
            print("gh-record: gh issue list failed: %s" % out.stderr.strip()[:200])
            return None
        return json.loads(out.stdout)
    except Exception as e:
        print("gh-record: gh issue list error: %s" % e)
        return None


IMG_URL_RE = re.compile(
    r"!\[[^\]]*\]\((https?://[^\s)]+)\)"           # markdown image
    r"|(https?://github\.com/user-attachments/assets/[\w-]+)"  # bare link
    r"|(https?://[^\s)>]+\.(?:png|jpe?g|gif|webp|mp4|mov))", re.I)
ATTACH_BASE = os.path.join(base_dir, "attachments")


def _ext_for(url, ctype):
    """Extension from the Content-Type (user-attachments links carry none)."""
    table = {"image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif",
             "image/webp": ".webp", "video/mp4": ".mp4", "video/quicktime": ".mov"}
    if ctype in table:
        return table[ctype]
    m = re.search(r"\.(png|jpe?g|gif|webp|mp4|mov)(?:\?|$)", url, re.I)
    return "." + m.group(1).lower() if m else ""


def download_images(mid, texts):
    """Pull every image/video URL out of the given texts into
    attachments/<mid>/img_NN.<ext>; returns the repo-relative paths."""
    urls = []
    for text in texts:
        for m in IMG_URL_RE.finditer(text or ""):
            u = next(g for g in m.groups() if g)
            if u not in urls:
                urls.append(u)
    if not urls:
        return []
    adir = os.path.join(ATTACH_BASE, mid)
    os.makedirs(adir, exist_ok=True)
    out = []
    for i, url in enumerate(urls, 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "hfv-gh-recorder"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                ctype = (resp.headers.get("Content-Type") or "").split(";")[0].strip().lower()
                ext = _ext_for(url, ctype)
                if not ext:
                    continue  # neither a known media type nor a media suffix
                data = resp.read(20 * 1024 * 1024)
            name = "img_%02d%s" % (i, ext)
            with open(os.path.join(adir, name), "wb") as f:
                f.write(data)
            out.append(os.path.join("attachments", mid, name))
        except Exception as e:
            print("gh-record: image download failed %s: %s" % (url[:80], e))
    return out


def main():
    issues = gh_list()
    if issues is None:
        return 0
    # shared store lock — same discipline as every other store writer
    _lock = open(os.path.join(base_dir, ".store.lock"), "w")
    fcntl.flock(_lock, fcntl.LOCK_EX)

    known = set()
    if os.path.exists(store):
        for line in open(store):
            line = line.strip()
            if not line:
                continue
            try:
                known.add(json.loads(line).get("message_id", ""))
            except Exception:
                pass

    now = int(time.time() * 1000)
    added = 0
    skipped = 0
    # newest-updated first from gh; record oldest-first so FIFO order in the
    # store matches activity order (stable regardless of write batching)
    for it in reversed(issues):
        if added >= MAX_NEW:
            break
        mid = "gh-%d" % it.get("number", 0)
        if mid in known:
            continue
        try:
            updated = int(
                time.mktime(time.strptime(it["updatedAt"][:19], "%Y-%m-%dT%H:%M:%S"))
                * 1000)
        except Exception:
            continue
        if updated < now - WINDOW_MS:
            skipped += 1  # inactive beyond the sliding window
            continue
        if it.get("assignees"):
            skipped += 1  # someone owns it already
            continue
        comments = it.get("comments") or []
        if any((c.get("author") or {}).get("login") == OWN_LOGIN for c in comments):
            skipped += 1  # we already replied / delivered here once
            continue
        recent = comments[-5:]
        replies = [{
            "sender_type": "user",
            "text": "%s: %s" % ((c.get("author") or {}).get("login", "?"),
                                (c.get("body") or "")[:1500]),
            "images": download_images(mid, [c.get("body") or ""]),
        } for c in recent]
        body = (it.get("body") or "").strip()
        images = download_images(mid, [body])
        text_full = "GitHub issue #%d %s\n\n%s\n\n--- reporter/recent comments ---\n%s" % (
            it.get("number", 0), it.get("url", ""),
            body[:4000] or "(no body)",
            "\n".join(r["text"] for r in replies) or "(none)")
        rec = {
            "message_id": mid,
            "source": "github",
            "thread_id": "",
            "create_time": updated,
            "text": ("gh#%d %s" % (it.get("number", 0),
                                   (it.get("title") or "").strip()))[:200],
            "text_full": text_full,
            "images": images,
            "files": [],
            "resource_keys": [],
            "replies": replies,
            "sender_id": (it.get("author") or {}).get("login", ""),
            "url": it.get("url", ""),
            "number": it.get("number", 0),
            "state": "open",
            "recorded_at": now,
        }
        with open(store, "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        known.add(mid)
        added += 1
        print("gh-record: added %s %s" % (mid, rec["text"][:80]))
    print("gh-record: added=%d skipped=%d total_candidates=%d" %
          (added, skipped, len(issues)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
