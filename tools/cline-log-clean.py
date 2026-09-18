#!/usr/bin/env python3
"""cline-log-clean.py — render cline's --json run log as per-iteration complete
blocks, for `hfv follow <line> --clean`.

The raw stream emits token-level content_start fragments; this filter prints
only assembled units: an iteration separator, then the iteration's FULL text,
reasoning and tool-call summaries (from content_end events), plus run results
and errors. Non-JSON run markers ("=== ... ===") pass through as separators.

Usage: tail -f run-*.log | cline-log-clean.py
"""
import json
import sys

TOOL_OUTPUT_HEAD = 400  # chars of a tool result worth showing


def emit(s=""):
    print(s, flush=True)


def main():
    for raw in sys.stdin:
        line = raw.rstrip("\n")
        if not line.startswith("{"):
            if line.startswith("==="):
                emit("\n" + line)
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        t = d.get("type")
        if t == "agent_event":
            e = d.get("event") or {}
            et = e.get("type")
            if et == "iteration_start":
                emit("\n━━━ iteration %s ━━━" % e.get("iteration", "?"))
            elif et == "content_end":
                ct = e.get("contentType")
                if ct == "text":
                    emit("\n" + (e.get("text") or ""))
                elif ct == "reasoning":
                    r = (e.get("reasoning") or "").strip()
                    if r:
                        emit("\n[思考] " + r)
                elif ct == "tool":
                    out = e.get("output")
                    if not isinstance(out, str):
                        out = json.dumps(out, ensure_ascii=False) if out else ""
                    out = out.strip().replace("\n", " ⏎ ")
                    if len(out) > TOOL_OUTPUT_HEAD:
                        out = out[:TOOL_OUTPUT_HEAD] + " …"
                    emit("\n[tool] %s → %s" % (e.get("toolName", "?"), out or "(no output)"))
            elif et == "error":
                emit("\n[ERROR] %s" % str(e.get("error") or e)[:500])
        elif t == "run_result":
            u = d.get("aggregateUsage") or {}
            emit("\n═══ run %s — iterations=%s in=%s out=%s ═══"
                 % (d.get("finishReason"), d.get("iterations"),
                    u.get("totalInputTokens"), u.get("totalOutputTokens")))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass  # Ctrl-C on hfv follow --clean: exit quietly, no traceback
    except BrokenPipeError:
        sys.stdout.close()  # downstream closed (e.g. | head)
