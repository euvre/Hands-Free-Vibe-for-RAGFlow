#!/usr/bin/env python3
"""tasks.py — issue-task numbering, index and ClickHouse bookkeeping.

Every issue-triage run gets a monotonically increasing task_id. The local
index (tasks/tasks.jsonl) is authoritative; a cline.tasks table in
ClickHouse mirrors it for cross-run analytics (best-effort, never fails a
run). tasks/<id>/ keeps per-task context so a later run can build on it:

  tasks/<id>/issue.json   issue snapshot as handed to the run
  tasks/<id>/pr           PR url (written by post-deliver on success)
  tasks/<id>/pr-title.txt / pr-body.md   delivery artifacts archive
  tasks/<id>/status       one-line terminal info (written by close)

Subcommands (invoked from pre-task/run-task/post-task and the CLI):
  assign   register a new task from issues/current.json (writes task_id back)
  close    finalize the current task (status/exit/log/pr) from tasks/.current
  list [n] print the newest n index rows
  latest   print the newest task_id
  show <id> print one task's full record + follow-up context paths
"""
import fcntl
import json
import os
import sys
import time
import urllib.parse
import urllib.request

DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # repo root (this file lives in tools/)
TASK_DIR = os.path.join(DIR, "tasks")
INDEX = os.path.join(TASK_DIR, "tasks.jsonl")
# Parallel slots: per-slot current file / marker / run-info (HFV_SLOT comes
# from the systemd template unit; empty = legacy single-run names).
_SUF = ("-s" + os.environ["HFV_SLOT"]) if os.environ.get("HFV_SLOT") else ""
CURRENT = os.path.join(DIR, "issues", "current%s.json" % _SUF)
CURRENT_MARKER = os.path.join(TASK_DIR, ".current%s" % _SUF)
RUN_INFO = os.path.join(TASK_DIR, ".last-run-info%s" % _SUF)
REGISTRY_LOCK = os.path.join(TASK_DIR, ".registry.lock")
CH = "http://127.0.0.1:8123/"
TTL_DAYS = 90


# ---------- local index ----------

def load_index():
    rows = []
    if os.path.exists(INDEX):
        for line in open(INDEX):
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except Exception:
                    pass
    return rows


def append_index(row):
    os.makedirs(TASK_DIR, exist_ok=True)
    with open(INDEX, "a") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def rewrite_index(rows):
    tmp = INDEX + ".tmp"
    with open(tmp, "w") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(tmp, INDEX)


# ---------- clickhouse (best-effort) ----------

def ch_query(query, body=None):
    url = CH + "?query=" + urllib.parse.quote(query)
    req = urllib.request.Request(url, data=body.encode() if body is not None else b"")
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.read().decode()


def ch_write(stmt, body=None):
    try:
        ch_query(stmt, body)
    except Exception as e:
        print(f"tasks: clickhouse write failed (continuing): {e}", file=sys.stderr)


def ch_ensure():
    ch_write(f"""CREATE TABLE IF NOT EXISTS cline.tasks (
        task_id UInt32, message_id String, kind String DEFAULT 'new',
        parent_task_id UInt32 DEFAULT 0, title String DEFAULT '',
        started_at DateTime, finished_at DateTime DEFAULT toDateTime(0),
        status String DEFAULT 'running', exit_code Int32 DEFAULT 0,
        log_file String DEFAULT '', pr String DEFAULT '',
        created_at DateTime DEFAULT now()
    ) ENGINE = MergeTree ORDER BY task_id TTL created_at + INTERVAL {TTL_DAYS} DAY""")


# ---------- helpers ----------

def now_iso():
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())


def task_dir(tid):
    return os.path.join(TASK_DIR, str(tid))


def with_registry(fn):
    """Serialize index mutations across parallel slots: task_id must stay
    monotonic and tasks.jsonl rewrites must not interleave (the legacy
    single-run path takes the same lock — free contention there)."""
    fd = os.open(REGISTRY_LOCK, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        return fn()
    finally:
        os.close(fd)


def do_assign():
    if not os.path.exists(CURRENT):
        return  # no issue selected this tick: nothing to number
    cur = json.load(open(CURRENT))
    mid = cur.get("message_id", "")
    if not mid:
        return
    meta = cur.get("task_meta") or {}
    kind = meta.get("kind") if meta.get("kind") in ("new", "resume", "follow") else "new"
    parent = int(meta.get("parent_task_id") or 0)

    tid = (max((r["task_id"] for r in load_index()), default=0)) + 1
    cur["task_id"] = tid
    cur["task_kind"] = kind
    cur["parent_task_id"] = parent
    tmp = CURRENT + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cur, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, CURRENT)

    os.makedirs(task_dir(tid), exist_ok=True)
    with open(os.path.join(task_dir(tid), "issue.json"), "w") as f:
        json.dump(cur, f, ensure_ascii=False, indent=2)

    append_index({
        "task_id": tid, "message_id": mid, "kind": kind,
        "parent_task_id": parent,
        "title": (cur.get("text_full") or cur.get("text") or "")[:80],
        "status": "running", "started_at": now_iso(),
        "finished_at": "", "exit_code": None, "log_file": "", "pr": "",
    })
    with open(CURRENT_MARKER, "w") as f:
        f.write(str(tid))

    ch_ensure()
    ch_write("DELETE FROM cline.tasks WHERE task_id = %d" % tid)
    ch_write("INSERT INTO cline.tasks FORMAT JSONEachRow", json.dumps({
        "task_id": tid, "message_id": mid, "kind": kind,
        "parent_task_id": parent,
        "title": (cur.get("text_full") or cur.get("text") or "")[:80],
        "started_at": now_iso(), "status": "running",
    }, ensure_ascii=False))
    print(f"task assigned: #{tid} kind={kind} parent={parent or '-'} mid={mid}")


