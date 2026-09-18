#!/usr/bin/env python3
"""gh-recorder.py — the GitHub recorder: the ONLY component that talks to GitHub.

Two jobs per pass (systemd timer, every minute; flock-guarded):

1. DRAIN the outbox (lines/gh-outbox/pending/*.json). Every GitHub WRITE the
   pipelines need — PR comments, label add/remove/retrip, PR creation — is an
   outbox record enqueued via gh-outbox.py by line scripts or in-container
   agents. Records retry with backoff; terminal failures are logged (and for
   pr_create reported to the Feishu thread). pr_create is idempotent (reuses
   an existing PR for the same head); comments carry an invisible idempotency
   key (<!-- hfv-outbox:<id> -->) checked against the PR's comments before
   posting, so a record replayed after a mid-drain crash never double-posts.
   pr_create replies the PR link to the originating thread, and archives the
   PR url into tasks/<task_id>/.

2. SCAN tracked PRs (read side). Every PR referenced by a state==done record
   in issues/issues.jsonl (plus anything already under gh-store/) is polled
   cheaply (updatedAt/headRefOid/state); on change the full snapshot is
   refreshed into lines/gh-store/:
     pr-<n>.json        meta + checks + comments/reviews (gh-shaped) — the
                        audit line's pre-scan and pr-follow read this file
     pr-<n>-comments.md complete rendered comment inventory (the reconciled
                        3-channel fetcher output), with image attachments
                        transcribed inline
   Image attachments (markdown images / user-attachments image links) in
   comments are downloaded into gh-store/attachments/pr-<n>/ and transcribed
   with the same Kimi vision pre-pass the Feishu issue recorder uses
   (issues/issue-vision.py). Non-image attachments are never downloaded —
   the link is kept.

   After each scan, outcome transitions (final state — merged or not — and
   the GitHub conversation count) are recorded into ClickHouse cline.prs by
   tools/pr_outcomes.py, one row per transition, no TTL.

With this running, line scripts and containers never call gh: writes go to
the outbox, reads come from gh-store. gh(1) can then leave the golden image.

Env: GH_BIN overrides the gh binary (tests); GH_RECORDER_DRY_RUN=1 skips all
writes (drain included) and only scans.
"""
import fcntl
import glob
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # repo root (lines/)
sys.path.insert(0, DIR)
from hfv_config import load as _load_hfv  # noqa: E402
from hfv_source import is_gh  # noqa: E402

_HFV = _load_hfv()
GITHUB_REPO = _HFV["GITHUB_REPO"]
FORK_REMOTE = _HFV["FORK_REMOTE"]
PR_BASE = _HFV["PR_BASE"]
PR_LABEL = _HFV["PR_LABEL"]
PR_REVIEWER = _HFV["PR_REVIEWER"]

LINES = os.path.join(DIR, "lines")
ISSUES = os.path.join(DIR, "issues")
STORE = os.path.join(ISSUES, "issues.jsonl")
AUDIT_STATE = os.path.join(ISSUES, "pr-audit.json")
OUTBOX = os.path.join(LINES, "gh-outbox")
GH_STORE = os.path.join(LINES, "gh-store")
FETCHER = os.path.join(DIR, "framework", "pr-comments-fetch.sh")
REPLY = os.path.join(ISSUES, "issue-reply.py")
LOCK = os.path.join(LINES, ".gh-recorder.lock")

GH = os.environ.get("GH_BIN", "gh")
REPO_MAIN = _HFV["RAGFLOW_MAIN"]
DRY_RUN = os.environ.get("GH_RECORDER_DRY_RUN") == "1"
MAX_ATTEMPTS = 5
DONE_RETENTION_S = 7 * 86400    # outbox done/ retention

PR_RE = re.compile(r"https?://github\.com/[^\s\"'<>]+/pull/(\d+)")
IMG_MD_RE = re.compile(r"!\[[^\]]*\]\((https?://[^)\s]+)\)")
IMG_HTML_RE = re.compile(r"<img[^>]+src=[\"'](https?://[^\"'\s]+)[\"']")
IMG_BARE_RE = re.compile(
    r"https?://(?:user-images\.githubusercontent\.com|github\.com/user-attachments)/[^\s)\]\"'<>]+")

