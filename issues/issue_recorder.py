#!/usr/bin/env python3
# issue_recorder.py — incrementally record NEW root messages (post/text) from
# the configured Feishu group into issues.jsonl. Does exactly one thing: append
# items not already in the store. Pruning and marking live elsewhere.
#
# Incremental strategy: fetch only messages after the newest create_time
# already in the store (first run: now - WINDOW_DAYS).
import fcntl
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

DIR = os.path.dirname(os.path.abspath(__file__))
STORE = os.path.join(DIR, "issues.jsonl")
sys.path.insert(0, os.path.dirname(DIR))
from hfv_config import load as _load_hfv  # noqa: E402
from hfv_source import is_gh  # noqa: E402
_HFV = _load_hfv()
# Shared whole-store lock: pr-follow.py (PR line) writes the SAME file via
# save_flips. Without a common lock, this process's load→(feishu/gh calls,
# ~30s)→full-rewrite could clobber pr-follow stamps landed in between
# (comment_check_at / dm_* / pr_flag flips) — same lost-update family as the
# only its save_flips critical section, we lock the whole main() run.
STORE_LOCK = os.path.join(DIR, ".store.lock")


def _store_locked(fn):
    with open(STORE_LOCK, "w") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            return fn()
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)
ATTACH_DIR = os.path.join(DIR, "attachments")
CURSOR = os.path.join(DIR, ".cursor")
CONFIG = os.path.join(DIR, "config")
BASE = os.environ.get("FEISHU_BASE_URL", "https://open.feishu.cn/open-apis")
PR_RE = re.compile(r"https?://github\.com/[^\s\"'<>]+/pull/\d+")

# Canonical claim template — single source of truth (pre-claim.sh sends the
# same text as a fallback when a record was claimed before this module owned
# claiming; keep the two in sync when editing).
_SELF_UID = _HFV.get("SELF_FEISHU_USER_ID", "")
CLAIM_TEXT = ((f'<at user_id="{_SELF_UID}"></at> ' if _SELF_UID else "")
              + "当前任务已被认领。如果你想要认领该任务，@自己即可。后续自动化任务会放弃该任务。"
              "如果你的回复不是为了认领该pr，不要使用@。")
CLAIM_MARK = "当前任务已被认领"
ABANDON_TEXT = "我现在放弃该任务。"


def load_cursor():
    try:
        return int(open(CURSOR).read().strip())
    except Exception:
        return 0


def save_cursor(value):
    if value > load_cursor():
        with open(CURSOR, "w") as f:
            f.write(str(value))


def load_config():
    cfg = {}
    for line in open(CONFIG):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    return cfg


def http(method, url, token=None, body=None):
    req = urllib.request.Request(url, method=method)
    req.add_header("Content-Type", "application/json; charset=utf-8")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(req, data=data, timeout=15) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read())
        except Exception:
            return None
    except Exception:
        return None


def tenant_token(cfg):
    r = http("POST", f"{BASE}/auth/v3/tenant_access_token/internal",
             body={"app_id": cfg["APP_ID"], "app_secret": cfg["APP_SECRET"]})
    return r["tenant_access_token"]


def fetch_message(mid, token):
    """Return the live message dict, the string "gone" (recalled / deleted /
    not found), or "unknown" (transient failure — never treated as gone)."""
    try:
        d = http("GET", f"{BASE}/im/v1/messages/{mid}", token=token)
    except Exception:
        return "unknown"
    if d.get("code") not in (None, 0):
        msg = str(d.get("msg", "")).lower()
        if "not exist" in msg or "not_found" in msg:
            return "gone"
        return "unknown"
    try:
        live = d["data"]["items"]
        if not live:
            return "gone"
        body = live[0].get("body", {}).get("content", "")
    except Exception:
        return "unknown"
    if "This message was recalled" in body:
        return "gone"
    return live[0]


def recall_message(mid_reply, token):
    """Recall a Feishu message by message_id. Best-effort, never raises."""
    if not mid_reply or not token:
        return
    url = f"{BASE}/im/v1/messages/{mid_reply}"
    req = urllib.request.Request(url, method="DELETE")
    req.add_header("Authorization", f"Bearer {token}")
    try:
        urllib.request.urlopen(req, timeout=15).read()
    except Exception:
        pass


