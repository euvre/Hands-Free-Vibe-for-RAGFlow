#!/usr/bin/env bash
# pre-claim.sh — send a template claim reply right after an issue is selected.
# No LLM: pure script. Uses issue-reply.py (posts into the original thread and
# @ ourselves). The created reply's message_id is persisted into BOTH the
# issues.jsonl record (durable — survives the current.json deletion/rebuild
# that happens between ticks when a run fails) and current.json, so
# recorder/select/sync can recall it when a third party takes over the issue.
#
# Idempotent: an issue is claimed at most once per record lifecycle. A failed
# run keeps the record open and retryable, but a later tick must NOT re-send
# the claim reply. Claim state is resolved from (in order): the store record's
# claim_reply_id, current.json's claim_reply_id (same-tick heal), or — for
# records claimed before this id was persisted — the record's reply snapshot,
# with the live thread fetched once to recover the reply id.
#
# Runs as the LAST step of the pre group (after issue-select.sh). If there
# is no current.json (no open issue), this is a no-op.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"  # repo root (this script lives in lines/)
SUF=""
[[ -n "${HFV_SLOT:-}" ]] && SUF="-s$HFV_SLOT"
ISSUE_FILE="$DIR/issues/current${SUF}.json"
STORE_FILE="$DIR/issues/issues.jsonl"
REPLY_SCRIPT="$DIR/issues/issue-reply.py"
CONFIG_FILE="$DIR/issues/config"
LOG_DIR="$DIR/logs"

mkdir -p "$LOG_DIR"

# run-task rests when there is no issue to process; claim is a no-op too.
if [[ ! -s "$ISSUE_FILE" ]]; then
  exit 0
fi

MID="$(python3 -c "import json;print(json.load(open('$ISSUE_FILE')).get('message_id',''))" 2>/dev/null || true)"
if [[ -z "$MID" ]]; then
  exit 0
fi

# --- GitHub issue source (gh-<number>): claim = ONE polite English comment on
# the issue, idempotent per record lifecycle (claim_reply_id stores the gh
# comment URL). The Feishu machinery below (at-tag template, reply-id recovery
# from the live thread) does not apply and is skipped entirely.
if [[ "$MID" == gh-* ]]; then
  CLAIMED_ID="$(python3 - "$STORE_FILE" "$ISSUE_FILE" 2>/dev/null <<'PYEOF' || true
import json, sys
cur = {}
try:
    cur = json.load(open(sys.argv[2]))
except Exception:
    pass
cid = cur.get("claim_reply_id") or ""
if not cid:
    try:
        for line in open(sys.argv[1]):
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("message_id") == cur.get("message_id"):
                cid = r.get("claim_reply_id") or ""
                break
    except Exception:
        pass
print(cid)
PYEOF
)"
  if [[ -n "$CLAIMED_ID" ]]; then
    echo "[$(date +%Y%m%d-%H%M%S)] pre-claim: $MID already claimed (comment=$CLAIMED_ID), not re-claiming" >> "$LOG_DIR/daemon.log"
    exit 0
  fi
  # issue-reply.py dispatches gh- ids to `gh issue comment` and prints the URL
  REPLY_MID="$("$REPLY_SCRIPT" "$MID" "We are picking this issue up and will try to reproduce and fix it. (automated triage)" 2>>"$LOG_DIR/daemon.log")" || {
    echo "[$(date +%Y%m%d-%H%M%S)] pre-claim: failed to send gh claim comment for $MID" >> "$LOG_DIR/daemon.log"
    exit 0
  }
  # Persist the claim (comment URL) into the store record + current.json —
  # the same two snippets the Feishu path uses below; without them every
  # tick would re-send the claim comment.
  python3 - "$STORE_FILE" "$MID" "$REPLY_MID" >>"$LOG_DIR/daemon.log" 2>&1 <<'PYEOF' || true
import json, os, sys
store, mid, reply_mid = sys.argv[1], sys.argv[2], sys.argv[3]
records = []
if os.path.exists(store):
    for line in open(store):
        line = line.strip()
        if line:
            try:
                records.append(json.loads(line))
            except Exception:
                pass
for r in records:
    if r.get("message_id") == mid:
        r["claim_reply_id"] = reply_mid
        tmp = store + ".tmp"
        with open(tmp, "w") as f:
            for rr in records:
                f.write(json.dumps(rr, ensure_ascii=False) + "\n")
        os.replace(tmp, store)
        break
PYEOF
  python3 - "$ISSUE_FILE" "$REPLY_MID" >>"$LOG_DIR/daemon.log" 2>&1 <<'PYEOF' || true
import json, os, sys
path, reply_mid = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
d["claim_reply_id"] = reply_mid
with open(path + ".tmp", "w") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
print("pre-claim: claimed %s comment=%s" % (d.get("message_id"), reply_mid))
PYEOF
  exit 0
fi

# Fixed template text; @ ourselves via the inline <at> tag (same id as task.md).
AT_SELF=""; [[ -n "$SELF_FEISHU_USER_ID" ]] && AT_SELF="<at user_id="$SELF_FEISHU_USER_ID"></at> "
CLAIM_TEXT="${AT_SELF}当前任务已被认领。如果你想要认领该任务，@自己即可。后续自动化任务会放弃该任务。如果你的回复不是为了认领该pr，不要使用@。"

# Resolve an already-sent claim reply id, if any. Prints the id (and persists
# it where missing), or "SEND" when this issue has never been claimed.
# Empty output means "state unknown" — treat as already claimed (never spam).
CLAIM_STATE="$(python3 - "$STORE_FILE" "$ISSUE_FILE" "$CONFIG_FILE" 2>>"$LOG_DIR/daemon.log" <<'PYEOF'
import fcntl, json, os, sys, urllib.request, urllib.error