def do_close():
    if not os.path.exists(CURRENT_MARKER):
        return
    tid = int(open(CURRENT_MARKER).read().strip())
    exit_code, log_file = 0, ""
    if os.path.exists(RUN_INFO):
        for line in open(RUN_INFO):
            if line.startswith("exit="):
                exit_code = int(line.split("=", 1)[1].strip() or 0)
            elif line.startswith("log="):
                log_file = line.split("=", 1)[1].strip()
        os.remove(RUN_INFO)
    pr = ""
    pr_path = os.path.join(task_dir(tid), "pr")
    if os.path.exists(pr_path):
        pr = open(pr_path).read().strip()
    status = "done" if exit_code == 0 else "failed"
    finished = now_iso()

    rows = load_index()
    for r in rows:
        if r["task_id"] == tid:
            r.update({"status": status, "exit_code": exit_code,
                      "log_file": log_file, "pr": pr, "finished_at": finished})
    rewrite_index(rows)
    with open(os.path.join(task_dir(tid), "status"), "w") as f:
        f.write(f"{status} exit={exit_code} pr={pr or '-'} at {finished}\n")
    os.remove(CURRENT_MARKER)

    ch_ensure()
    ch_write("DELETE FROM cline.tasks WHERE task_id = %d" % tid)
    row = next((r for r in rows if r["task_id"] == tid), None)
    if row:
        ch_write("INSERT INTO cline.tasks FORMAT JSONEachRow", json.dumps({
            "task_id": row["task_id"], "message_id": row["message_id"],
            "kind": row["kind"], "parent_task_id": row.get("parent_task_id") or 0,
            "title": row.get("title", ""),
            "started_at": row["started_at"], "finished_at": finished,
            "status": status, "exit_code": exit_code,
            "log_file": log_file, "pr": pr,
        }, ensure_ascii=False))
    print(f"task closed: #{tid} status={status} exit={exit_code} pr={pr or '-'}")


def do_abandon(tid):
    """Terminate task <tid> permanently: status=abandoned (terminal) in the
    local index + ClickHouse + tasks/<id>/status. Also clears tasks/.current
    when it points at this task (a killed run never reaches `close`).

    Prints "<mid>\t<current>" for the caller (hfv task abandon):
    current=1 means this task is the one assigned to the in-flight tick, so
    the caller must stop the service to kill the running LLM."""
    rows = load_index()
    row = next((r for r in rows if r["task_id"] == tid), None)
    if not row:
        print(f"task abandon: #{tid} not found", file=sys.stderr)
        sys.exit(1)
    mid = row.get("message_id", "")
    current = 0
    if os.path.exists(CURRENT_MARKER) and open(CURRENT_MARKER).read().strip() == str(tid):
        current = 1
        os.remove(CURRENT_MARKER)
    finished = now_iso()
    for r in rows:
        if r["task_id"] == tid:
            r.update({"status": "abandoned", "finished_at": finished})
    rewrite_index(rows)
    with open(os.path.join(task_dir(tid), "status"), "w") as f:
        f.write(f"abandoned at {finished}\n")

    ch_ensure()
    ch_write("DELETE FROM cline.tasks WHERE task_id = %d" % tid)
    ch_write("INSERT INTO cline.tasks FORMAT JSONEachRow", json.dumps({
        "task_id": tid, "message_id": mid,
        "kind": row.get("kind", "new"),
        "parent_task_id": row.get("parent_task_id") or 0,
        "title": row.get("title", ""),
        "started_at": row.get("started_at") or finished,
        "finished_at": finished, "status": "abandoned",
        "exit_code": row.get("exit_code") or 0,
        "log_file": row.get("log_file", ""), "pr": row.get("pr", ""),
    }, ensure_ascii=False))
    print("%s\t%d" % (mid, current))


def do_list(n=20):
    rows = load_index()[-n:]
    if not rows:
        print("no tasks yet")
        return
    print(f"{'id':>4s} {'kind':7s} {'status':8s} {'parent':>6s}  {'pr':<45s} title")
    for r in reversed(rows):
        print(f"{r['task_id']:>4d} {r.get('kind','new'):7s} {r.get('status','?'):8s} "
              f"{str(r.get('parent_task_id') or '-'):>6s}  {(r.get('pr') or '-'):<45s} "
              f"{(r.get('title') or '')[:50]}")


def do_latest():
    rows = load_index()
    print(max((r["task_id"] for r in rows), default=0))


def do_show(tid):
    row = next((r for r in load_index() if r["task_id"] == tid), None)
    if not row:
        print(f"no task #{tid}")
        return 1
    print(json.dumps(row, ensure_ascii=False, indent=2))
    for name in ("issue.json", "pr", "pr-title.txt", "pr-body.md", "status"):
        p = os.path.join(task_dir(tid), name)
        if os.path.exists(p):
            print(f"file: {p}")
    return 0


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "assign":
        with_registry(do_assign)
    elif cmd == "close":
        with_registry(do_close)
    elif cmd == "abandon" and len(sys.argv) == 3:
        with_registry(lambda: do_abandon(int(sys.argv[2])))
    elif cmd == "list":
        do_list(int(sys.argv[2]) if len(sys.argv) > 2 else 20)
    elif cmd == "latest":
        do_latest()
    elif cmd == "show":
        sys.exit(do_show(int(sys.argv[2])))
    else:
        print("usage: tasks.py assign|close|list [n]|latest|show <id>", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