# the vision pre-pass lives with the issue recorder — reuse its core
_spec = importlib.util.spec_from_file_location(
    "issue_vision", os.path.join(ISSUES, "issue-vision.py"))
_vision = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_vision)
VISION_CFG = (_vision.load_config()
              if os.path.exists(os.path.join(ISSUES, "config")) else {})


def log(msg):
    print("[%s] gh-recorder: %s" % (time.strftime("%Y%m%d-%H%M%S"), msg), flush=True)


def now_ms():
    return int(time.time() * 1000)


def gh(args, timeout=120):
    """Run gh; returns (rc, stdout). Never raises."""
    try:
        p = subprocess.run([GH] + args, capture_output=True, text=True,
                           timeout=timeout)
        return p.returncode, p.stdout
    except Exception as e:
        log("gh %s: %s" % (" ".join(str(a) for a in args[:3]), e))
        return 127, ""



# ---------------------------------------------------------------- outbox drain

DM = os.path.join(DIR, "tools", "feishu-dm.py")


def _dm_owner(text):
    subprocess.run([sys.executable, DM, "dm-owner", text],
                   capture_output=True, timeout=60)


def _fail_reply(rec):
    if rec.get("dm_owner"):
        _dm_owner("feat 交付失败：分支已推送但 PR 多次创建失败（%s），需人工 gh pr create。"
                  % rec.get("branch", ""))
        return
    mid = rec.get("mid", "")
    txt = ("PR creation failed after retries (automated message): the branch "
           "was pushed but the PR could not be created. See logs."
           if is_gh(mid) else
           "PR 创建多次失败（自动消息）：分支已推送但 PR 未能创建，详见日志。")
    subprocess.run([sys.executable, REPLY, mid, txt],
                   capture_output=True, timeout=60)


def _success_reply(mid, pr_url):
    if is_gh(mid):
        txt = ("Fix proposed in %s — root-cause analysis and fix details are "
               "in the PR description; it closes this issue when merged." % pr_url)
    else:
        txt = "已提交 PR：%s 。根因分析及修复说明详见 PR 描述。" % pr_url
    subprocess.run([sys.executable, REPLY, mid, txt],
                   capture_output=True, timeout=60)


SIGNATURE = ("This reply was generated by "
             "[Hands-Free-Vibe-for-RAGFlow]"
             "(https://github.com/euvre/Hands-Free-Vibe-for-RAGFlow).")


def _do_comment(rec):
    # every public reply carries the pipeline's signature on its first line
    body = rec["body"]
    if not body.startswith(SIGNATURE):
        body = SIGNATURE + "\n\n" + body
    # idempotency key: an invisible marker unique to this outbox record. The
    # execute-then-rename drain is at-least-once — a crash between the POST
    # and the done/ rename replays the record (PR #19823 double-comment on
    # 2026-09-18: power loss after the POST, before the rename). The marker
    # makes such a replay detectable.
    marker = "<!-- hfv-outbox:%s -->" % rec["id"]
    body = body.rstrip("\n") + "\n\n" + marker + "\n"
    # pre-send dedup: if the marker already reached the PR (a previous
    # execution that never got booked), skip the POST and book the record as
    # done. A failed CHECK must never post either — it could mask a live
    # duplicate — so it takes the normal failure path (backoff + retry).
    # Last-100 comments (gh's window) suffice: replays land minutes after
    # the original POST.
    rc, out = gh(["pr", "view", str(rec["pr"]), "--repo", GITHUB_REPO,
                  "--json", "comments", "--jq", ".comments[].body"],
                 timeout=60)
    if rc != 0:
        log("comment %s: dedup pre-check failed (rc=%d) — backing off"
            % (rec["id"], rc))
        return False
    if marker in out:
        log("comment %s: marker already on pr=%s — replay suppressed"
            % (rec["id"], rec["pr"]))
        return True
    body_file = os.path.join(OUTBOX, ".body-%s.md" % rec["id"])
    with open(body_file, "w") as f:
        f.write(body)
    try:
        rc, _ = gh(["pr", "comment", str(rec["pr"]), "--repo", GITHUB_REPO,
                    "--body-file", body_file], timeout=120)
        return rc == 0
    finally:
        os.unlink(body_file)


