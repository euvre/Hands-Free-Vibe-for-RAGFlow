#!/usr/bin/env python3
"""build-header.py — render the per-run task header injected into the issue
prompt. Reads issues/current.json (task_id/task_kind/parent_task_id plus the
resume/follow context staged by issue-select.sh) and fills the templates in
task-templates/:

  header.md.tmpl    shared lines (task number, kind, parent, prev-run log)
  resume.md.tmpl    extra guidance for kind=resume
  follow.md.tmpl    extra guidance for kind=follow

Templates use {placeholders}; values are str.format-mapped from a context
dict. Absent optional fields render as empty strings — the builder never
raises on missing data (an unnumbered run simply renders minimal lines).
"""
import json
import os
import sys

DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(DIR))  # repo root, for hfv_source
from hfv_source import is_gh


def load(name):
    p = os.path.join(DIR, name)
    if os.path.exists(p):
        return open(p).read()
    return ""


def main():
    d = json.load(open(sys.argv[1]))
    kind = d.get("task_kind") or "new"
    tid = d.get("task_id")
    parent = d.get("parent_task_id") or 0
    prev = d.get("prev_run") or {}
    fu = d.get("followup") or {}

    ctx = {
        "task_id": str(tid if tid is not None else "?"),
        "kind": kind,
        "parent": str(parent or 0),
        "parent_hint": (", based on task #%d" % parent) if parent else "",
        "prev_log": prev.get("log_file") or "",
        "prev_status": prev.get("status") or "?",
        "prev_exit": "?" if prev.get("exit_code") is None else str(prev["exit_code"]),
        "pr": fu.get("pr") or ("tasks/%s/ 目录" % parent if parent else "（缺失）"),
        "pr_body": (fu.get("pr_body") or "")[:2000],
        "new_replies": "\n".join(
            "- [%s] %s" % (rp.get("sender_type") or "?", rp.get("text") or "")
            for rp in (fu.get("new_replies") or [])),
        "parent_dir": str(parent or 0),
    }

    lines = [load("header.md.tmpl").format(**ctx).rstrip()]
    # Source-specific block: a github record (source=github, message_id
    # gh-<number>) carries the GitHub-issue overrides (English reply, no
    # local screenshots, Fixes #N) — rendered right after the shared header
    # so it lands above the task file's Feishu-specific defaults.
    if (d.get("source") or "feishu") == "github":
        gctx = dict(ctx)
        mid = d.get("message_id", "")
        num = d.get("number") or (mid[3:] if is_gh(mid) else "?")
        gctx["number"] = str(num)
        gctx["url"] = d.get("url") or ""
        # repo root so the template can point at helper scripts by absolute
        # path (the __HFV_DIR__ sed pass in run-task.sh only rewrites
        # task.md, not this header)
        gctx["hfv_dir"] = os.path.abspath(os.path.join(DIR, ".."))
        lines.append(load("github.md.tmpl").format(**gctx).rstrip())
    extra = load("%s.md.tmpl" % kind)
    if extra:
        lines.append(extra.format(**ctx).rstrip())
    # golden lessons: high hit-rate rules solidified by playbook-effect.py —
    # injected here so every task run (main/feat) carries them in-prompt.
    gp = os.path.join(DIR, "..", "playbook-golden.md")
    if os.path.exists(gp):
        golden = open(gp).read().strip()
        if golden:
            lines.append(golden)
    print("\n".join(x for x in lines if x.strip()))


if __name__ == "__main__":
    main()
