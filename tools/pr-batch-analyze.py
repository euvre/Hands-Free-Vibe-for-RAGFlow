#!/usr/bin/env python3
"""pr-batch-analyze.py — analyze pr-batch-stats.jsonl + stage run logs into a
per-stage, per-phase timing report for workflow optimization.

Phases are cut from the first event-line timestamp where a marker appears:
  boot     agent_start → first git fetch        (LLM boot, prompt, context)
  sync     fetch → rebase | comment gather      (branch sync / comment read)
  rebase   rebase start → conflict work         (rebase itself)
  work     conflict/edit markers → first test   (conflict resolve / code edits)
  verify   test → push/comment                  (tests, type-check)
  deliver  push/comment → end                   (push, reply, wrap-up)

Usage: pr-batch-analyze.py [stats.jsonl]  (default logs/pr-batch-stats.jsonl)
"""
import datetime
import json
import os
import statistics
import sys

DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # repo root (this file lives in tools/)
LOG_DIR = os.path.join(DIR, "logs")
STATS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(LOG_DIR, "pr-batch-stats.jsonl")

MARK = [
    ("fetch",   ("git fetch", "fetch origin")),
    ("rebase",  ("git rebase", "rebase origin/main")),
    ("work",    ("CONFLICT", "checkout -B")),
    ("verify",  ("build.sh --test", "type-check")),
    ("deliver", ("git push", "pr comment")),
]


def parse_ts(s):
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def phases(log_name, wall_start, wall_end):
    p = os.path.join(LOG_DIR, log_name)
    if not os.path.exists(p):
        return {}, 0
    first = {}
    dur = 0.0
    with open(p, errors="replace") as f:
        for line in f:
            if '"ts"' not in line:
                continue
            ts = parse_ts(line.split('"ts":"', 1)[1].split('"', 1)[0])
            if '"durationMs":' in line and '"run_result"' in line:
                try:
                    dur = int(line.split('"durationMs":', 1)[1].split(",", 1)[0]) / 1000.0
                except Exception:
                    pass
            if ts is None:
                continue
            # markers must come from REAL tool calls only: the echoed prompt and
            # reasoning text also contain "git push" etc. and would smear the
            # phase boundaries onto the first iteration. Tool calls in this log
            # format look like: "toolName":"run_commands","input":{"commands":["…"]
            if '"input":{"commands"' not in line:
                continue
            for ph, marks in MARK:
                if ph not in first and any(m in line for m in marks):
                    first[ph] = ts
    seg = {}
    names = [n for n, _ in MARK]
    bounds = [wall_start] + [first[n] for n in names if n in first] + [wall_end]
    seg_names = ["boot"] + names
    for i in range(len(bounds) - 1):
        if bounds[i + 1] > bounds[i]:
            seg[seg_names[i]] = round(bounds[i + 1] - bounds[i], 1)
    return seg, dur


def main():
    rows = [json.loads(l) for l in open(STATS) if l.strip()]
    print("%6s %-7s %6s %6s %4s %5s  phases(s)" % ("PR", "stage", "wall", "llm_s", "it", "exit"))
    segs_all = {"rebase": [], "review": []}
    for r in rows:
        log_name = r.get("log") or ""
        seg, dur = phases(log_name, r["start"], r["end"]) if log_name else ({}, 0)
        ph = " ".join("%s=%ds" % (k, v) for k, v in seg.items())
        it = r.get("iterations")
        print("%6d %-7s %6d %6s %4s %5d  %s" % (
            r["pr"], r["stage"], r["duration_s"],
            int(r["llm_duration_ms"] / 1000) if r.get("llm_duration_ms") else "-",
            it if it else "-", r["exit"], ph or "-"))
        segs_all.setdefault(r["stage"], []).append((r, seg))

    print()
    for stage, items in segs_all.items():
        if not items:
            continue
        ds = [r["duration_s"] for r, _ in items]
        fast = [r for r, _ in items if r["duration_s"] <= 180]
        print("%s: n=%d total=%ds mean=%.0fs median=%.0fs max=%ds "
              "early-exit(<=3min)=%d (%.0f%%) wasted_on_fast=%ds" % (
                  stage, len(ds), sum(ds), statistics.mean(ds), statistics.median(ds),
                  max(ds), len(fast), 100 * len(fast) / len(ds),
                  sum(r["duration_s"] for r in fast)))
        # aggregate phase share for slow (real-work) runs
        agg = {}
        for r, seg in items:
            if r["duration_s"] <= 180:
                continue
            for k, v in seg.items():
                agg[k] = agg.get(k, 0) + v
        tot = sum(agg.values())
        if tot:
            print("  slow-run phase shares: " + "  ".join(
                "%s=%.0f%%" % (k, 100 * v / tot) for k, v in sorted(agg.items(), key=lambda x: -x[1])))


if __name__ == "__main__":
    main()