def _do_label(rec):
    ok = True
    if rec.get("remove"):
        rc, _ = gh(["pr", "edit", str(rec["pr"]), "--repo", GITHUB_REPO,
                    "--remove-label", rec["remove"]])
        ok = ok and rc == 0
    if rec.get("add"):
        rc, _ = gh(["pr", "edit", str(rec["pr"]), "--repo", GITHUB_REPO,
                    "--add-label", rec["add"]])
        ok = ok and rc == 0
    return ok


def _do_pr_create(rec):
    """True/False for retry; on success the feishu reply and the tasks/<id>/
    archive happen here (they were post-deliver's tail before the outbox)."""
    branch, mid = rec["branch"], rec["mid"]
    rc, out = gh(["pr", "list", "--repo", GITHUB_REPO,
                  "--head", "%s:%s" % (FORK_REMOTE, branch),
                  "--json", "url", "--jq", ".[0].url"])
    pr_url = out.strip() if rc == 0 and out.strip().startswith("https://") else ""
    if not pr_url:
        body_file = os.path.join(OUTBOX, ".body-%s.md" % rec["id"])
        with open(body_file, "w") as f:
            f.write(rec["body"])
        try:
            rc, out = gh(["pr", "create", "--repo", GITHUB_REPO,
                          "--base", PR_BASE,
                          "--head", "%s:%s" % (FORK_REMOTE, branch),
                          "--title", rec["title"], "--body-file", body_file],
                         timeout=180)
        finally:
            os.unlink(body_file)
        if rc != 0 or not out.strip().startswith("https://"):
            return False
        pr_url = out.strip()
    num = pr_url.rstrip("/").rsplit("/", 1)[-1]
    # label + reviewers: best-effort, logged (the audit/ci lines also manage
    # the label; GitHub silently drops non-collaborator reviewers)
    reviewers = rec.get("reviewers") or PR_REVIEWER
    rc, _ = gh(["pr", "edit", num, "--repo", GITHUB_REPO,
                "--add-label", PR_LABEL, "--add-reviewer", reviewers])
    log("pr_create %s: pr=%s label/reviewer rc=%d" % (rec["id"], pr_url, rc))
    if rec.get("dm_owner"):
        _dm_owner("feat 任务已交付 PR：%s（分支 %s）。" % (pr_url, branch))
    else:
        _success_reply(mid, pr_url)
    tid = rec.get("task_id") or ""
    if tid:
        tdir = os.path.join(DIR, "tasks", tid)
        os.makedirs(tdir, exist_ok=True)
        with open(os.path.join(tdir, "pr"), "w") as f:
            f.write(pr_url + "\n")
        for name, key in (("pr-title.txt", "title"), ("pr-body.md", "body")):
            with open(os.path.join(tdir, name), "w") as f:
                f.write(rec.get(key, ""))
    log("pr_create %s: delivered %s (mid=%s)" % (rec["id"], pr_url, mid))
    return True


def _is_pool_worktree(wt):
    """Push sources are restricted to line-managed pool worktrees of the main
    clone — never the main root, never an arbitrary path (a prompt-injected
    agent could otherwise enqueue a push of the host's main checkout)."""
    if not wt or not os.path.isdir(wt):
        return False
    real = os.path.realpath(wt)
    pool = os.path.realpath(os.path.join(REPO_MAIN, "wt")) + os.sep
    if not real.startswith(pool):
        return False
    return subprocess.run(["git", "-C", real, "rev-parse", "--git-dir"],
                          capture_output=True).returncode == 0


def _do_push(rec):
    """Returns True=pushed, False=retryable failure, None=terminal (guard
    violation — straight to failed/, no retry)."""
    wt, branch = rec.get("worktree", ""), rec.get("branch", "")
    remote = rec.get("remote") or FORK_REMOTE
    if not _is_pool_worktree(wt):
        log("push %s: worktree %r is not a pool worktree — refused" % (rec["id"], wt))
        return None
    if remote != FORK_REMOTE and remote != os.environ.get("GH_RECORDER_TEST_REMOTE", "\x00"):
        log("push %s: remote %r refused (fork only, never origin)" % (rec["id"], remote))
        return None
    if not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9._/-]*$", branch) or branch == PR_BASE:
        log("push %s: branch %r refused" % (rec["id"], branch))
        return None
    cmd = ["git", "-C", wt, "push"]
    if rec.get("force_with_lease"):
        # plain lease: the worktree's remote-tracking ref is the expectation —
        # the same ref the in-container push would have used
        cmd.append("--force-with-lease")
    cmd += [remote, "HEAD:refs/heads/" + branch]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    except Exception as e:
        log("push %s: %s" % (rec["id"], e))
        return False
    if p.returncode != 0:
        log("push %s: rc=%d %s" % (rec["id"], p.returncode, (p.stderr or "")[-300:]))
        return False
    log("push %s: %s HEAD -> %s/%s done" % (rec["id"], wt, remote, branch))
    return True


