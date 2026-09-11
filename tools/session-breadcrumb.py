#!/usr/bin/env python3
"""session-breadcrumb.py — digest a cline session file into a continuation
breadcrumb for cold-retry prompts.

Why this exists: the CLI's --id resume is unusable in one-shot JSON mode
(3.0.57 force-sets interactive and drops the prompt), so run-task.sh retries
cold and injects this digest so the agent continues instead of restarting
from zero. See run-task.sh "attempt continuity".

Usage: session-breadcrumb.py <session.messages.json> [char_cap=1600]
Prints nothing (empty string) when the session did too little to be worth
continuing — the caller then falls back to a plain cold start.
"""
import json
import re
import sys


def main():
    path = sys.argv[1]
    cap = int(sys.argv[2]) if len(sys.argv) > 2 else 1600
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        return  # unreadable session: no breadcrumb, plain cold start
    msgs = data.get("messages", []) if isinstance(data, dict) else data
    if not isinstance(msgs, list):
        return

    # last assistant text notes (newest last)
    asst_texts = []
    for m in msgs:
        if not isinstance(m, dict) or m.get("role") != "assistant":
            continue
        for part in (m.get("content") or []):
            if isinstance(part, dict) and part.get("type") == "text":
                t = (part.get("text") or "").strip()
                if t:
                    asst_texts.append(t)
    if not asst_texts:
        return  # the attempt produced no reasoning at all — cold is fine

    # files touched, from tool-call params in the raw JSON (schema-agnostic)
    try:
        raw = open(path, errors="replace").read()
    except Exception:
        raw = ""
    paths = []
    for p in re.findall(r'"path"\s*:\s*"([^"]{3,200})"', raw):
        if p.startswith("/") and p not in paths:
            paths.append(p)
    paths = paths[:12]

    lines = ["Last assistant notes from the interrupted attempt (oldest→newest, may be truncated):"]
    for t in asst_texts[-3:]:
        t = re.sub(r"\s+", " ", t)
        lines.append("- " + (t[:450] + " …" if len(t) > 450 else t))
    if paths:
        lines.append("Files the interrupted attempt touched (order of first touch, deduped): " + ", ".join(paths))
    out = "\n".join(lines)
    print(out[:cap])


if __name__ == "__main__":
    main()