def send_reply(mid, text, token):
    """Post a text reply into the thread of `mid`. Best-effort: returns the
    created message_id on success, None on any failure (never raises)."""
    if not mid or not token:
        return None
    body = {
        "msg_type": "text",
        "content": json.dumps({"text": text}, ensure_ascii=False),
    }
    d = http("POST", BASE + "/im/v1/messages/" + mid + "/reply", token=token, body=body)
    if not d or d.get("code") != 0:
        return None
    return (d.get("data") or {}).get("message_id")


def resolve_live_claim_id(rec, token):
    """Recover the id of our already-sent claim reply from the live thread
    (read-only). Used when the record provably has our claim (snapshot) but
    its id was never persisted. Best-effort: '' on any failure."""
    if not token:
        return ""
    tid = rec.get("thread_id", "")
    mid = rec.get("message_id", "")
    if not tid:
        return ""
    page = ""
    while True:
        url = (BASE + "/im/v1/messages?container_id_type=thread&container_id="
               + tid + "&page_size=50")
        if page:
            url += "&page_token=" + page
        data = (http("GET", url, token=token) or {}).get("data") or {}
        for it in data.get("items") or []:
            if it.get("deleted") or it.get("message_id") == mid:
                continue
            if it.get("sender", {}).get("sender_type") != "app":
                continue
            try:
                body = json.loads(it["body"]["content"]).get("text", "")
            except Exception:
                body = it.get("body", {}).get("content", "")
            if CLAIM_MARK in body:
                return it.get("message_id", "")
        if data.get("has_more") and data.get("page_token"):
            page = data["page_token"]
        else:
            return ""


def ensure_claim(r, token):
    """Idempotently claim an issue RIGHT AT SCAN TIME and persist the reply id
    into the store record (caller saves the store). Order:
      1. already claimed (claim_reply_id present) -> reuse
      2. snapshot proves a claim but the id is missing -> recover from the
         live thread; unrecoverable -> give up sending (never duplicate)
      3. never claimed -> send now, persist the id
    Returns the claim reply id or ''."""
    if not token or not isinstance(r, dict):
        return r.get("claim_reply_id") or "" if isinstance(r, dict) else ""
    existing = r.get("claim_reply_id") or ""
    if existing:
        return existing
    snapshot_claim = any(
        rp.get("sender_type") == "app" and CLAIM_MARK in (rp.get("text") or "")
        for rp in (r.get("replies") or [])
    )
    if snapshot_claim:
        existing = resolve_live_claim_id(r, token)
        if not existing:
            return ""  # proven claimed but id unrecoverable: never re-send
    if not existing:
        existing = send_reply(r.get("message_id", ""), CLAIM_TEXT, token) or ""
    if existing:
        r["claim_reply_id"] = existing
    return existing


def drop_record(items, mid, token=None, recall_claim_reply=True):
    """Remove a record and its attachment dir from the store. Unless
    `recall_claim_reply` is False, a record carrying a claim_reply_id (sent by
    pre-claim.sh) gets that reply recalled first so the thread no longer shows
    a stale claim by our bot. The third-party-takeover (abandon) path passes
    False: the claim stays visible as handover history — the abandon reply
    announces the step-aside instead."""
    r = items.get(mid, {})
    claim_reply = r.get("claim_reply_id") if isinstance(r, dict) else None
    if recall_claim_reply and claim_reply and token:
        recall_message(claim_reply, token)
    items.pop(mid, None)
    adir = os.path.join(ATTACH_DIR, mid)
    if os.path.isdir(adir):
        shutil.rmtree(adir, ignore_errors=True)


def load_store():
    items = {}
    if os.path.exists(STORE):
        for line in open(STORE):
            line = line.strip()
            if line:
                try:
                    r = json.loads(line)
                    items[r["message_id"]] = r
                except Exception:
                    pass
    return items


