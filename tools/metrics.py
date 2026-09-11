#!/usr/bin/env python3
"""Parse cline --json run logs and upload metrics to ClickHouse.

Usage: metrics.py <run_log_path> [exit_code]

Tables (schema auto-ensured, idempotent):
  cline.runs:       one row per run (kind, totals, attempt_count, error_kind)
  cline.attempts:   one row per LLM attempt (quota-retry waste is visible here)
  cline.iterations: one row per agent iteration (per-step duration & tokens)
  cline.phases:     milestone timestamps for semantic task phases

kind is inferred from the log file name: run-feat-* -> feat,
summarize-* -> summarize, run-* -> issue. Retries inside one run log are
split on the '=== run started ... attempt=N ===' markers written by
run-task.sh / run-feat.sh. All tables carry a 90-day TTL.
"""
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone

CH = "http://127.0.0.1:8123/"
TTL_DAYS = 90

QUOTA_PATTERN = re.compile(
    r"usage limit|billing cycle|quota.{0,40}(refresh|exceed|exhaust)|insufficient.{0,20}quota",
    re.I)
TRANSIENT_PATTERN = re.compile(
    r"rate.?limit|too many requests|\b429\b|overloaded|temporarily unavailable|service unavailable|\b50[23]\b|try again later|high load|capacity exceeded|out of capacity|timed out|负载|限流|稍后重试",
    re.I)
ATTEMPT_MARKER = re.compile(r"=== run started .* attempt=(\d+) ===")

# milestone signature -> phase name; matched against tool name or, for
# run_commands, the command text. First occurrence wins.
# Only phases that still happen inside the main LLM run are tracked here;
# claim_reply (pre), git_branch/git_push/pr_create/pr_label_reviewer (post)
# moved out of the main task and are no longer visible in its log.
PHASE_RULES = [
    ("browser_reproduce", lambda t, c: t.startswith("chrome-devtools__")),
    ("code_fix", lambda t, c: t == "editor"),
    ("go_test", lambda t, c: t == "run_commands" and "build.sh --test" in c),
]


def parse_ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc).replace(tzinfo=None)


def fmt(dt):
    return dt.strftime("%Y-%m-%d %H:%M:%S.") + f"{dt.microsecond // 1000:03d}"


def ch_query(query, body=None):
    url = CH + "?query=" + urllib.parse.quote(query)
    # always POST: GET implies readonly mode on the HTTP interface
    req = urllib.request.Request(url, data=body.encode() if body is not None else b"")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.read().decode()
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:500]
        raise RuntimeError(f"clickhouse rejected: {query[:120]}... -> {detail}") from e


def ensure_schema():
    ch_query(f"""CREATE TABLE IF NOT EXISTS cline.runs (
        run_id String, kind String DEFAULT 'issue', log_file String,
        ts_start DateTime64(3), ts_end DateTime64(3), duration_ms UInt64,
        iterations UInt32, attempt_count UInt16 DEFAULT 1, error_kind String DEFAULT '',
        input_tokens UInt64, output_tokens UInt64, cache_read_tokens UInt64,
        cache_write_tokens UInt64, total_cost Float64, model String,
        exit_code Int32, status String, created_at DateTime DEFAULT now()
    ) ENGINE = MergeTree ORDER BY ts_start TTL ts_start + INTERVAL {TTL_DAYS} DAY""")
    ch_query(f"""CREATE TABLE IF NOT EXISTS cline.attempts (
        run_id String, attempt UInt16, ts_start DateTime64(3), ts_end DateTime64(3),
        duration_ms UInt64, iterations UInt32, input_tokens UInt64, output_tokens UInt64,
        cache_read_tokens UInt64, cache_write_tokens UInt64, cost Float64,
        status String, error_kind String DEFAULT '', created_at DateTime DEFAULT now()
    ) ENGINE = MergeTree ORDER BY ts_start TTL ts_start + INTERVAL {TTL_DAYS} DAY""")
    ch_query(f"""CREATE TABLE IF NOT EXISTS cline.iterations (
        run_id String, iteration UInt32, ts_start DateTime64(3), duration_ms UInt64,
        input_tokens UInt64, output_tokens UInt64, cache_read_tokens UInt64,
        cache_write_tokens UInt64, cost Float64, tool_calls UInt32,
        tool_names Array(String), created_at DateTime DEFAULT now()
    ) ENGINE = MergeTree ORDER BY ts_start TTL ts_start + INTERVAL {TTL_DAYS} DAY""")
    ch_query(f"""CREATE TABLE IF NOT EXISTS cline.phases (
        run_id String, phase String, ts DateTime64(3), since_start_ms UInt64,
        created_at DateTime DEFAULT now()
    ) ENGINE = MergeTree ORDER BY ts TTL ts + INTERVAL {TTL_DAYS} DAY""")
    # upgrade pre-existing tables in place (all idempotent)
    for ddl in (
        "ALTER TABLE cline.runs ADD COLUMN IF NOT EXISTS kind String DEFAULT 'issue'",
        "ALTER TABLE cline.runs ADD COLUMN IF NOT EXISTS attempt_count UInt16 DEFAULT 1",
        "ALTER TABLE cline.runs ADD COLUMN IF NOT EXISTS error_kind String DEFAULT ''",
        "ALTER TABLE cline.runs MODIFY TTL ts_start + INTERVAL {} DAY".format(TTL_DAYS),
        "ALTER TABLE cline.iterations MODIFY TTL ts_start + INTERVAL {} DAY".format(TTL_DAYS),
        "ALTER TABLE cline.phases MODIFY TTL ts + INTERVAL {} DAY".format(TTL_DAYS),
    ):
        ch_query(ddl)