def _do_rescan(rec):
    """An agent found its PR's snapshot missing/stale — deep-fetch now,
    regardless of the cheap-poll fingerprint. Read-only; failures retry."""
    num = int(rec["pr"])
    return _deep_fetch(num, _load_snap(num) or {})


def drain_outbox():
    pend = os.path.join(OUTBOX, "pending")
    if not os.path.isdir(pend):
        return
    handlers = {"comment": _do_comment, "label": _do_label,
                "pr_create": _do_pr_create, "push": _do_push,
                "rescan": _do_rescan}
    for path in sorted(glob.glob(os.path.join(pend, "*.json"))):
        try:
            rec = json.load(open(path))
        except Exception:
            continue
        if rec.get("not_before", 0) > now_ms():
            continue
        kind, handler = rec.get("kind"), handlers.get(rec.get("kind"))
        if handler is None:
            os.makedirs(os.path.join(OUTBOX, "failed"), exist_ok=True)
            os.rename(path, os.path.join(OUTBOX, "failed", os.path.basename(path)))
            log("outbox %s: unknown kind — dropped" % rec.get("id"))
            continue
        # dependency: --after <id> — run only once the referenced record is
        # done; a failed dependency cascades the dependent to failed/
        dep = rec.get("after") or ""
        if dep:
            if os.path.exists(os.path.join(OUTBOX, "done", dep + ".json")):
                pass
            elif os.path.exists(os.path.join(OUTBOX, "failed", dep + ".json")):
                os.makedirs(os.path.join(OUTBOX, "failed"), exist_ok=True)
                os.rename(path, os.path.join(OUTBOX, "failed", os.path.basename(path)))
                log("outbox %s: %s dropped — dependency %s failed"
                    % (rec.get("id"), kind, dep))
                continue
            else:
                continue  # dependency still pending — next pass
        if DRY_RUN:
            log("outbox %s: DRY-RUN would execute %s" % (rec.get("id"), kind))
            continue
        ok = False
        try:
            ok = handler(rec)
        except Exception as e:
            log("outbox %s: handler error: %s" % (rec.get("id"), e))
        if ok is None:
            # terminal (guard violation): no retry
            os.makedirs(os.path.join(OUTBOX, "failed"), exist_ok=True)
            os.rename(path, os.path.join(OUTBOX, "failed", os.path.basename(path)))
            log("outbox %s: %s refused by guard — failed/" % (rec.get("id"), kind))
        elif ok:
            os.makedirs(os.path.join(OUTBOX, "done"), exist_ok=True)
            os.rename(path, os.path.join(OUTBOX, "done", os.path.basename(path)))
            log("outbox %s: %s done" % (rec.get("id"), kind))
        else:
            rec["attempts"] = rec.get("attempts", 0) + 1
            if rec["attempts"] >= MAX_ATTEMPTS:
                os.makedirs(os.path.join(OUTBOX, "failed"), exist_ok=True)
                os.rename(path, os.path.join(OUTBOX, "failed", os.path.basename(path)))
                log("outbox %s: %s FAILED after %d attempts"
                    % (rec.get("id"), kind, rec["attempts"]))
                if kind == "pr_create":
                    _fail_reply(rec)
                elif kind == "push":
                    _dm_owner("push 多次失败：worktree %s 的分支 %s 未能推送到 fork"
                              "（详见 gh-recorder 日志）；对应 PR 回复不会发出。"
                              % (rec.get("worktree", "?"), rec.get("branch", "?")))
            else:
                rec["not_before"] = now_ms() + (2 ** rec["attempts"]) * 60 * 1000
                with open(path, "w") as f:
                    json.dump(rec, f, ensure_ascii=False)
                log("outbox %s: %s failed, retry #%d backed off"
                    % (rec.get("id"), kind, rec["attempts"]))