def extract_text(msg):
    try:
        content = json.loads(msg["body"]["content"])
    except Exception:
        return ""
    if "text" in content:
        return content["text"]
    parts = []
    for para in content.get("content", []):
        for seg in para:
            if seg.get("tag") == "text":
                parts.append(seg.get("text", ""))
    return "".join(parts)


def extract_content(msg):
    """Return (full_text, [(kind, key, name)]) from a post/text message body.
    kind: "image" or "file". File segments carry the original file_name."""
    full_text = extract_text(msg)
    resources = []
    try:
        content = json.loads(msg["body"]["content"])
    except Exception:
        content = {}
    for para in content.get("content", []):
        for seg in para:
            if seg.get("tag") == "img" and seg.get("image_key"):
                resources.append(("image", seg["image_key"], None))
            elif seg.get("tag") == "media" and seg.get("file_key"):
                resources.append(("file", seg["file_key"], seg.get("file_name", "")))
    return full_text, resources


VIDEO_EXTS = {".mp4", ".m4v", ".mov", ".mkv", ".webm", ".avi"}


def sniff_file_ext(data):
    """Best-effort extension for a downloaded file resource that did not
    carry its original name (Feishu media/video segments have none). Videos
    get their real extension; only genuinely-PNG/JPEG bytes keep image
    extensions — an MP4 saved as .png poisons the vision pre-pass."""
    if data[:4] == b"\x89PNG":
        return ".png"
    if data[:2] == b"\xff\xd8":
        return ".jpg"
    if data[4:8] == b"ftyp":
        return ".mp4"
    if data[:4] == b"\x1a\x45\xdf\xa3":
        return ".webm"
    if data[:4] == b"%PDF":
        return ".pdf"
    return ""


def download_resource(message_id, kind, key, token, name, file_name):
    """Download one message resource into attachments/<message_id>/.
    kind "image" -> type=image, .jpg/.png by magic bytes;
    kind "file"  -> type=file, keeps the original file_name (sanitized).
    Returns (relpath, effective_kind); effective_kind upgrades "file" to
    "video" when the resource is a video (by file_name or container sniff) so
    callers can route it through the image pipeline (kimi transcription).
    Best-effort: returns (None, kind) on failure, never blocks recording."""
    url = (f"{BASE}/im/v1/messages/{message_id}/resources/{key}"
           f"?type={'image' if kind == 'image' else 'file'}")
    req = urllib.request.Request(url, method="GET")
    req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = resp.read()
    except Exception:
        return None, kind
    if not data or data[:1] == b"{":  # JSON error body instead of file bytes
        return None, kind
    effective = kind
    if kind == "file":
        named_ext = os.path.splitext(file_name or "")[1].lower()
        if named_ext in VIDEO_EXTS or sniff_file_ext(data) in (".mp4", ".webm"):
            effective = "video"
    if kind == "file" and file_name:
        safe = "".join(c for c in file_name if c not in "/\\\0")[:120] or "file"
        fname = safe if safe.startswith(f"{name}_") or name == "" else f"{name}_{safe}"
    elif kind == "file":
        # A file resource without its original name is usually a media
        # segment (video): sniff the container instead of assuming an image
        # extension.
        fname = f"{name}{sniff_file_ext(data)}"
    else:
        ext = ".jpg" if data[:2] == b"\xff\xd8" else ".png"
        fname = f"{name}{ext}"
    adir = os.path.join(ATTACH_DIR, message_id)
    os.makedirs(adir, exist_ok=True)
    path = os.path.join(adir, fname)
    with open(path, "wb") as f:
        f.write(data)
    return os.path.relpath(path, DIR), effective


def _reuse_reply_file(adir, base):
    """Return (relpath, kind) of an already-downloaded reply file for this
    base name (any non-.md extension), or (None, None)."""
    for p in glob.glob(os.path.join(adir, base + ".*")):
        if p.endswith(".md"):
            continue
        ext = os.path.splitext(p)[1].lower()
        kind = ("video" if ext in VIDEO_EXTS
                else "image" if ext in (".jpg", ".png") else "file")
        return os.path.relpath(p, DIR), kind
    return None, None


