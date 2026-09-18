#!/usr/bin/env python3
"""issue-start-notice.py — post the "run started" notice into the Feishu thread
of the currently selected issue. Idempotent per record lifecycle
(start_notice_id): re-picks of the same issue do not re-send.

  issue-start-notice.py <current.json>

Silent no-op when: no current file, a gh- record (GitHub issues get no Feishu
notices), no claim reply yet (claim precedes the start notice), the notice was
already sent, or any send/persist failure (never blocks the pre group).
"""
import fcntl
import json
import os
import subprocess
import sys

DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, DIR)  # DIR is the repo root here, for hfv_source
from hfv_source import is_gh
STORE = os.path.join(DIR, "issues.jsonl")
STORE_LOCK = os.path.join(DIR, ".store.lock")
REPLY = os.path.join(DIR, "issue-reply.py")
NOTICE = "自动化脚本已经正式开始处理该任务，此后 @ 认领/接管 将不再生效。"


def main():
    if len(sys.argv) < 2 or not os.path.exists(sys.argv[1]):
        return 0
    cur = json.load(open(sys.argv[1]))
    mid = cur.get("message_id") or ""
    if not mid or is_gh(mid) or not cur.get("claim_reply_id"):
        return 0

    lock = open(STORE_LOCK, "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    records = [json.loads(l) for l in open(STORE)] if os.path.exists(STORE) else []
    rec = next((r for r in records if r.get("message_id") == mid), None)
    if rec is None or rec.get("start_notice_id"):
        return 0

    out = subprocess.run([sys.executable, REPLY, mid, NOTICE],
                         capture_output=True, text=True, timeout=60)
    notice_id = (out.stdout or "").strip()
    if out.returncode != 0 or not notice_id:
        return 0

    rec["start_notice_id"] = notice_id
    tmp = STORE + ".tmp"
    with open(tmp, "w") as f:
        for r in records:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(tmp, STORE)
    cur["start_notice_id"] = notice_id
    tmp = sys.argv[1] + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cur, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, sys.argv[1])
    print("issue-start-notice: sent for %s (%s)" % (mid, notice_id))
    return 0


if __name__ == "__main__":
    sys.exit(main())
