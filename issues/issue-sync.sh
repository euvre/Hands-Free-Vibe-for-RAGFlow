#!/usr/bin/env bash
# issue-sync.sh — post-run issue-state sync (rule-based, no LLM). For every
# non-done record, read the live Feishu thread and settle it, splitting
# replies by sender (this app's own replies vs everyone else's):
#   a THIRD PARTY claimed (@mention) or posted a PR → drop the record
#     (a human is handling it; attachments removed too) and reply
#     "我现在放弃该任务。" in the thread
#   our own reply carries a GitHub PR link → done (+pr link, terminal)
#   a claim without a PR yet → stays open (in-flight or failed run: retryable)
#   root message recalled / gone            → drop the record entirely
#   otherwise                               → stays open
# merged/closed (PR terminal states set by pr-follow.sh) are terminal here
# too — never re-classified back into done/open. So is "fail" (retry cap
# exhausted in issue-select.sh) and "abandoned" (hfv task abandon).
# The recorder refresh applies the same rules between runs; this pass settles
# states right after each task finishes. Pruning owns eventual removal.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="/home/inf/hands-free-vibe/logs"

mkdir -p "$LOG_DIR"
{
  echo "[$(date +%Y%m%d-%H%M%S)] issue-sync pass start"
  python3 - "$DIR" <<'PYEOF'
import fcntl, json, os, re, shutil, sys, time, urllib.error, urllib.request

base_dir = sys.argv[1]
sys.path.insert(0, os.path.dirname(base_dir))  # repo root
from hfv_source import is_gh
store = os.path.join(base_dir, "issues.jsonl")
# Shared store lock (see issue_recorder.py STORE_LOCK).
_lock = open(os.path.join(base_dir, ".store.lock"), "w")
fcntl.flock(_lock, fcntl.LOCK_EX)
cfg = {}
for line in open(os.path.join(base_dir, "config")):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        cfg[k.strip()] = v.strip()
BASE = os.environ.get("FEISHU_BASE_URL", "https://open.feishu.cn/open-apis")
PR_RE = re.compile(r"https?://github\.com/[^\s\"'<>]+/pull/\d+")

# ---- GitHub issue source (source=github, message_id=gh-<number>) ----------
GH_BIN = os.environ.get("GH_BIN", "gh")
GH_REPO = cfg.get("GITHUB_ISSUE_REPO", "infiniflow/ragflow")
# issues/config calls it GITHUB_LOGIN, hfv.conf calls it OWN_LOGIN — accept both;
# an empty value here silently disables gh done-detection (own-PR-comment never matches).
OWN_LOGIN = cfg.get("OWN_LOGIN") or cfg.get("GITHUB_LOGIN", "")


def gh_view_issue(num):
    import subprocess
    try:
        out = subprocess.run(
            [GH_BIN, "issue", "view", str(num), "--repo", GH_REPO, "--json",
             "state,assignees,comments"],
            capture_output=True, text=True, timeout=30)
    except Exception:
        return None
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout)
    except Exception:
        return None


def gh_note(num, text):
    """Best-effort comment (step-aside note). Never raises."""
    import subprocess
    try:
        subprocess.run([GH_BIN, "issue", "comment", str(num), "--repo", GH_REPO,
                        "--body", text], capture_output=True, timeout=30)
    except Exception:
        pass


def http(method, url, token=None, body=None):
    req = urllib.request.Request(url, method=method)
    req.add_header("Content-Type", "application/json; charset=utf-8")
    if token:
        req.add_header("Authorization", "Bearer " + token)
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