def materialize_reply_resources(message_id, replies, token):
    """Download images/files carried by replies into attachments/<message_id>/
    and set each reply's local `images`/`files` paths. Runs on EVERY refresh
    pass for every open record, so files materialized on an earlier pass are
    reused instead of re-downloaded — a re-download refreshes the file mtime
    and would force the vision pre-pass to re-transcribe the same reply media
    every tick. Best-effort per item."""
    adir = os.path.join(ATTACH_DIR, message_id)
    for seq, reply in enumerate(replies, 1):
        saved_img, saved_file = [], []
        for idx, (kind, key, fname) in enumerate(reply.pop("resources", []), 1):
            base = f"reply_{seq:02d}" if idx == 1 else f"reply_{seq:02d}_{idx}"
            existing, existing_kind = _reuse_reply_file(adir, base)
            if existing:
                # videos ride the image pipeline (kimi transcription)
                (saved_img if existing_kind in ("image", "video")
                 else saved_file).append(existing)
                continue
            if kind == "image":
                p, _ = download_resource(message_id, "image", key, token, base, None)
                if p:
                    saved_img.append(p)
            else:
                p, eff = download_resource(message_id, "file", key, token, base, fname)
                if p:
                    # videos ride the image pipeline (kimi transcription)
                    (saved_img if eff == "video" else saved_file).append(p)
        if saved_img:
            reply["images"] = saved_img
        if saved_file:
            reply["files"] = saved_file


def thread_scan(msg, token):
    """Fetch the thread once; return (third_handled, own_pr, own_claim, replies).
    Replies are split by sender: this app's own replies (sender_type == "app",
    sent by issue-reply.py) vs everyone else's.
      third_handled: someone else claimed (@mention) or posted a GitHub PR —
        a human is handling it; callers drop the record entirely.
      own_pr: latest PR link posted by our own replies (None if absent).
      own_claim: our app claimed the thread (@mention) with no PR yet.
    replies: structured snapshot of the thread replies (root excluded).
    The root message itself is excluded (reporters often @ a human reviewer)."""
    tid = msg.get("thread_id", "")
    mid = msg.get("message_id", "")
    if not tid:
        return False, None, False, []
    third_handled = own_claim = False
    own_pr = None
    replies = []
    page_token = ""
    while True:
        url = f"{BASE}/im/v1/messages?container_id_type=thread&container_id={tid}&page_size=50"
        if page_token:
            url += f"&page_token={page_token}"
        r = http("GET", url, token=token)
        data = r.get("data", {})
        for it in data.get("items", []):
            if it.get("message_id") == mid or it.get("deleted"):
                continue
            body = ""
            try:
                body = it["body"]["content"]
            except Exception:
                pass
            if "This message was recalled" in body:
                continue
            # Takeover semantics per our claim reply's own protocol
            # ("@自己即可"): a claim is a user @-ing THEMSELVES. Humans @-ing
            # each other to discuss the issue (the normal case) must NOT count
            # as a takeover — the old any-mention test dropped delivered
            # tasks' records and posted bogus "我现在放弃该任务。" notes.
            sender = it.get("sender", {})
            sid = sender.get("id", "")
            mention = bool(it.get("mentions")) or "<at " in body
            self_claim = bool(sid) and any(
                m.get("id") == sid for m in it.get("mentions") or [])
            m = PR_RE.search(body)
            pr_link = m.group(0) if m else None
            if sender.get("sender_type") == "app":
                if pr_link:
                    own_pr = pr_link  # later replies win
                if mention:
                    own_claim = True
            elif self_claim or pr_link:
                third_handled = True
            rtext = extract_text(it).strip()
            _, rres = extract_content(it)
            if not rtext and rres:
                kinds = {(k) for k, _, _ in rres}
                rtext = "[图片]" if kinds == {"image"} else "[附件]" if kinds == {"file"} else "[图片+附件]"
            if (rtext or rres) and len(replies) < 20:
                replies.append({
                    "create_time": int(it.get("create_time", 0)),
                    "sender_id": it.get("sender", {}).get("id", ""),
                    "sender_type": it.get("sender", {}).get("sender_type", ""),
                    "text": rtext.replace("\n", " ")[:400],
                    "resources": rres,
                })
        if data.get("has_more") and data.get("page_token"):
            page_token = data["page_token"]
        else:
            break
    return third_handled, own_pr, own_claim, replies


