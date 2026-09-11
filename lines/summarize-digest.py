#!/usr/bin/env python3
# summarize-digest.py — mechanically condense a cline run log into a compact
# digest (~1-2KB) for the summarizer prompt. Usage: summarize-digest.py <run.log>
import json
import re
import sys
from collections import defaultdict
from datetime import datetime


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def summarize_cmd(name, inp):
    try:
        if name == "run_commands":
            cmds = inp.get("commands") or []
            return (cmds[0] if cmds else "").replace("\n", " ")[:90]
        if name in ("editor", "read_files"):
            p = inp.get("path") or ""
            if not p and inp.get("files"):
                p = inp["files"][0].get("path", "")
            return p[-90:]
        return json.dumps(inp, ensure_ascii=False)[:90]
    except Exception:
        return ""


def main(path):
    first = last = None
    iters = 0
    compactions = 0
    tools = []
    open_tools = {}
    exit_rc = "?"
    done_text = ""
    errors = defaultdict(int)
    with open(path) as f:
        for line in f:
            if not line.startswith("{"):
                m = re.search(r"=== run finished .* exit=(\d+)", line)
                if m:
                    exit_rc = m.group(1)
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            t = ts(d["ts"])
            first = t if first is None else first
            last = t
            ev = d.get("event", {})
            et = ev.get("type")
            if et == "iteration_start":
                iters += 1
            elif et == "notice" and ev.get("reason") == "auto_compaction" and ev.get("metadata", {}).get("phase") == "started":
                compactions += 1
            elif et == "done":
                done_text = (ev.get("text") or "")[:500]
            elif et == "content_start" and ev.get("contentType") == "tool":
                open_tools[ev.get("toolCallId")] = (t, ev.get("toolName", "?"), summarize_cmd(ev.get("toolName", "?"), ev.get("input", {})))
            elif et == "content_end" and ev.get("contentType") == "tool":
                cid = ev.get("toolCallId")
                s, n, sm = open_tools.pop(cid, (None, None, None))
                if s:
                    tools.append((t - s, n, sm))
                    out = json.dumps(ev.get("output", {}), ensure_ascii=False)
                    for m in re.finditer(r"(?i)(error|failed|not found|denied|timeout)[^\"]{0,60}", out):
                        errors[m.group(0)[:70]] += 1

    dur = (last - first) / 60 if first else 0
    print(f"run_duration_min={dur:.0f} iterations={iters} exit={exit_rc} auto_compactions={compactions}")
    agg = defaultdict(lambda: [0, 0.0])
    for d_, n, _ in tools:
        agg[n][0] += 1
        agg[n][1] += d_
    top = sorted(agg.items(), key=lambda x: -x[1][1])[:6]
    print("tools_by_time:", ", ".join(f"{n}x{c}/{s / 60:.1f}min" for n, (c, s) in top))
    print("slowest_calls:")
    for d_, n, sm in sorted(tools, key=lambda x: -x[0])[:8]:
        print(f"  {d_:6.1f}s {n} {sm}")
    if errors:
        print("top_errors:")
        for e, c in sorted(errors.items(), key=lambda x: -x[1])[:5]:
            print(f"  {c}x {e}")
    if done_text:
        print("final_summary:", done_text.replace("\n", " ")[:500])


if __name__ == "__main__":
    main(sys.argv[1])