def infer_kind(fname):
    if fname.startswith("run-feat-"):
        return "feat"
    if fname.startswith("summarize-"):
        return "summarize"
    return "issue"


def classify_error(text):
    if QUOTA_PATTERN.search(text):
        return "quota"
    if TRANSIENT_PATTERN.search(text):
        return "transient"
    if "Command timed out" in text or "timeout" in text.lower():
        return "timeout"
    return "other"


def error_text(events, text_lines):
    """All failure text of one attempt: runner text lines + JSON error events."""
    parts = ["\n".join(text_lines)]
    for obj in events:
        if obj.get("type") == "error":
            parts.append(str(obj.get("message", "")))
        ev = obj.get("event", {})
        if ev.get("type") == "error":
            parts.append(str((ev.get("error") or {}).get("message", "")))
    return "\n".join(parts)


def parse_attempt(events):
    """One cline invocation: (run_result, iterations, usage events, phases, final_reply)."""
    iter_start, iter_end, tools_in_iter = {}, {}, {}
    usages, phases, run_result = [], {}, None
    last_reply_ts, cur_iter = None, 0
    for obj in events:
        ts = parse_ts(obj["ts"])
        if obj.get("type") == "run_result":
            run_result = obj
            continue
        ev = obj.get("event", {})
        et = ev.get("type")
        if et == "iteration_start":
            cur_iter = ev.get("iteration", cur_iter + 1)
            iter_start[cur_iter] = ts
        elif et == "iteration_end":
            iter_end[ev.get("iteration", cur_iter)] = (ts, ev.get("toolCallCount", 0))
        elif et == "usage":
            usages.append((ts, ev))
        elif et == "content_start" and ev.get("contentType") == "tool":
            tool = ev.get("toolName", "")
            tools_in_iter.setdefault(cur_iter, []).append(tool)
            cmd = ""
            if tool == "run_commands":
                cmds = (ev.get("input") or {}).get("commands") or []
                cmd = " ".join(str(x) for x in cmds)
            for phase, rule in PHASE_RULES:
                if phase not in phases and rule(tool, cmd):
                    phases[phase] = ts
            if tool == "lark-mcp__im_v1_message_reply":
                last_reply_ts = ts
    if last_reply_ts:
        phases["final_reply"] = last_reply_ts
    return run_result, iter_start, iter_end, tools_in_iter, usages, phases


def usage_of(run_result, usages):
    """(usage_dict, model, status) for one attempt."""
    if run_result and run_result.get("aggregateUsage"):
        u = run_result["aggregateUsage"]
        model = (run_result.get("model") or {}).get("id", "")
        status = "completed" if run_result.get("finishReason") == "completed" else "finished:" + str(run_result.get("finishReason"))
        return u, model, status
    if usages:
        u = usages[-1][1]
        u = {"inputTokens": u.get("totalInputTokens", 0), "outputTokens": u.get("totalOutputTokens", 0),
             "cacheReadTokens": u.get("totalCacheReadTokens", 0), "cacheWriteTokens": u.get("totalCacheWriteTokens", 0),
             "totalCost": u.get("totalCost", 0)}
        return u, "", "interrupted"
    return {}, "", "no-usage"