# ------------------------------------------------------------------ PR scan

def tracked_prs():
    """PR numbers worth scanning: every state==done record's PR link (the
    follow store), plus audit-stamped PRs (the audit pre-scan target)."""
    nums = set()
    if os.path.exists(STORE):
        for line in open(STORE):
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("state") != "done":
                continue
            for field in (r.get("text_full") or "", r.get("text") or "",
                          json.dumps(r.get("replies") or [])):
                m = PR_RE.search(field)
                if m:
                    nums.add(int(m.group(1)))
                    break
    try:
        for k in json.load(open(AUDIT_STATE)):
            if str(k).isdigit():
                nums.add(int(k))
    except Exception:
        pass
    return sorted(nums)


def _snap_path(num):
    return os.path.join(GH_STORE, "pr-%d.json" % num)


def _load_snap(num):
    try:
        return json.load(open(_snap_path(num)))
    except Exception:
        return None


def _write_snap(num, data):
    os.makedirs(GH_STORE, exist_ok=True)
    tmp = _snap_path(num) + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.rename(tmp, _snap_path(num))


def _download_image(url, dest_base):
    """Image attachments only. Returns the saved path or None. Content-Type
    must say image/* AND the magic bytes must be a real image (the vision
    pre-pass rejects anything else)."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "hfv-gh-recorder"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            ctype = (resp.headers.get("Content-Type") or "").split(";")[0].strip()
            data = resp.read(20 * 1024 * 1024)
        if not ctype.startswith("image/"):
            return None
        ext = {"image/png": ".png", "image/jpeg": ".jpg",
               "image/gif": ".gif", "image/webp": ".webp"}.get(ctype)
        if not ext:
            return None
        path = dest_base + ext
        with open(path, "wb") as f:
            f.write(data)
        if _vision.probe_media_kind(path) != "image":
            os.unlink(path)
            return None
        return path
    except Exception:
        return None


def _transcribe_image(path):
    desc = os.path.splitext(path)[0] + ".md"
    if os.path.exists(desc) and os.path.getmtime(desc) >= os.path.getmtime(path):
        try:
            return open(desc).read().strip()
        except Exception:
            return ""
    if not VISION_CFG.get("KIMI_API_KEY"):
        return ""
    try:
        text = _vision.transcribe(path, VISION_CFG, "image")
    except Exception as e:
        log("vision %s: %s" % (os.path.basename(path), e))
        return ""
    if text:
        with open(desc, "w") as f:
            f.write(text + "\n")
    return text or ""



def _comment_image_urls(body):
    urls = list(dict.fromkeys(IMG_MD_RE.findall(body or "")))
    for u in IMG_HTML_RE.findall(body or "") + IMG_BARE_RE.findall(body or ""):
        if u not in urls:
            urls.append(u)
    return urls


def _render_comments(num, jsonl_path):
    """Render the complete inventory to pr-<n>-comments.md. Human bodies are
    inlined in full (bot/own bodies capped); image attachments are downloaded
    + transcribed inline. Returns (md_text, gh_shaped_comments, gh_shaped_reviews)."""
    att_dir = os.path.join(GH_STORE, "attachments", "pr-%d" % num)
    os.makedirs(att_dir, exist_ok=True)
    lines = [
        "<!-- gh-recorder snapshot (async scan, 1-min cadence). Complete",
        "     reconciled inventory of all 3 channels; every body is inlined in",
        "     full (only >6000-char walls are capped, with a pointer into the",
        "     sibling pr-<n>-comments.jsonl). Image attachments are transcribed",
        "     inline regardless of author; non-image attachments are never",
        "     downloaded (link kept). 🤖 marks bot/own authors. -->",
        "",
    ]
    comments, reviews = [], []
    entries = []
    for line in open(jsonl_path):
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except Exception:
            pass
    entries.sort(key=lambda e: e.get("created_at") or "")
    own = (_HFV.get("OWN_LOGIN") or "").lower()
    for e in entries:
        ch = e.get("channel", "?")
        author = e.get("author") or "?"
        body = e.get("body") or ""
        is_bot = (own != "" and author.lower() == own) or "[bot]" in author \
            or author.lower() in ("github-actions", "codecov", "coderabbitai",
                                  "copilot-pull-request-reviewer", "claude",
                                  "renovate", "dependabot")
        # gh-shaped copies for pr-follow.py's consumer
        if ch == "issue":
            comments.append({"author": {"login": author}, "body": body,
                             "createdAt": e.get("created_at") or ""})
        elif ch == "review":
            reviews.append({"author": {"login": author},
                            "state": e.get("state") or "",
                            "body": body,
                            "submittedAt": e.get("created_at") or ""})
        # completeness is neutral: bot review comments (coderabbit-style
        # findings) carry real fix hints the review line consumes, so every
        # body is inlined in full up to a generous cap — only genuine walls
        # (codecov tables, stack summaries) exceed it, with a JSONL pointer.
        shown = body
        if len(shown) > 6000:
            shown = shown[:6000] + (
                "\n…(truncated at 6000 chars; full body: "
                "jq -r 'select(.id==%s) | .body' pr-%d-comments.jsonl)"
                % (e.get("id"), num))
        head = "### [%s] #%s @%s%s %s%s%s" % (
            ch, e.get("id"), author, " 🤖" if is_bot else "",
            e.get("created_at") or "",
            "  `%s`" % e.get("state") if e.get("state") else "",
            "  `%s:%s`" % (e.get("path"), e.get("line"))
            if e.get("path") else "")
        lines.append(head)
        lines.append("")
        if shown.strip():
            lines.append(shown)
            lines.append("")
        # every image attachment is transcribed (same rule as the feishu
        # pipeline), regardless of author — bot review comments carry
        # screenshots/diagrams too; non-image attachments are never downloaded
        for i, url in enumerate(_comment_image_urls(body)):
            saved = _download_image(url, os.path.join(
                att_dir, "%s-%d" % (e.get("id"), i)))
            if saved:
                text = _transcribe_image(saved)
                rel = os.path.relpath(saved, DIR)
                lines.append("[图片 %s]" % rel)
                if text:
                    lines.append("> " + text.replace("\n", "\n> "))
                lines.append("")
            else:
                lines.append("[附件(非图片或下载失败，未下载): %s]" % url)
                lines.append("")
    return "\n".join(lines), comments, reviews


def _deep_fetch(num, snap):
    """Refresh the full snapshot for one PR. Comment inventory comes from the
    reconciled fetcher (completeness contract preserved); on its failure the
    previous comments are kept and flagged stale."""
    rc, out = gh(["pr", "view", str(num), "--repo", GITHUB_REPO, "--json",
                  "title,author,body,additions,deletions,changedFiles,"
                  "baseRefName,headRefName,headRefOid,state,isDraft,labels,"
                  "updatedAt,url,mergedAt,closedAt"], timeout=120)
    if rc != 0 or not out.strip():
        log("pr=%d: deep fetch failed" % num)
        return False
    meta = json.loads(out)
    rc, checks_out = gh(["pr", "checks", str(num), "--repo", GITHUB_REPO,
                         "--json", "bucket,name,link"], timeout=60)
    checks = json.loads(checks_out) if rc == 0 and checks_out.strip() else []

    snap.update({
        "num": num, "fetched_at": now_ms(),
        "updated_at": meta.get("updatedAt") or "",
        "state": meta.get("state") or "",
        "is_draft": bool(meta.get("isDraft")),
        "head_ref": meta.get("headRefName") or "",
        "head_oid": meta.get("headRefOid") or "",
        "base_ref": meta.get("baseRefName") or "",
        "title": meta.get("title") or "",
        "author": (meta.get("author") or {}).get("login") or "",
        "body": meta.get("body") or "",
        "additions": meta.get("additions"), "deletions": meta.get("deletions"),
        "changed_files": meta.get("changedFiles"),
        "labels": [l.get("name") for l in meta.get("labels") or []],
        "url": meta.get("url") or "",
        "merged_at": meta.get("mergedAt") or "",
        "closed_at": meta.get("closedAt") or "",
        "checks": checks,
    })

    rc_fetch = subprocess.run(
        ["bash", FETCHER, GITHUB_REPO, str(num)],
        capture_output=True, text=True, timeout=600).returncode
    if rc_fetch == 0:
        snaps = sorted(glob.glob(os.path.join(DIR, "tmp",
                                              "pr-comments-%d-*.jsonl" % num)))
        if snaps:
            md, comments, reviews = _render_comments(num, snaps[-1])
            # the raw JSONL rides along: capped walls (>6000 chars) are
            # pulled in full by id from this stable path
            import shutil
            shutil.copyfile(snaps[-1], os.path.join(
                GH_STORE, "pr-%d-comments.jsonl" % num))
            md_path = os.path.join(GH_STORE, "pr-%d-comments.md" % num)
            tmp = md_path + ".tmp"
            with open(tmp, "w") as f:
                f.write(md)
            os.rename(tmp, md_path)
            snap["comments"] = comments
            snap["reviews"] = reviews
            snap["comments_fetched_at"] = now_ms()
            snap["comments_stale"] = False
    else:
        snap["comments_stale"] = True
        log("pr=%d: comment fetch incomplete — kept previous inventory" % num)
    _write_snap(num, snap)
    log("pr=%d: snapshot refreshed (state=%s oid=%s)"
        % (num, snap.get("state"), (snap.get("head_oid") or "")[:10]))
    return True



def scan_prs():
    for num in tracked_prs():
        rc, out = gh(["pr", "view", str(num), "--repo", GITHUB_REPO,
                      "--json", "updatedAt,state,headRefOid"], timeout=60)
        if rc != 0 or not out.strip():
            continue
        try:
            cur = json.loads(out)
        except Exception:
            continue
        snap = _load_snap(num) or {}
        changed = (
            snap.get("updated_at") != (cur.get("updatedAt") or "")
            or snap.get("head_oid") != (cur.get("headRefOid") or "")
            or snap.get("state") != (cur.get("state") or ""))
        if changed:
            _deep_fetch(num, snap)


def gc():
    """done/ outbox files older than the retention window; snapshots of PRs
    that left the tracked set (pruned from issues.jsonl) are dropped."""
    cutoff = time.time() - DONE_RETENTION_S
    for path in glob.glob(os.path.join(OUTBOX, "done", "*.json")):
        try:
            if os.path.getmtime(path) < cutoff:
                os.unlink(path)
        except Exception:
            pass
    tracked = set(tracked_prs())
    for path in glob.glob(os.path.join(GH_STORE, "pr-*.json")):
        m = re.search(r"pr-(\d+)\.json$", path)
        if m and int(m.group(1)) not in tracked \
                and os.path.getmtime(path) < time.time() - 86400:
            num = int(m.group(1))
            for p in glob.glob(os.path.join(GH_STORE, "pr-%d*" % num)):
                if os.path.isfile(p):
                    os.unlink(p)
            att = os.path.join(GH_STORE, "attachments", "pr-%d" % num)
            if os.path.isdir(att):
                import shutil
                shutil.rmtree(att, ignore_errors=True)
            log("gc: dropped snapshot for untracked pr=%d" % num)


def main():
    os.makedirs(GH_STORE, exist_ok=True)
    # the outbox is written by in-container agents (different uid) and drained
    # here — make the queue world-writable whoever created it first
    for sub in ("pending", "done", "failed"):
        p = os.path.join(OUTBOX, sub)
        os.makedirs(p, exist_ok=True)
        try:
            os.chmod(p, 0o777)
        except OSError:
            pass
    fd = os.open(LOCK, os.O_CREAT | os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0  # a previous pass is still running — skip this tick
    if os.environ.get("GH_RECORDER_NO_DRAIN") != "1":
        drain_outbox()
    if os.environ.get("GH_RECORDER_NO_SCAN") != "1":
        scan_prs()
        # record outcome transitions (merged? / conversation counts) into
        # ClickHouse from the just-refreshed local snapshots; never crashes
        # the pass (the tool itself swallows CH outages, belt + braces here)
        if not DRY_RUN:
            try:
                env = dict(os.environ, PR_OUTCOMES_FROM_RECORDER="1")
                rc = subprocess.run(
                    [sys.executable, os.path.join(DIR, "tools", "pr_outcomes.py")],
                    capture_output=True, text=True, timeout=120, env=env)
                if rc.returncode != 0:
                    log("pr_outcomes failed: %s" % (rc.stderr or "").strip()[:200])
                elif rc.stdout.strip():
                    log(rc.stdout.strip())
            except Exception as e:
                log("pr_outcomes pass error: %s" % e)
    gc()
    return 0


if __name__ == "__main__":
    sys.exit(main())

