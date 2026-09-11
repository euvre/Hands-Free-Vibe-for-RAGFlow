#!/usr/bin/env python3
"""summarize-tree.py — tournament-merge lesson engine (2026-08-21).

Spec: every task yields 4 lessons (leaves). Nodes are grouped by index mod 4
(stride): {0,4,8,12} {1,5,9,13} {2,6,10} {3,7,11} …; each group merges to 4
lessons; repeat upward until ≤16 lessons remain — the final experience set.
Merge nodes are persisted by content hash (summarize/nodes/), so unchanged
subtrees cost ZERO LLM calls on later sweeps — only the branch touched by a
new task is recomputed.

A stats table (summarize/stats.json) tracks per lesson:
  - hit-rate: hits/opps, where opps counts sweep participations (as a leaf
    input or a theme match) and hits counts making the final set (directly or
    via close paraphrase). Theme recurrence (a later task independently
    re-deriving the same rule) bumps BOTH — the strongest relevance signal.
  - affinity: co-occurrence counts inside merge groups + text similarity.
High-streak lessons are solidified by playbook-effect.py into
playbook-golden.md, which build-header.py injects into every task prompt.
High affinity (sim ≥ FUSE_SIM and co-occurrence ≥ FUSE_COOCC) → the pair is
fused into one lesson by one LLM call.

LLM calls go through the cline CLI with output redirected to a FILE (never a
pipe — grandchildren inherit pipes and wedge the caller, observed 2026-08-21).
TREE_FAKE_LLM=1 swaps in a deterministic stub for tests.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time

DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # repo root (this file lives in lines/)
sys.path.insert(0, DIR)
from hfv_config import load as _load_hfv  # noqa: E402
_HFV = _load_hfv()

STATE = os.path.join(DIR, "summarize")
LEAVES = os.path.join(STATE, "leaves")   # leaves/<task-key>.json {"lessons":[…≤4]}
NODES = os.path.join(STATE, "nodes")     # nodes/<content-hash>.json {"lessons":[4]}
STATS_F = os.path.join(STATE, "stats.json")
PLAYBOOK = os.path.join(DIR, "playbook.md")
SECTION_HEADER = "## Rolling additions (tree-merged auto-summary, final 16)"
OLD_SECTION_HEADERS = ("## 滚动补充（自动总结，保留最近 12 条）",
                       "## 滚动补充（树归并自动总结，最终16条）")

PER_TASK = int(_HFV["LESSONS_PER_TASK"])
FINAL = int(_HFV["TREE_FINAL_COUNT"])
FAN = 4                      # merge fan-in: 4 nodes -> 1 node (the spec's stride)
MATCH_SIM = 0.45             # theme match: "same lesson, other words"
SURVIVE_SIM = 0.60           # paraphrase close enough to count as survival
FUSE_SIM = float(_HFV["FUSE_SIM"])
FUSE_COOCC = int(_HFV["FUSE_COOCC"])

STOP = set(("的 了 和 是 都 与 及 或 不 要 用 在 对 先 后 再 最 需 可 应 禁 勿 "
            "把 被 让 从 到 由 于 以 并 且 之 其 这 那 有 无 未 已 时 中 上 下 "
            "a an the to of and or not no in on for with without never always "
            "do dont if when then than").split())


def norm(t):
    t = re.sub(r"https?://\S+|`[^`]*`", " ", t or "")
    toks = re.findall(r"[a-z0-9_]{2,}|[\u4e00-\u9fff]", t.lower())
    return {w for w in toks if w not in STOP}


def sim(a, b):
    A, B = norm(a), norm(b)
    return len(A & B) / len(A | B) if A and B else 0.0


def lid(text):
    return "L" + hashlib.sha1(" ".join(sorted(norm(text))).encode()).hexdigest()[:10]


def h16(texts):
    return hashlib.sha1("\x00".join(sorted(texts)).encode()).hexdigest()[:16]


# --------------------------------------------------------------------- LLM
CLINE = _HFV["CLINE_BIN"]
FAKE = os.environ.get("TREE_FAKE_LLM") == "1"


def _model_args():
    rc = subprocess.run(["python3", os.path.join(DIR, "tools", "model-profile.py"), "args"],
                        capture_output=True, text=True)
    return rc.stdout.split() if rc.returncode == 0 else []


def fake_llm(prompt):
    """Deterministic test double: dedupe the candidate '- ' lines, cap at 4.
    Merge candidates live after the "Lessons:" marker; fuse candidates are the
    last two '- ' lines (the instruction bullets must never be echoed)."""
    lines = prompt.splitlines()
    if "Lessons:" in prompt:
        idx = next(i for i, l in enumerate(lines) if "Lessons:" in l)
        lines = lines[idx + 1:]
    seen, out = set(), []
    for l in lines:
        if not l.strip().startswith("- "):
            continue
        c = l.strip()[2:].strip()
        k = " ".join(sorted(norm(c)))
        if k and k not in seen:
            seen.add(k)
            out.append(c)
        if len(out) == PER_TASK:
            break
    return "\n".join("- " + c for c in out) or "NONE"


def llm(prompt, tag):
    timeout = int(_HFV["SUMMARIZE_SECONDS"])
    if FAKE:
        return fake_llm(prompt)
    log = os.path.join(STATE, "llm-%s-%d.log" % (tag, int(time.time() * 1000)))
    args = [CLINE, "--json", "--cwd", DIR, "-t", str(timeout),
            "--auto-approve", "true"] + _model_args() + [prompt]
    try:
        with open(log, "w") as fh:
            subprocess.run(["timeout", str(timeout + 60)] + args,
                           stdout=fh, stderr=fh, timeout=timeout + 90)
    except Exception:
        return ""
    done, texts = "", []
    for line in open(log, errors="ignore"):
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        ev = d.get("event", {})
        if ev.get("type") == "done":
            done = ev.get("text") or ""
        elif ev.get("type") == "content_start" and ev.get("contentType") == "text":
            texts.append(ev.get("text", ""))
    return done or "".join(texts)


def parse_lessons(text):
    out = []
    for l in (text or "").splitlines():
        l = re.sub(r"^\s*[-*•]+\s*|^\s*\d+[.)]\s*", "", l.strip())
        if not l or l.startswith(("#", "`", "：", ":")) or l.upper() == "NONE":
            continue
        # a non-compliant merger sometimes echoes its clustering pass as label
        # lines ("Cluster 1 — backgrounding:", "Theme: retries", …): drop them
        if re.match(r"(?i)^(cluster|theme|group)\b", l) and len(l) < 60:
            continue
        out.append(l[:120])
    return out


# ------------------------------------------------------------------ leaves
def load_leaves():
    """All leaf lesson-sets, ordered numerically by task key (task-0, task-1…)."""
    items = []
    if not os.path.isdir(LEAVES):
        return items
    for f in sorted(os.listdir(LEAVES)):
        if not f.endswith(".json"):
            continue
        try:
            d = json.load(open(os.path.join(LEAVES, f)))
        except Exception:
            continue
        ls = [x.strip() for x in (d.get("lessons") or []) if x and x.strip()][:PER_TASK]
        if ls:
            items.append((f[:-5], ls))

    def key(it):
        m = re.search(r"\d+", it[0])
        return int(m.group()) if m else 1 << 30
    return [ls for _, ls in sorted(items, key=key)]


def seed_legacy_leaf():
    """First run only: fold the pre-tree rolling section into a virtual leaf
    so existing hard-won rules enter the tournament instead of vanishing."""
    if os.path.isdir(LEAVES) and os.listdir(LEAVES):
        return
    try:
        lines = open(PLAYBOOK).read().splitlines()
        idx = next(i for i, l in enumerate(lines) if l in OLD_SECTION_HEADERS)
    except Exception:
        return
    rules = [l[2:].strip() for l in lines[idx + 1:] if l.startswith("- ")]
    if rules:
        os.makedirs(LEAVES, exist_ok=True)
        json.dump({"lessons": rules[:PER_TASK]},
                  open(os.path.join(LEAVES, "legacy.json"), "w"), ensure_ascii=False)


# ------------------------------------------------------------------- tree
MERGE_PROMPT = """You are a lesson merger. Below are lessons from automated task runs (one per line).