def main():
    if not os.path.exists(store):
        return
    records = []
    for line in open(store):
        line = line.strip()
        if line:
            try:
                records.append(json.loads(line))
            except Exception:
                pass
    targets = [r for r in records if r.get("state") not in ("done", "merged", "closed", "abandoned", "fail")]
    # Slot source affinity: each line settles only records of its own
    # source(s) (ISSUE_SOURCES[_<slot>]); others are left untouched for the
    # line that owns them. Syncing is per-record maintenance, so a line with
    # no matching source simply has nothing to do.
    _slot = os.environ.get("HFV_SLOT") or "host"
    _raw = cfg.get("ISSUE_SOURCES_" + _slot,
                   cfg.get("ISSUE_SOURCES", "feishu github"))
    _allowed = set(_raw.split())
    targets = [r for r in targets
               if (r.get("source") or "feishu") in _allowed]
    if not targets:
        print("issue-sync: nothing to check")
        return
    # The tenant token is only needed by the FEISHU classify path (live thread
    # reads). gh- records verify through gh and sync regardless.
    token = ""
    if any(not is_gh(r.get("message_id")) for r in targets):
        auth = http("POST", BASE + "/auth/v3/tenant_access_token/internal",
                    body={"app_id": cfg["APP_ID"], "app_secret": cfg["APP_SECRET"]})
        token = (auth or {}).get("tenant_access_token", "")
        if not token:
            print("issue-sync: no tenant token, feishu records deferred")

    def gh_classify(r):
        """(action, pr, why) for a github record. action: 'done' | 'delete' |
        None(=keep open). done = our own comment carries a PR link (delivery
        reply) or the issue got closed with our PR on record; delete = someone
        was assigned (third-party takeover) or it closed without any of our
        work. None on gh failure (cannot verify — stay open)."""
        mid = r.get("message_id", "")
        d = gh_view_issue(mid[3:])
        if d is None:
            return None, None, ""
        if d.get("assignees"):
            return "delete", None, "assignee"
        own_pr = None
        for c in d.get("comments") or []:
            if (c.get("author") or {}).get("login") == OWN_LOGIN:
                m = PR_RE.search(c.get("body") or "")
                if m:
                    own_pr = m.group(0)  # later comments win
        if d.get("state") == "closed":
            if own_pr or r.get("pr"):
                return "done", own_pr or r.get("pr"), "closed-with-our-pr"
            return "delete", None, "closed-without-us"
        if own_pr:
            return "done", own_pr, "our-pr-comment"
        return None, None, ""

    def thread_rows(thread_id, root_mid):
        """(body, sender_type, claimed) per non-deleted reply; root excluded."""
        rows, page = [], ""
        if not thread_id:
            return rows
        while True:
            url = (BASE + "/im/v1/messages?container_id_type=thread&container_id="
                   + thread_id + "&page_size=50")
            if page:
                url += "&page_token=" + page
            data = (http("GET", url, token=token) or {}).get("data") or {}
            for it in data.get("items") or []:
                if it.get("deleted") or it.get("message_id") == root_mid:
                    continue
                body = ""
                try:
                    body = it["body"]["content"]
                except Exception:
                    pass
                sender = it.get("sender") or {}
                sender_type = sender.get("sender_type", "")
                # a takeover claim is a user @-ing THEMSELVES (the claim
                # reply's own protocol); humans @-ing each other to discuss
                # the issue are NOT a takeover (old any-mention test caused
                # false "third party handled" drops of delivered tasks)
                sid = sender.get("id", "")
                claimed = bool(sid) and any(
                    mm.get("id") == sid for mm in it.get("mentions") or [])
                rows.append((body, sender_type, claimed))
            if data.get("has_more") and data.get("page_token"):
                page = data["page_token"]
            else:
                return rows

    def classify(rows):
        """(action, pr): delete on third-party claim/PR; done on own PR;
        otherwise (None, None) — a bare own claim keeps the record open."""
        own_pr = None
        third = False
        for body, sender_type, claimed in rows:
            m = PR_RE.search(body)
            if sender_type == "app":
                if m:
                    own_pr = m.group(0)  # later replies win
            elif m or claimed:
                third = True
        # our delivered PR settles it: later human chatter (even a late
        # self-claim) must not delete a delivered task's record
        if own_pr:
            return "done", own_pr
        if third:
            return "delete", None
        return None, None

    def message_gone(mid):
        d = http("GET", BASE + "/im/v1/messages/" + mid, token=token) or {}
        if d.get("code") not in (None, 0):
            msg = str(d.get("msg", "")).lower()
            return "not exist" in msg or "not_found" in msg
        try:
            body = d["data"]["items"][0]["body"]["content"]
        except Exception:
            return False
        return "This message was recalled" in body

    def recall_claim(r):
        """Recall a claim reply (sent by pre-claim.sh) when dropping the
        record. Best-effort, never raises."""
        claim_reply = r.get("claim_reply_id") if isinstance(r, dict) else None
        if not claim_reply:
            return
        url = BASE + "/im/v1/messages/" + claim_reply
        http("DELETE", url, token=token)

    def abandon_reply(mid):
        """Announce in the thread that we give up the task (a third party took
        over). Best-effort, never raises."""
        if not mid:
            return
        body = {
            "msg_type": "text",
            "content": json.dumps({"text": "我现在放弃该任务。"}, ensure_ascii=False),
        }
        http("POST", BASE + "/im/v1/messages/" + mid + "/reply", token=token, body=body)

    now = int(time.time() * 1000)
    changed = 0
    kept = []
    for r in records:
        if r.get("state") in ("done", "merged", "closed", "abandoned", "fail"):
            kept.append(r)
            continue
        if r not in targets:
            kept.append(r)  # filtered out (slot source affinity) — untouched
            continue
        mid = r.get("message_id", "")
        if is_gh(mid):
            action, pr, why = gh_classify(r)
            if action == "delete":
                # public handover note only when a human took it over; a plain
                # close-without-us needs no comment
                if why == "assignee":
                    gh_note(mid[3:], "Stepping aside — this issue now has an assignee. (automated triage)")
                shutil.rmtree(os.path.join(base_dir, "attachments", mid), ignore_errors=True)
                changed += 1
                print("issue-sync: %s dropped (%s)" % (mid, why))
                continue
            if action == "done":
                if r.get("state") == "done" and r.get("pr") == pr:
                    kept.append(r)
                    continue
                r["state"] = "done"
                r["done_time"] = now
                if pr:
                    r["pr"] = pr
                changed += 1
                print("issue-sync: %s -> done%s" % (mid, " " + pr if pr else ""))
                kept.append(r)
                continue
            # cannot verify (gh failure) or nothing settled: stay open
            r["state"] = "open"
            r.pop("note", None)
            r.pop("done_time", None)
            kept.append(r)
            continue
        if not token:
            kept.append(r)  # feishu deferred (no tenant token) — stays open
            continue
        action, pr = classify(thread_rows(r.get("thread_id", ""), mid))
        if action == "delete":
            # state publicly that we step aside, drop the record; our claim
            # reply stays in the thread (handover history, not recalled)
            abandon_reply(mid)
            shutil.rmtree(os.path.join(base_dir, "attachments", mid), ignore_errors=True)
            changed += 1
            print("issue-sync: %s dropped (third party handled)" % mid)
            continue
        if action is None:
            # untouched or claimed-without-PR: keep it open and retryable
            if message_gone(mid):
                recall_claim(r)
                shutil.rmtree(os.path.join(base_dir, "attachments", mid), ignore_errors=True)
                changed += 1
                print("issue-sync: %s dropped (message gone)" % mid)
            else:
                r["state"] = "open"
                r.pop("note", None)
                r.pop("done_time", None)
                kept.append(r)
            continue
        if action == "done" and r.get("state") == "done" and r.get("pr") == pr:
            kept.append(r)
            continue
        r["state"] = action
        r["done_time"] = now
        if pr:
            r["pr"] = pr
        changed += 1
        print("issue-sync: %s -> %s%s" % (mid, action, " " + pr if pr else ""))
        kept.append(r)

    if changed:
        tmp = store + ".tmp"
        with open(tmp, "w") as f:
            for r in kept:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        os.replace(tmp, store)
    print("issue-sync: changed=%d" % changed)


main()
PYEOF
  echo "[$(date +%Y%m%d-%H%M%S)] issue-sync pass end rc=$?"
} >> "$LOG_DIR/issues.log" 2>&1