def main():
    log_path = sys.argv[1]
    exit_code = int(sys.argv[2]) if len(sys.argv) > 2 else -1
    fname = log_path.rsplit("/", 1)[-1]
    run_id = re.sub(r"\.log$", "", fname)
    kind = infer_kind(fname)

    # split the log into attempts on the text markers written by the runners;
    # a log without markers is a single attempt
    attempt_events = defaultdict(list)
    attempt_text = defaultdict(list)
    all_events = []
    cur = 1
    with open(log_path, errors="replace") as f:
        for line in f:
            line = line.strip()
            if line.startswith("{"):
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if obj.get("type") in ("agent_event", "run_result", "error"):
                    attempt_events[cur].append(obj)
                    all_events.append(obj)
            else:
                m = ATTEMPT_MARKER.search(line)
                if m:
                    cur = int(m.group(1))
                attempt_text[cur].append(line)
    if not all_events:
        print("no events in log, skip")
        return

    ts0 = parse_ts(all_events[0]["ts"])
    tsN = parse_ts(all_events[-1]["ts"])

    ensure_schema()

    # per-attempt rows
    attempt_rows = []
    parsed = {}
    for n in sorted(attempt_events):
        evs = attempt_events[n]
        if not evs:
            continue
        rr, iter_start, iter_end, tools_in_iter, usages, _ = parse_attempt(evs)
        u, model, status = usage_of(rr, usages)
        s, e = parse_ts(evs[0]["ts"]), parse_ts(evs[-1]["ts"])
        err = "" if status == "completed" else classify_error(error_text(evs, attempt_text.get(n, [])))
        parsed[n] = (rr, iter_start, iter_end, tools_in_iter, usages)
        attempt_rows.append({
            "run_id": run_id, "attempt": n, "ts_start": fmt(s), "ts_end": fmt(e),
            "duration_ms": max(0, int((e - s).total_seconds() * 1000)),
            "iterations": max(iter_start) if iter_start else 0,
            "input_tokens": u.get("inputTokens", 0), "output_tokens": u.get("outputTokens", 0),
            "cache_read_tokens": u.get("cacheReadTokens", 0), "cache_write_tokens": u.get("cacheWriteTokens", 0),
            "cost": u.get("totalCost", 0), "status": status, "error_kind": err,
        })

    # run-level row from the LAST attempt (the decisive one)
    last = max(parsed) if parsed else 1
    rr, iter_start, iter_end, tools_in_iter, usages = parsed.get(last, (None, {}, {}, {}, []))
    u, model, status = usage_of(rr, usages)
    if rr and rr.get("durationMs"):
        duration_ms = rr["durationMs"]
    else:
        duration_ms = int((tsN - ts0).total_seconds() * 1000)
    error_kind = next((r["error_kind"] for r in reversed(attempt_rows) if r["error_kind"]), "") \
        if status != "completed" else ""

    # iterations: parsed per attempt, then renumbered sequentially across
    # attempts (each cline invocation restarts iteration numbering, which
    # would otherwise cross-match start/end timestamps between attempts)
    iter_rows = []
    total_iters = 0
    for n in sorted(parsed):
        rr, iter_start, iter_end, tools_in_iter, usages = parsed[n]
        ui = 0
        for k in sorted(iter_start):
            s = iter_start[k]
            e, tcc = iter_end.get(k, (None, 0))
            dur = max(0, int((e - s).total_seconds() * 1000)) if e else 0
            urow = {}
            while ui < len(usages) and usages[ui][0] <= (e or s):
                if usages[ui][0] >= s:
                    urow = usages[ui][1]
                ui += 1
            total_iters += 1
            iter_rows.append({
                "run_id": run_id, "iteration": total_iters, "ts_start": fmt(s), "duration_ms": dur,
                "input_tokens": urow.get("inputTokens", 0), "output_tokens": urow.get("outputTokens", 0),
                "cache_read_tokens": urow.get("cacheReadTokens", 0),
                "cache_write_tokens": urow.get("cacheWriteTokens", 0),
                "cost": urow.get("cost", 0), "tool_calls": tcc,
                "tool_names": tools_in_iter.get(k, []),
            })
    rr0, iter_start_all, _, _, _, phases = parse_attempt(all_events)
    iter_count = max(iter_start_all) if iter_start_all else len(iter_rows)
    # task_end: timestamp of the last event in the log (main task finish).
    phases["task_end"] = tsN
    phase_rows = [{"run_id": run_id, "phase": p, "ts": fmt(t),
                   "since_start_ms": int((t - ts0).total_seconds() * 1000)}
                  for p, t in sorted(phases.items(), key=lambda kv: kv[1])]

    run_row = {
        "run_id": run_id, "kind": kind, "log_file": log_path,
        "ts_start": fmt(ts0), "ts_end": fmt(tsN), "duration_ms": duration_ms,
        "iterations": iter_count,
        "attempt_count": len(attempt_rows) or 1,
        "error_kind": error_kind,
        "input_tokens": u.get("inputTokens", 0), "output_tokens": u.get("outputTokens", 0),
        "cache_read_tokens": u.get("cacheReadTokens", 0), "cache_write_tokens": u.get("cacheWriteTokens", 0),
        "total_cost": u.get("totalCost", 0), "model": model,
        "exit_code": exit_code, "status": status,
    }

    # idempotent rewrite of this run's rows
    for table in ("runs", "attempts", "iterations", "phases"):
        ch_query(f"DELETE FROM cline.{table} WHERE run_id = '{run_id}'")

    def insert(table, rows):
        if not rows:
            return
        body = "\n".join(json.dumps(r, ensure_ascii=False) for r in rows)
        ch_query(f"INSERT INTO cline.{table} FORMAT JSONEachRow", body)

    insert("runs", [run_row])
    insert("attempts", attempt_rows)
    insert("iterations", iter_rows)
    insert("phases", phase_rows)
    print(f"uploaded: run={run_id} kind={kind} attempts={run_row['attempt_count']} "
          f"iters={len(iter_rows)} phases={len(phase_rows)} duration_ms={duration_ms} "
          f"in_tok={run_row['input_tokens']} out_tok={run_row['output_tokens']} "
          f"status={status} err={error_kind or '-'}")


if __name__ == "__main__":
    main()