BOT_LOGINS_PR = {
    "github-actions", "codecov", "renovate", "dependabot",
    "copilot-pull-request-reviewer", "coderabbitai", "claude",
}
PR_URL_RE = re.compile(r"https?://github\.com/[^\s\"'<>]+/pull/(\d+)")


def _pr_author_bot(author):
    login = ((author or {}).get("login") or "").lower()
    return login in BOT_LOGINS_PR or login.endswith("bot") or login.endswith("[bot]")


def _pr_author_own(author):
    return (((author or {}).get("login") or "").lower() == _HFV["OWN_LOGIN"])


def _iso_ms(s):
    if not s:
        return 0
    try:
        import datetime
        dt = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return int(dt.timestamp() * 1000)
    except Exception:
        return 0


def _gh_overview(num):
    """gh pr view → dict or None. comments+reviews for the pr_flag machine."""
    try:
        p = subprocess.run(
            ["gh", "pr", "view", str(num), "--repo", _HFV["GITHUB_REPO"],
             "--json", "state,headRefName,comments,reviews"],
            capture_output=True, text=True, timeout=30)
        if p.returncode != 0 or not p.stdout.strip():
            return None
        return json.loads(p.stdout)
    except Exception:
        return None


def _human_latest_ms(ov):
    """Newest HUMAN activity ms. coderabbitai is in BOT_LOGINS_PR, so
    coderabbit and our own replies never drive pr_flag."""
    times = []
    for c in ov.get("comments") or []:
        if not _pr_author_bot(c.get("author")) and not _pr_author_own(c.get("author")):
            times.append(_iso_ms(c.get("createdAt")))
    for rv in ov.get("reviews") or []:
        if not _pr_author_bot(rv.get("author")) and not _pr_author_own(rv.get("author")):
            times.append(_iso_ms(rv.get("submittedAt")))
    return max(times) if times else 0


def maintain_pr_flags(items, now_ms):
    """pr_flag state machine, recorder-owned transitions:
      new → fresh        first HUMAN comment on a done+PR record
      *   → fresh        any NEW human activity
    Snapshot kept in `pr_comments` ({"latest_human_ms":..,"checked_at":..})
    — a dedicated area mirroring the `replies` pattern. Terminal for the
    review line; it owns (new|fresh)→done.
    """
    moved = 0
    new_urls = []
    for mid, r in items.items():
        if r.get("state") != "done":
            continue
        m = PR_URL_RE.search(r.get("pr") or "")
        if not m:
            continue
        ov = _gh_overview(int(m.group(1)))
        if ov is None:
            continue
        gh = (ov.get("state") or "").upper()
        if gh == "MERGED":
            r["state"] = "merged"; r["merged_time"] = now_ms; moved += 1
            continue
        if gh == "CLOSED":
            r["state"] = "closed"; r["closed_time"] = now_ms; moved += 1
            continue
        latest = _human_latest_ms(ov)
        # with no dm_new_at means this PR just entered the list → tell the merge owner
        # to assign reviewers / review. Existing records were backfilled, so
        # only genuinely new submissions ever fire.
        if not r.get("dm_new_at"):
            new_urls.append((mid, r["pr"]))
        snap = r.get("pr_comments") or {}
        prev = snap.get("latest_human_ms") or 0
        if latest > prev:
            cur = r.get("pr_flag") or "new"
            r["pr_flag"] = "fresh"
            r["dm_done_at"] = 0  # re-arm: new human comment starts a new done-cycle
            moved += 1
            print("pr_flag: %s %s -> fresh (new human comment)" % (mid, cur))
        r["pr_comments"] = {"latest_human_ms": max(latest, prev), "checked_at": now_ms}
    if new_urls:
        msg = "以下新 PR 已提交，请及时分配 reviewer 或进行 review：" + "\n" + "\n".join(
            u for _, u in new_urls)
        rc = subprocess.run(
            ["python3", os.path.join(os.path.dirname(DIR), "tools", "feishu-dm.py"),
             "dm-owner", msg],
            capture_output=True, text=True)
        for line in (rc.stdout + rc.stderr).splitlines():
            print("new-pr notice: %s" % line)
        if rc.returncode == 0:
            for mid, _ in new_urls:
                items[mid]["dm_new_at"] = now_ms
            print("new-pr notice: %d PR(s) reported to the merge owner" % len(new_urls))
        else:
            print("new-pr notice: DM failed rc=%d (will retry next pass)" % rc.returncode)
    if moved:
        print("pr_flag maintenance: %d record(s) touched" % moved)