store, current, config = sys.argv[1], sys.argv[2], sys.argv[3]
# Shared store lock (see issues/issue_recorder.py STORE_LOCK): this script
# rewrites issues.jsonl (claim_reply_id write-back).
_lock = open(os.path.join(os.path.dirname(store), ".store.lock"), "w")
fcntl.flock(_lock, fcntl.LOCK_EX)
CLAIM_MARK = "当前任务已被认领"


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


cfg = {}
try:
    for line in open(config):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"')
except Exception:
    pass
BASE = "https://open.feishu.cn/open-apis"

records = []
if os.path.exists(store):
    for line in open(store):
        line = line.strip()
        if line:
            try:
                records.append(json.loads(line))
            except Exception:
                pass

try:
    cur = json.load(open(current))
except Exception:
    cur = {}
mid = cur.get("message_id", "")
if not mid:
    print("SEND")
    raise SystemExit(0)

rec = next((r for r in records if r.get("message_id") == mid), None)


def save_store():
    tmp = store + ".tmp"
    with open(tmp, "w") as f:
        for r in records:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(tmp, store)


def save_current(claim_id):
    cur["claim_reply_id"] = claim_id
    tmp = current + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cur, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, current)


def resolve_live_claim_id(rec, mid):
    """Recover the id of our previously sent claim reply from the live thread
    (read-only). Used once for records claimed before claim_reply_id started
    being persisted. Best-effort: returns "" on any failure."""
    if not cfg.get("APP_ID") or not cfg.get("APP_SECRET"):
        return ""
    auth = http("POST", BASE + "/auth/v3/tenant_access_token/internal",
                body={"app_id": cfg["APP_ID"], "app_secret": cfg["APP_SECRET"]})
    token = (auth or {}).get("tenant_access_token", "")
    if not token:
        return ""
    tid = rec.get("thread_id", "")
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


# 1) store record carries the claim id (normal path after the fix)
existing = (rec or {}).get("claim_reply_id") or ""
# 2) same-tick heal: the id reached current.json but not the store
if not existing:
    existing = cur.get("claim_reply_id") or ""
# 3) pre-fix record: our claim reply is visible in the reply snapshot but its
#    id was never persisted — recover it from the live thread once, instead of
#    sending a duplicate claim. A snapshot claim is PROOF we already claimed:
#    when the id cannot be recovered (API failure etc.) we skip the send
#    entirely (empty output) rather than risk a duplicate.
if not existing and rec:
    snapshot_claim = any(
        rp.get("sender_type") == "app" and CLAIM_MARK in (rp.get("text") or "")
        for rp in (rec.get("replies") or [])
    )
    if snapshot_claim:
        existing = resolve_live_claim_id(rec, mid)
        if not existing:
            print("")
            raise SystemExit(0)

if existing:
    healed = False
    if rec is not None and rec.get("claim_reply_id") != existing:
        rec["claim_reply_id"] = existing
        healed = True
    if healed:
        save_store()
    if cur.get("claim_reply_id") != existing:
        save_current(existing)
    print(existing)
    raise SystemExit(0)

print("SEND")
PYEOF
)"

case "$CLAIM_STATE" in
  SEND)
    ;;
  "")
    # Could not determine claim state (store unreadable etc.) — do not risk a
    # duplicate claim; the run itself proceeds regardless of claiming.
    echo "[$(date +%Y%m%d-%H%M%S)] pre-claim: claim state unknown for $MID, skipping send" >> "$LOG_DIR/daemon.log"
    exit 0
    ;;
  *)
    echo "[$(date +%Y%m%d-%H%M%S)] pre-claim: $MID already claimed (reply=$CLAIM_STATE), not re-claiming" >> "$LOG_DIR/daemon.log"
    exit 0
    ;;
esac

REPLY_MID="$("$REPLY_SCRIPT" "$MID" "$CLAIM_TEXT" 2>>"$LOG_DIR/daemon.log")" || {
  echo "[$(date +%Y%m%d-%H%M%S)] pre-claim: failed to send claim reply for $MID" >> "$LOG_DIR/daemon.log"
  exit 0  # don't block the main task on a reply failure
}

# Persist claim_reply_id into the store record first (durable source of truth
# for the already-claimed check and for recall), then into current.json.
python3 - "$STORE_FILE" "$MID" "$REPLY_MID" >>"$LOG_DIR/daemon.log" 2>&1 <<'PYEOF' || true
import json, os, sys

store, mid, reply_mid = sys.argv[1], sys.argv[2], sys.argv[3]
records = []
if os.path.exists(store):
    for line in open(store):
        line = line.strip()
        if line:
            try:
                records.append(json.loads(line))
            except Exception:
                pass
for r in records:
    if r.get("message_id") == mid:
        r["claim_reply_id"] = reply_mid
        tmp = store + ".tmp"
        with open(tmp, "w") as f:
            for rr in records:
                f.write(json.dumps(rr, ensure_ascii=False) + "\n")
        os.replace(tmp, store)
        break
PYEOF

python3 - "$ISSUE_FILE" "$REPLY_MID" >>"$LOG_DIR/daemon.log" 2>&1 <<'PYEOF' || true
import json, sys
path, reply_mid = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
d["claim_reply_id"] = reply_mid
with open(path + ".tmp", "w") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
    f.write("\n")
import os
os.replace(path + ".tmp", path)
print("pre-claim: claimed %s reply=%s" % (d.get("message_id"), reply_mid))
PYEOF
