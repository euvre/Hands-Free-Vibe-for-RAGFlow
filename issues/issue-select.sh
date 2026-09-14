#!/usr/bin/env bash
# issue-select.sh — framework-side issue picker (rule-based, no LLM), run at
# the END of the pre group. Picks the OLDEST state=open record (FIFO: oldest
# first, so the queue drains in arrival order), verifies the
# message still exists, and hands the full record to the task via
# issues/current.json (run-task.sh injects it into the prompt and rests when
# the file is absent):
#   oldest open candidate alive            → write current.json (+selected_at)
#   open candidate exhausted its picks     → state=fail (terminal, never
#                                            picked again; a give-up note is
#                                            posted in the thread, prune
#                                            removes the record later)
#   candidate recalled / gone              → drop the record, fall through to
#                                            the next one
#   no open candidate at all               → ensure current.json is absent
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="/home/inf/hands-free-vibe/logs"

mkdir -p "$LOG_DIR"
{
  echo "[$(date +%Y%m%d-%H%M%S)] issue-select pass start"
  python3 - "$DIR" <<'PYEOF'
import fcntl, json, os, shutil, sys, time, urllib.error, urllib.request

base_dir = sys.argv[1]
sys.path.insert(0, os.path.dirname(base_dir))  # repo root
from hfv_source import is_gh
store = os.path.join(base_dir, "issues.jsonl")
# Shared store lock (see issue_recorder.py STORE_LOCK).
_lock = open(os.path.join(base_dir, ".store.lock"), "w")
fcntl.flock(_lock, fcntl.LOCK_EX)
_suf = ("-s" + os.environ["HFV_SLOT"]) if os.environ.get("HFV_SLOT") else ""
current = os.path.join(base_dir, "current%s.json" % _suf)
PIN = os.path.join(base_dir, "..", "tasks", ".pin")
TASKS_DIR = os.path.join(base_dir, "..", "tasks")
cfg = {}
for line in open(os.path.join(base_dir, "config")):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        cfg[k.strip()] = v.strip()
BASE = os.environ.get("FEISHU_BASE_URL", "https://open.feishu.cn/open-apis")

# ---- GitHub issue source (source=github, message_id=gh-<number>) ----------
GH_BIN = os.environ.get("GH_BIN", "gh")
GH_REPO = cfg.get("GITHUB_ISSUE_REPO", "infiniflow/ragflow")


def gh_view(num):
    """Live GitHub issue state (state/assignees/comments) via gh; None on any
    failure — callers must treat None as 'cannot verify', never as gone."""
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


def gh_comment(num, text):
    """Best-effort comment on a GitHub issue (step-aside / give-up notes)."""
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


def message_gone(mid, token):
    """True only on a definitive not-exist/recalled verdict; network errors
    (None response) stay conservative and count as alive."""
    if is_gh(mid):
        d = gh_view(mid[3:])
        if d is None:
            return False  # cannot prove closed — stay conservative
        return d.get("state") == "closed"
    d = http("GET", BASE + "/im/v1/messages/" + mid, token=token) or {}
    if d.get("code") not in (None, 0):
        msg = str(d.get("msg", "")).lower()
        return "not exist" in msg or "not_found" in msg
    try:
        body = d["data"]["items"][0]["body"]["content"]
    except Exception:
        return False
    return "This message was recalled" in body


def recall_message(mid_reply, token):
    """Recall a Feishu message by message_id. Best-effort, never raises."""
    if not mid_reply or not token:
        return
    url = BASE + "/im/v1/messages/" + mid_reply
    http("DELETE", url, token=token)


def drop_record(records, mid, token=None, recall_claim_reply=True):
    """Drop a record from the list and remove its attachment dir. Unless
    `recall_claim_reply` is False, a record carrying a claim_reply_id (sent at
    scan time or by pre-claim.sh) gets that reply recalled first. The
    third-party-takeover (abandon) path passes False: the claim stays visible
    in the thread as handover history — the abandon reply announces the
    handover instead."""
    for r in records:
        if r.get("message_id") == mid:
            if recall_claim_reply and not is_gh(mid):
                claim_reply = r.get("claim_reply_id")
                if claim_reply and token:
                    recall_message(claim_reply, token)
            break
    records[:] = [r for r in records if r.get("message_id") != mid]
    adir = os.path.join(base_dir, "attachments", mid)
    if os.path.isdir(adir):
        shutil.rmtree(adir, ignore_errors=True)


def save_store(records):
    tmp = store + ".tmp"
    with open(tmp, "w") as f:
        for r in records:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(tmp, store)


def main():
    # Pinned selection (hfv task resume/follow <id>): the pinned
    # task's issue overrides the regular newest-open pick. Consume the pin.
    if os.path.exists(PIN):
        try:
            pin = json.load(open(PIN))
        except Exception:
            pin = {}
        os.remove(PIN)
        tid = int(pin.get("task_id") or 0)
        mode = pin.get("mode") if pin.get("mode") in ("resume", "follow") else None
        snap = os.path.join(TASKS_DIR, str(tid), "issue.json") if tid else ""
        if mode and tid and os.path.exists(snap):
            auth = http("POST", BASE + "/auth/v3/tenant_access_token/internal",
                        body={"app_id": cfg["APP_ID"], "app_secret": cfg["APP_SECRET"]})
            token = (auth or {}).get("tenant_access_token", "")
            cur = json.load(open(snap))
            cur.pop("task_id", None); cur.pop("selected_at", None)
            cur["task_meta"] = {"kind": mode, "parent_task_id": tid}
            # Previous-run trace from the task index: the log PATH only —
            # full logs are MBs of JSON events, so the new run greps it on
            # demand instead of us injecting the content.
            cur["prev_run"] = {}
            index_path = os.path.join(TASKS_DIR, "tasks.jsonl")
            if os.path.exists(index_path):
                for line in open(index_path):
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        r = json.loads(line)
                    except Exception:
                        continue
                    if r.get("task_id") == tid:
                        cur["prev_run"] = {
                            "log_file": r.get("log_file") or "",
                            "status": r.get("status") or "",
                            "exit_code": r.get("exit_code"),
                        }
                        break
            if mode == "follow" and token:
                # refresh the snapshot with the live thread so the run sees
                # the reporter's follow-up replies
                sys.path.insert(0, base_dir)
                import issue_recorder as ir
                mid = cur.get("message_id", "")
                msg = ir.fetch_message(mid, token)
                if msg == "gone":
                    print("issue-select: pin refused, root message gone")
                    if os.path.exists(current):
                        os.remove(current)
                    return
                third, own_pr, own_claim, replies = ir.thread_scan(
                    {"thread_id": cur.get("thread_id", ""), "message_id": mid}, token)
                if third:
                    print("issue-select: pin refused, a third party took over")
                    if os.path.exists(current):
                        os.remove(current)
                    return
                if msg != "unknown":
                    full_text, _ = ir.extract_content(msg)
                    cur["text_full"] = full_text[:2000]
                old_max = max((rp.get("create_time", 0) for rp in (cur.get("replies") or [])), default=0)
                new_replies = [{"create_time": rp.get("create_time", 0),
                                "sender_type": rp.get("sender_type", ""),
                                "text": rp.get("text", "")}
                               for rp in (replies or []) if rp.get("create_time", 0) > old_max]
                cur["replies"] = replies or []
                followup = {"parent_task_id": tid}
                pr_path = os.path.join(TASKS_DIR, str(tid), "pr")
                if os.path.exists(pr_path):
                    followup["pr"] = open(pr_path).read().strip()
                body_path = os.path.join(TASKS_DIR, str(tid), "pr-body.md")
                if os.path.exists(body_path):
                    followup["pr_body"] = open(body_path).read()[:4000]
                followup["new_replies"] = new_replies
                cur["followup"] = followup
                print("issue-select: pinned follow #%d (%d new replies)" % (tid, len(new_replies)))
            else:
                print("issue-select: pinned resume #%d" % tid)
            # pinned picks join the same anti-double-pick discipline as
            # regular ones: mark the store record in-flight for this line,
            # host included (post-task releases it via issue-release.py)
            owner = os.environ.get("HFV_SLOT") or "host"
            pin_recs = []
            if os.path.exists(store):
                for pline in open(store):
                    pline = pline.strip()
                    if pline:
                        try:
                            pin_recs.append(json.loads(pline))
                        except Exception:
                            pass
            marked = False
            for pr in pin_recs:
                if pr.get("message_id") == cur.get("message_id"):
                    pr["in_flight_slot"] = owner
                    pr["in_flight_at"] = int(time.time() * 1000)
                    marked = True
            if marked:
                save_store(pin_recs)
            cur["selected_at"] = int(time.time() * 1000)
            tmp = current + ".tmp"
            with open(tmp, "w") as f:
                json.dump(cur, f, ensure_ascii=False, indent=2)
                f.write("\n")
            os.replace(tmp, current)
            return
        print("issue-select: stale pin ignored (task/mode invalid)")

    records = []
    if os.path.exists(store):
        for line in open(store):
            line = line.strip()
            if line:
                try:
                    records.append(json.loads(line))
                except Exception:
                    pass
    # FIFO: oldest open record first (ascending create_time), so issues are
    # worked in arrival order instead of always chasing the newest one.
    # Quota demotion: records whose runs died on LLM quota carry
    # priority_penalty (bumped by issue-quota-demote.py from post-task.sh);
    # each penalty drops them one class below every less-penalized record,
    # so healthy issues get the slots first while quota recovers — yet they
    # stay pickable forever (quota give-ups never burn select_count, see the
    # demote script), never marching into terminal fail on our outage alone.
    # Parallel lines: a record carrying in_flight_slot belongs to another
    # line's LIVE run (slot n, or "host") — skip it. Staleness needs TWO
    # proofs now: the owning line's run-s<n>.lock / run.lock is FREE and the
    # marker is older than the handoff grace. Lock-free alone used to count
    # as "run provably over", but the marker is written HERE while the lock
    # is only taken later by run-task.sh (assign -> pre-claim -> pre-clean ->
    # worker start sit in between; ~17s on 2026-08-28 19:55). A concurrent
    # select pass inside that window reclaimed the fresh marker and handed
    # the SAME issue to a second slot 1.1s later (tasks 206+207 -> PRs
    # #18996 and #18997, one of them entirely foreign). A run that really
    # died between select and lock acquisition is simply reclaimed by a
    # later pass once the grace elapses.
    HANDOFF_GRACE_MS = 10 * 60 * 1000  # select -> run-task handoff + slack

    def slot_lock_held(slot):
        path = os.path.join(base_dir, "..",
                            "run.lock" if slot in ("", "host")
                            else "run-s%s.lock" % slot)
        try:
            fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
        except OSError:
            return False
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
            return False
        except OSError:
            os.close(fd)
            return True

    reclaimed = 0
    now_ms = int(time.time() * 1000)
    for r in records:
        s = r.get("in_flight_slot")
        if not s:
            continue
        if slot_lock_held(s):
            continue  # owning line's run is live
        if now_ms - (r.get("in_flight_at") or 0) < HANDOFF_GRACE_MS:
            continue  # handoff window: marker not yet vouched for by its lock
        r.pop("in_flight_slot", None)
        r.pop("in_flight_at", None)
        reclaimed += 1
    if reclaimed:
        save_store(records)
        print("issue-select: reclaimed %d stale in-flight marker(s)" % reclaimed)

    opens = sorted((r for r in records if r.get("state") == "open"
                    and not r.get("in_flight_slot")),
                   key=lambda r: (r.get("priority_penalty", 0),
                                  r.get("create_time", 0)), reverse=False)
    # Slot source affinity (ISSUE_SOURCES[_<slot>]): this slot only PICKS
    # records of its allowed source(s). Recording and stale-marker reclaim
    # stay global — a gh-only slot may still reclaim a feishu marker (and
    # vice versa) so a crashed run never strands a record; it just returns
    # to the pool for the right line. Empty value = this slot never picks.
    _slot = os.environ.get("HFV_SLOT") or "host"
    _raw = cfg.get("ISSUE_SOURCES_" + _slot,
                   cfg.get("ISSUE_SOURCES", "feishu github"))
    _allowed = set(_raw.split())
    opens = [r for r in opens
             if (r.get("source") or "feishu") in _allowed]
    if not opens:
        if os.path.exists(current):
            os.remove(current)
            print("issue-select: no open issue, cleared current.json")
        else:
            print("issue-select: no open issue")
        return

    # Token is only needed to verify FEISHU candidates (message-existence and
    # third-party-claim probes). gh- candidates verify through gh instead, so
    # a Feishu auth outage defers only the feishu records — they stay open and
    # are simply retried next pass, nothing is lost.
    token = ""
    if any(not is_gh(r.get("message_id")) for r in opens):
        auth = http("POST", BASE + "/auth/v3/tenant_access_token/internal",
                    body={"app_id": cfg["APP_ID"], "app_secret": cfg["APP_SECRET"]})
        token = (auth or {}).get("tenant_access_token", "")
    if not token:
        before = len(opens)
        opens = [r for r in opens if is_gh(r.get("message_id"))]
        if before != len(opens):
            print("issue-select: no tenant token, %d feishu candidate(s) deferred"
                  % (before - len(opens)))
        if not opens:
            if os.path.exists(current):
                os.remove(current)
            print("issue-select: no verifiable candidate")
            return

    now = int(time.time() * 1000)
    picked = None
    dropped = 0
    failed = 0
    # Retry cap: an issue is picked at most MAX_PICKS times in total — the
    # initial pick plus two re-picks. A still-open record that burned them
    # all (every attempt ended in a failed run) flips to the terminal "fail"
    # state and is never picked again; a give-up note is posted in the thread
    # (best-effort) and prune drops the record when it ages out.
    MAX_PICKS = 3
    FAIL_NOTE = "该问题已自动尝试多次仍未解决，暂时搁置。如需继续处理请@认领。"
    # Third-party takeover re-check helper: a claim sent at scan time can be
    # superseded by a human @ before the issue reaches current.json. Re-verify
    # the live thread at hand-off; on takeover announce the step-aside and
    # drop the record (claim kept as history), then fall through to the next
    # candidate.
    sys.path.insert(0, base_dir)
    import issue_recorder as ir

    def third_party_claimed(rec, token):
        mid = rec.get("message_id", "")
        if is_gh(mid):
            d = gh_view(mid[3:])
            return bool(d and d.get("assignees"))
        third, _, _, _ = ir.thread_scan(
            {"thread_id": rec.get("thread_id", ""), "message_id": rec.get("message_id", "")},
            token)
        return bool(third)

    for r in opens:
        mid = r.get("message_id", "")
        if not mid:
            continue
        if message_gone(mid, token):
            drop_record(records, mid, token)
            dropped += 1
            print("issue-select: %s dropped (gone/recalled)" % mid)
            continue
        if third_party_claimed(r, token):
            if is_gh(mid):
                gh_comment(mid[3:], "Stepping aside — this issue now has an assignee. (automated triage)")
            elif not ir.send_reply(mid, ir.ABANDON_TEXT, token):
                print("issue-select: abandon-reply failed for %s (best-effort)" % mid)
            drop_record(records, mid, token, recall_claim_reply=False)
            dropped += 1
            print("issue-select: %s dropped (third party claimed, we step aside)" % mid)
            continue
        if r.get("select_count", 0) >= MAX_PICKS:
            if is_gh(mid):
                gh_comment(mid[3:], "We attempted this issue several times without a solid fix and are setting it aside for now — please re-triage. (automated triage)")
            elif not ir.send_reply(mid, FAIL_NOTE, token):
                print("issue-select: fail-note failed for %s (best-effort)" % mid)
            r["state"] = "fail"
            r["fail_time"] = now
            failed += 1
            print("issue-select: %s -> fail (exhausted %d picks)" % (mid, MAX_PICKS))
            continue
        r["select_count"] = r.get("select_count", 0) + 1
        r["in_flight_slot"] = os.environ.get("HFV_SLOT") or "host"
        r["in_flight_at"] = now
        picked = r
        break
    if dropped or failed or picked is not None:
        # dropped/failed mutate records; a pick bumps select_count — all
        # three must be persisted or the retry cap miscounts on a crash.
        save_store(records)
    if picked is None:
        if os.path.exists(current):
            os.remove(current)
        print("issue-select: %s" % ("all open candidates gone, resting" if dropped or failed
                                    else "no open issue"))
        return
    picked["selected_at"] = now
    tmp = current + ".tmp"
    with open(tmp, "w") as f:
        json.dump(picked, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, current)
    print("issue-select: picked %s (%s)" % (
        picked.get("message_id"), (picked.get("text_full") or "")[:60]))


main()
PYEOF
  echo "[$(date +%Y%m%d-%H%M%S)] issue-select pass end rc=$?"
} >> "$LOG_DIR/issues.log" 2>&1