Work in two explicit passes (silently — the output must contain ONLY the final rule lines):
1. CLUSTER: group the lessons by their underlying theme. Several input lessons are usually near-verbatim paraphrases of one rule (e.g. every variant of "background long commands + poll logs" or "check quota + checkpoint progress") — they belong to ONE cluster.
2. SELECT: emit ONE canonical rule per cluster, in its broadest actionable form. NEVER keep multiple phrasings of the same idea — a cluster yields exactly one rule.

Hard output contract:
- At most %d rules total; one per line, imperative mood, ≤25 words, prefixed with "- ".
- NO case information (run numbers, PR numbers, dates, names, file paths).
- Rules MUST be in English. Output only rule lines — no titles, no cluster labels, no explanations.

Lessons:
%s"""


def merge_node(texts):
    """One merge node: ≤N input lessons -> PER_TASK output lessons, cached by
    content hash so unchanged subtrees never re-call the LLM."""
    key = h16(texts)
    nf = os.path.join(NODES, key + ".json")
    if os.path.exists(nf):
        try:
            return json.load(open(nf))["lessons"]
        except Exception:
            pass
    out = parse_lessons(llm(MERGE_PROMPT % (PER_TASK, "\n".join("- " + t for t in texts)),
                            "merge"))[:PER_TASK]
    if not out:
        # LLM failure: deterministic fallback keeps the tree moving
        seen, out = set(), []
        for t in texts:
            k = " ".join(sorted(norm(t)))
            if k not in seen:
                seen.add(k)
                out.append(t)
            if len(out) == PER_TASK:
                break
    json.dump({"lessons": out}, open(nf, "w"), ensure_ascii=False)
    return out


def build_tree(leaves):
    """Tournament: stride-4 groups merged upward until ≤FINAL lessons remain.
    14 tasks -> groups {0,4,8,12} {1,5,9,13} {2,6,10} {3,7,11} -> 4 nodes = 16.
    """
    nodes = [node[:] for node in leaves]
    while len(nodes) * PER_TASK > FINAL and len(nodes) > 1:
        groups = [nodes[i::FAN] for i in range(FAN)]
        nodes = [merge_node([t for node in g for t in node]) for g in groups if g]
    return [t for node in nodes for t in node][:FINAL]


# ------------------------------------------------------------------ stats
def load_stats():
    if os.path.exists(STATS_F):
        try:
            return json.load(open(STATS_F))
        except Exception:
            pass
    return {"lessons": {}, "cooccur": {}}


def _bump(st, i, field, n=1):
    e = st["lessons"].setdefault(i, {"hits": 0, "opps": 0, "text": ""})
    e[field] += n


def update_stats(st, leaves, final):
    leaf_texts = [t for node in leaves for t in node]
    final_ids = {lid(t) for t in final}
    # register + participation + final presence
    for t in leaf_texts + final:
        i = lid(t)
        st["lessons"].setdefault(i, {"hits": 0, "opps": 0, "text": t})
        st["lessons"][i]["text"] = t
    for t in leaf_texts:
        _bump(st, lid(t), "opps")
    for t in final:
        _bump(st, lid(t), "hits")
    # survival via paraphrase: a final lesson phrased differently credits its
    # closest leaf ancestor with a hit
    leaf_ids = {lid(t) for t in leaf_texts}
    for ft in final:
        if lid(ft) in leaf_ids:
            continue
        best, bid = 0.0, None
        for t in leaf_texts:
            s = sim(ft, t)
            if s > best:
                best, bid = s, lid(t)
        if best >= SURVIVE_SIM and bid:
            _bump(st, bid, "hits")
    # theme recurrence (bounded): an OLD lesson NOT in this pass's leaf pool
    # that a fresh leaf independently re-derives gets ONE opp+hit per pass —
    # a genuine "this rule proved right again" event, capped so that broadly
    # similar lesson sets cannot inflate every rate toward 1.0 (observed in
    # testing: unbounded recurrence made everything golden instantly).
    leaf_pool = {lid(t) for t in leaf_texts}
    for i_old, e in st["lessons"].items():
        if i_old in leaf_pool or not e.get("text"):
            continue
        for t in leaf_texts:
            if sim(t, e["text"]) >= MATCH_SIM:
                _bump(st, i_old, "opps")
                _bump(st, i_old, "hits")
                break
    # co-occurrence: same task leaf-set and same final set
    for g in leaves + [final]:
        ids = sorted({lid(t) for t in g})
        for a in range(len(ids)):
            for b in range(a + 1, len(ids)):
                k = ids[a] + "+" + ids[b]
                st["cooccur"][k] = st["cooccur"].get(k, 0) + 1


# ------------------------------------------------------------------ fusion
FUSE_PROMPT = """Fuse the following two lessons into ONE broader imperative rule, still ≤25 words, in English.
Output exactly one line starting with "- ", nothing else.
- %s
- %s"""


def fuse_pass(st, final):
    """Highest-affinity pair in the final set crosses the bar → fuse via LLM.
    At most one fusion per sweep keeps the final set stable."""
    best = (0.0, -1, -1)
    for i in range(len(final)):
        for j in range(i + 1, len(final)):
            a, b = lid(final[i]), lid(final[j])
            co = st["cooccur"].get(a + "+" + b, 0) + st["cooccur"].get(b + "+" + a, 0)
            s = sim(final[i], final[j])
            if s >= FUSE_SIM and co >= FUSE_COOCC and co + s > best[0]:
                best = (co + s, i, j)
    i, j = best[1], best[2]
    if i < 0:
        return final
    fused = parse_lessons(llm(FUSE_PROMPT % (final[i], final[j]), "fuse"))
    if not fused:
        return final
    fi, fj, fk = lid(final[i]), lid(final[j]), lid(fused[0])
    e = st["lessons"].setdefault(fk, {"hits": 0, "opps": 0, "text": fused[0]})
    e["hits"] = st["lessons"][fi]["hits"] + st["lessons"][fj]["hits"]
    e["opps"] = st["lessons"][fi]["opps"] + st["lessons"][fj]["opps"]
    st["lessons"][fi]["fused_into"] = fk
    st["lessons"][fj]["fused_into"] = fk
    out = [final[k] for k in range(len(final)) if k not in (i, j)]
    out.append(fused[0])
    return out


# ------------------------------------------------------------------ outputs
# (none — both output channels live in playbook-effect.py: the rolling section
# is the eight-houses view, and golden solidification is streak-based)


# --------------------------------------------------------------------- main
def main():
    os.makedirs(LEAVES, exist_ok=True)
    os.makedirs(NODES, exist_ok=True)
    seed_legacy_leaf()
    leaves = load_leaves()
    if not leaves:
        print("tree: no leaves yet")
        return 0
    final = build_tree(leaves)
    st = load_stats()
    update_stats(st, leaves, final)
    final = fuse_pass(st, final)
    # Rolling-section AND golden ownership both live in playbook-effect.py now
    # (eight houses, effect-weighted; streak-based solidification). The tree
    # keeps only stats maintenance; the hit-rate golden channel is retired.
    json.dump(st, open(STATS_F, "w"), ensure_ascii=False, indent=1)
    print("tree: %d leaves -> %d final; nodes_cached=%d"
          % (len(leaves), len(final), len(os.listdir(NODES))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
    for t in leaf_texts:
        i_new = lid(t)
        for i_old, e in st["lessons"].items():
            if i_old == i_new or not e.get("text"):
                continue
            if sim(t, e["text"]) >= MATCH_SIM:
                _bump(st, i_old, "opps")
                _bump(st, i_old, "hits")
    # co-occurrence: same task leaf-set and same final set
    for g in leaves + [final]:
        ids = sorted({lid(t) for t in g})
        for a in range(len(ids)):
            for b in range(a + 1, len(ids)):
                k = ids[a] + "+" + ids[b]
                st["cooccur"][k] = st["cooccur"].get(k, 0) + 1