def main():
    cfg = load_config()
    window_ms = int(cfg.get("WINDOW_DAYS", "7")) * 86400 * 1000
    chat_id = cfg["CHAT_ID"]
    token = tenant_token(cfg)

    items = load_store()
    now_ms = int(time.time() * 1000)

    # refresh every non-done record against the live message + thread:
    #   root gone (recalled/deleted/not found) → drop the record entirely
    #   a third party claimed (@) or posted a PR → drop the record (not ours)
    #     and reply "我现在放弃该任务。" in the thread (our claim reply stays
    #     visible as handover history; it is NOT recalled)
    #   our own PR reply → done (+pr)
    #   otherwise → update text, resources and reply snapshots; the record
    #     STAYS open (a claim without a PR means the run is in flight or has
    #     failed — it must remain retryable)
    # merged/closed/abandoned (terminal states set by pr-follow.sh / task
    # abandon) are terminal here too, as is "fail" (retry cap exhausted in
    # issue-select.sh) — never re-classified back into done/open.
    refreshed = flipped = dropped = removed = 0
    for mid, r in list(items.items()):
        if r.get("state") in ("done", "merged", "closed", "abandoned", "fail"):
            continue
        if is_gh(mid):
            # GitHub-sourced records have no Feishu message to refresh: the
            # fetch below 404s on them and drop_record would remove them as
            # "gone". Their lifecycle is owned by issue-sync.sh
            # (gh_classify) and issue-select.sh — skip them here.
            continue
        msg = fetch_message(mid, token)
        if msg == "gone":
            drop_record(items, mid, token)
            removed += 1
            continue
        third, own_pr, own_claim, replies = thread_scan({"thread_id": r.get("thread_id", ""), "message_id": mid}, token)
        # A takeover only counts BEFORE our start notice: once the run was
        # announced ("@将不再生效"), a later @-claim must not interrupt the
        # in-flight run — the record settles via the run's own outcome.
        if third and not r.get("start_notice_id"):
            # A human took over: state publicly that we step aside, then drop
            # the record. Our claim reply STAYS in the thread (handover
            # history); only the gone path recalls it.
            if not send_reply(mid, ABANDON_TEXT, token):
                print(f"abandon-reply failed for {mid} (best-effort, dropped anyway)")
            drop_record(items, mid, token, recall_claim_reply=False)
            dropped += 1
            continue
        # refresh root content: text always; attachments only when their keys
        # changed (edited message), re-downloading into a clean dir
        if msg != "unknown":
            full_text, resources = extract_content(msg)
            keys = [k for _, k, _ in resources]
            if keys != (r.get("resource_keys") or []):
                adir = os.path.join(ATTACH_DIR, mid)
                if os.path.isdir(adir):
                    shutil.rmtree(adir, ignore_errors=True)
                images, files = [], []
                for idx, (kind, key, fname) in enumerate(resources, 1):
                    base = f"img_{idx:02d}" if kind == "image" else f"file_{idx:02d}"
                    p, eff = download_resource(mid, kind, key, token, base, fname)
                    if p:
                        # videos ride the image pipeline (kimi transcription)
                        (images if eff in ("image", "video") else files).append(p)
                r["resource_keys"] = keys
                r["images"] = images
                r["files"] = files
            r["text"] = full_text.replace("\n", " ")[:120]
            r["text_full"] = full_text[:2000]
        materialize_reply_resources(mid, replies, token)
        r["replies"] = replies
        if own_pr:
            r["state"] = "done"
            r["done_time"] = now_ms
            r["pr"] = own_pr
            flipped += 1
        else:
            # claimed-but-undelivered (in-flight or failed run) stays open
            r["state"] = "open"
            r.pop("note", None)
            r.pop("done_time", None)
        refreshed += 1
    if refreshed or flipped or dropped or removed:
        print(f"refreshed={refreshed} flipped={flipped} dropped_third={dropped} removed_gone={removed}")

    cursor = load_cursor()
    if cursor:
        newest = max([r["create_time"] for r in items.values()] + [cursor])
        start_ms = newest + 1
    else:
        # Cursor absent (never started, or `hfv rec reset`): full
        # sliding-window rescan. Store records do NOT anchor the window here —
        # otherwise records older than the newest one could never be restored
        # after a manual wipe; message_id dedup keeps them from duplicating.
        start_ms = now_ms - window_ms

    added = 0
    skipped = 0
    seen_max = start_ms
    page_token = ""
    while start_ms < now_ms:
        url = (f"{BASE}/im/v1/messages?container_id_type=chat&container_id={chat_id}"
               f"&start_time={start_ms // 1000}&sort_type=ByCreateTimeAsc&page_size=50")
        if page_token:
            url += f"&page_token={page_token}"
        r = http("GET", url, token=token)
        data = r.get("data", {})
        for msg in data.get("items", []):
            ct = int(msg.get("create_time", 0))
            if ct > seen_max:
                seen_max = ct
            mid = msg.get("message_id", "")
            if not mid or mid in items:
                continue
            if msg.get("msg_type") not in ("post", "text"):
                continue
            if msg.get("deleted"):
                continue
            if msg.get("parent_id") or msg.get("root_id"):
                continue  # only root messages (thread starters)
            text = extract_text(msg).strip()
            if not text or text == "This message was recalled":
                continue
            third, own_pr, own_claim, replies = thread_scan(msg, token)
            if third or own_pr or own_claim:
                skipped += 1
                continue
            full_text, resources = extract_content(msg)
            images, files = [], []
            for idx, (kind, key, fname) in enumerate(resources, 1):
                base = f"img_{idx:02d}" if kind == "image" else f"file_{idx:02d}"
                p, eff = download_resource(mid, kind, key, token, base, fname)
                if p:
                    # videos ride the image pipeline (kimi transcription)
                    (images if eff in ("image", "video") else files).append(p)
            materialize_reply_resources(mid, replies, token)
            items[mid] = {
                "message_id": mid,
                "thread_id": msg.get("thread_id", ""),
                "create_time": int(msg.get("create_time", 0)),
                "text": text.replace("\n", " ")[:120],
                "text_full": full_text[:2000],
                "images": images,
                "files": files,
                "resource_keys": [k for _, k, _ in resources],
                "replies": replies,
                "sender_id": msg.get("sender", {}).get("id", ""),
                "state": "open",
                "recorded_at": now_ms,
            }
            added += 1
            # Claim IMMEDIATELY at scan time: the thread was verified clean
            # seconds ago inside this same loop, so claiming here keeps the
            # race window (a third party @-ing between our scan and our claim)
            # as small as it can possibly be. Idempotent; the reply id is
            # persisted with the store save below (pre-claim.sh at tick time
            # then becomes a no-op fallback).
            try:
                cid = ensure_claim(items[mid], token)
                print("claimed-at-scan %s reply=%s" % (mid, cid or "FAILED"))
            except Exception as e:
                print("claim-at-scan %s failed: %s" % (mid, e))
        if data.get("has_more") and data.get("page_token"):
            page_token = data["page_token"]
        else:
            break

    maintain_pr_flags(items, now_ms)

    tmp = STORE + ".tmp"
    with open(tmp, "w") as f:
        for r in sorted(items.values(), key=lambda x: x["create_time"]):
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(tmp, STORE)
    save_cursor(seen_max)
    print(f"added={added} skipped_closed={skipped} total={len(items)}")


if __name__ == "__main__":
    sys.exit(_store_locked(main))
