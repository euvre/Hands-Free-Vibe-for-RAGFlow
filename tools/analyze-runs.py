#!/usr/bin/env python3
"""Analyze cline daemon run logs: where did the time go?"""
import json
import glob
import os
from datetime import datetime

MILESTONES = [
    ("select", lambda t, c: t in ("lark-mcp__im_v1_chat_search", "lark-mcp__im_v1_chat_list")),
    ("claim", lambda t, c: t == "lark-mcp__im_v1_message_reply"),
    ("browser", lambda t, c: t.startswith("chrome-devtools__")),
    ("edit", lambda t, c: t == "editor"),
    ("go_test", lambda t, c: t == "run_commands" and "build.sh --test" in c),
    ("branch", lambda t, c: t == "run_commands" and "git checkout -b" in c),
    ("push", lambda t, c: t == "run_commands" and "git push" in c),
    ("pr", lambda t, c: t == "run_commands" and "gh pr create" in c),
    ("sheet", lambda t, c: t == "run_commands" and "sheets/v2" in c),
]


def ts(obj):
    return datetime.fromisoformat(obj["ts"].replace("Z", "+00:00")).timestamp()


def analyze(path):
    events = []
    for line in open(path, errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("type") == "agent_event":
            events.append(obj)
    if not events:
        return None
    t0, tN = ts(events[0]), ts(events[-1])

    marks = {}
    tool_calls = []  # (ts, name, cmd)
    for obj in events:
        ev = obj.get("event", {})
        if ev.get("type") == "content_start" and ev.get("contentType") == "tool":
            name = ev.get("toolName", "")
            cmd = ""
            if name == "run_commands":
                cmd = " ".join(map(str, (ev.get("input") or {}).get("commands") or []))
            tool_calls.append((ts(obj), name, cmd))
            for ph, rule in MILESTONES:
                if ph not in marks and rule(name, cmd):
                    marks[ph] = ts(obj)

    # phase durations: milestone -> next milestone (or end)
    order = ["select", "claim", "browser", "edit", "go_test", "branch", "push", "pr", "sheet"]
    hits = [(m, marks[m]) for m in order if m in marks]
    hits.sort(key=lambda x: x[1])
    phases = []
    for i, (m, t) in enumerate(hits):
        end = hits[i + 1][1] if i + 1 < len(hits) else tN
        phases.append((m, end - t))

    # gap analysis between consecutive tool calls
    gaps = []
    for i in range(1, len(tool_calls)):
        gaps.append((tool_calls[i][0] - tool_calls[i - 1][0], tool_calls[i - 1][1], tool_calls[i][1]))
    gaps.sort(reverse=True)

    # tool call counts
    counts = {}
    for _, name, _ in tool_calls:
        counts[name] = counts.get(name, 0) + 1

    return {
        "run": os.path.basename(path), "duration_s": tN - t0, "tool_calls": len(tool_calls),
        "phases": phases, "top_gaps": gaps[:5], "counts": counts,
    }


for path in sorted(glob.glob("/home/inf/hands-free-vibe/logs/run-*.log")):
    r = analyze(path)
    if not r:
        continue
    print(f"\n=== {r['run']}  总时长 {r['duration_s'] / 60:.1f} 分钟, {r['tool_calls']} 次工具调用 ===")
    print(" 阶段耗时(里程碑到下一里程碑):")
    for m, d in r["phases"]:
        print(f"   {m:<10} {d / 60:5.1f} min")
    print(" 最大时间间隙 top5:")
    for g, a, b in r["top_gaps"]:
        print(f"   {g:6.1f}s  {a} -> {b}")
    top = sorted(r["counts"].items(), key=lambda x: -x[1])[:6]
    print(" 工具调用次数:", ", ".join(f"{k}×{v}" for k, v in top))
