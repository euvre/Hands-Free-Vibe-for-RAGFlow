#!/usr/bin/env python3
"""playbook-effect.py — the eight-houses effect engine (2026-09-11).

Replaces text-popularity (hit rate) with an outcome metric: ITERATIONS SAVED.

Houses (planet order = iteration order): 水 Mercury < 金 Venus < 地 Earth <
火 Mars < 木 Jupiter < 土 Saturn < 天 Uranus < 海 Neptune. Recent glm-5.3
issue runs (iterations >= MIN_ITERS, i.e. real work) are sorted by iteration
count and split into eight equal-frequency houses; the 7 bounds are
EMA-smoothed across sweeps. House weight w_g = its share of total iterations
(load).

Per lesson e and house g:
    effect(e, g) = median(iters of house-g runs BEFORE e first appeared)
                 − median(iters of house-g runs AFTER)
(positive = the lesson saves iterations inside that house; windows with
< MIN_SAMPLES runs are 'pending'). e lives in argmax_g effect(e, g); with
EMA-smoothed bounds and single-peaked effects a rule can only move between
ADJACENT houses. Objective (the value to minimize, printed every sweep):

    V = Σ_g w_g · Σ_{e∈g} (−effect(e, g))     [≡ maximize iterations saved]

Cold start honesty: lessons without a real first_seen (paraphrased survivors
whose leaf text no longer matches) are stamped now — their 'before' window is
approximately clean only from that stamp onward; leaf-matched lessons get the
leaf file's real mtime. Golden stays hit-rate driven until at least one lesson
has a proven positive effect (no prompt-quality regression during the
accumulation window); the playbook rolling section switches to the houses view
immediately. ClickHouse unreachable → exit quietly, playbook untouched.
"""
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from statistics import median

DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # repo root (lines/)
sys.path.insert(0, DIR)
from hfv_config import load as _load_hfv  # noqa: E402

_HFV = _load_hfv()
CH = _HFV.get("CLICKHOUSE_HTTP", "http://127.0.0.1:8123/")
STATE = os.path.join(DIR, "summarize")
STATS_F = os.path.join(STATE, "stats.json")
GROUPS_F = os.path.join(STATE, "groups.json")
LEAVES = os.path.join(STATE, "leaves")
PLAYBOOK = os.path.join(DIR, "playbook.md")
GOLDEN_F = os.path.join(DIR, "playbook-golden.md")

HOUSES = ["水", "金", "地", "火", "木", "土", "天", "海"]
PLANETS = ["Mercury", "Venus", "Earth", "Mars", "Jupiter", "Saturn", "Uranus", "Neptune"]
MIN_ITERS = 10      # resting/instant runs carry no workload signal
MIN_SAMPLES = 4     # per-window minimum for a median to mean anything
EMA_ALPHA = 0.3     # bound smoothing (adjacent-house-only movement)
MODEL = "glm-5.3"   # mixed-model history is not comparable; glm only

STOP = set(("a an the to of and or not no in on for with without never always "
            "do dont if when then than").split())


def atomic_json(obj, path):
    """tmp+rename — a crashed/concurrent write must never truncate the store
    (two parallel playbook-effect runs once produced a torn stats.json read:
    the loser's json.load failed, its empty fallback overwrote nothing here
    only by luck of timing)."""
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def norm(t):
    t = re.sub(r"https?://\S+|`[^`]*`", " ", t or "")
    return {w for w in re.findall(r"[a-z0-9_]{2,}", t.lower()) if w not in STOP}


def lid(text):
    import hashlib
    return "L" + hashlib.sha1(" ".join(sorted(norm(text))).encode()).hexdigest()[:10]


def ch(query):
    url = CH + "?query=" + urllib.parse.quote(query)
    req = urllib.request.Request(url, data=b"")
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode()


def load_runs():
    """(ts_start epoch, iterations) for real-work glm issue runs, oldest first."""
    out = ch("SELECT toUnixTimestamp(ts_start), iterations FROM cline.runs "
             "WHERE model = '%s' AND kind = 'issue' AND iterations >= %d "
             "ORDER BY ts_start" % (MODEL, MIN_ITERS))
    runs = []
    for line in out.splitlines():
        ts, it = line.split("\t")
        runs.append((int(ts), int(it)))
    return runs


def compute_houses(runs):
    """Equal-frequency octile bounds, EMA-smoothed against the previous sweep."""
    iters = sorted(it for _, it in runs)
    n = len(iters)
    new_bounds = [iters[int(n * i / 8)] for i in range(1, 8)] if n >= 8 else None
    prev = None
    if os.path.exists(GROUPS_F):
        try:
            prev = json.load(open(GROUPS_F)).get("bounds")
        except Exception:
            prev = None
    if new_bounds is None:
        bounds = prev
    elif prev and len(prev) == 7:
        bounds = [round(EMA_ALPHA * b + (1 - EMA_ALPHA) * p) for b, p in zip(new_bounds, prev)]
    else:
        bounds = new_bounds
    if bounds is None:
        return None
    houses = [[] for _ in range(8)]
    for ts, it in runs:
        h = sum(1 for b in bounds if it >= b)   # it >= bounds[i] → house i+1
        houses[h].append((ts, it))
    total = sum(it for _, it in runs) or 1
    weights = [sum(it for _, it in h) / total for h in houses]
    return {"bounds": bounds, "houses": houses, "weights": weights,
            "runs": n, "updated_at": int(time.time())}


def stamp_first_seen(st):
    """Backfill first_seen for every lesson: the owning leaf's real mtime when
    its text still matches, else 'now' (its paraphrase first showed up today —
    its effect becomes measurable from here). Returns True if stats changed."""
    leaf_seen = {}
    if os.path.isdir(LEAVES):
        for f in os.listdir(LEAVES):
            if not f.endswith(".json"):
                continue
            p = os.path.join(LEAVES, f)
            try:
                d = json.load(open(p))
            except Exception:
                continue
            mt = int(os.path.getmtime(p))
            for t in d.get("lessons") or []:
                i = lid(t)
                if i not in leaf_seen or mt < leaf_seen[i]:
                    leaf_seen[i] = mt
    now = int(time.time())
    changed = False
    for i, e in st.get("lessons", {}).items():
        if e.get("first_seen"):
            continue
        e["first_seen"] = leaf_seen.get(i, now)
        changed = True
    return changed


def effect_for(e, houses):
    """Per-house effect for one lesson; None where a window is too thin."""
    fs = e.get("first_seen")
    out = []
    for h in houses:
        before = [it for ts, it in h if fs and ts < fs]
        after = [it for ts, it in h if fs and ts >= fs]
        if len(before) < MIN_SAMPLES or len(after) < MIN_SAMPLES:
            out.append(None)
        else:
            out.append(median(before) - median(after))
    return out


def main():
    try:
        runs = load_runs()
    except Exception as ex:
        print("effect: ClickHouse unreachable (%s) — playbook untouched" % type(ex).__name__)
        return 0
    if len(runs) < 16:
        print("effect: only %d real-work runs — accumulate more" % len(runs))
        return 0
    try:
        st = json.load(open(STATS_F))
    except Exception:
        st = {"lessons": {}, "cooccur": {}}
    stamp_first_seen(st)
    atomic_json(st, STATS_F)

    H = compute_houses(runs)
    if not H:
        print("effect: not enough runs for houses yet")
        return 0
    atomic_json({"bounds": H["bounds"], "weights": H["weights"], "runs": H["runs"],
                 "updated_at": H["updated_at"]}, GROUPS_F)

    # per-lesson effects, house assignment, objective value
    rows = []          # (house, effect, text, effs, lid)
    V = 0.0
    for i, e in st["lessons"].items():
        if e.get("fused_into") or not e.get("text"):
            continue
        effs = effect_for(e, H["houses"])
        best_h, best_v = None, None
        for h, v in enumerate(effs):
            if v is not None and (best_v is None or v > best_v):
                best_h, best_v = h, v
        rows.append((best_h, best_v, e["text"], effs, i))
        if best_v is not None:
            V += H["weights"][best_h] * (-best_v)

    # streak bookkeeping: the best lesson inside each house extends its streak
    # ONLY when new runs arrived since the last sweep (an idle timer sweep must
    # not inflate a streak — "8 consecutive TASKS" means 8 real tasks).
    runs_changed = H["runs"] != st.get("last_runs_count")
    st["last_runs_count"] = H["runs"]
    if runs_changed:
        update_streaks(st, rows)
    golden_ids = manage_golden(st, rows)
    atomic_json(st, STATS_F)

    write_houses_section(rows, H, golden_ids)
    golden_n = emit_golden(st, rows)
    streaking = sum(1 for e in st["lessons"].values() if e.get("streak", 0) > 0)
    print("effect: %d runs, %d lessons, golden=%d (streaking=%d), objective V=%.2f "
          "(weights: %s)" % (H["runs"], len(rows), golden_n, streaking, V,
                             " ".join("%.0f%%" % (w * 100) for w in H["weights"])))
    return 0


THEME_DEDUP_SIM = 0.30   # empirical: same-theme paraphrase pairs sit at
                         # sim 0.30-0.42, cross-theme pairs max out at 0.08 —
                         # the gap in between makes 0.30 safe from false merges
STREAK_BAR = 8           # consecutive tasks being the house's best → solidify
GOLDEN_MAX = 8           # golden holds at most 8 lessons (one per house, max)


def dedupe_themes(pairs):
    """Greedy theme dedup over (effect, text) pairs sorted best-first: a lesson
    that is a near-paraphrase of an already-kept one is dropped. Without this,
    a strong theme's dozen phrasings occupy every slot in a house (and in
    golden), crowding out every other theme. The stats layer keeps ALL variants
    accumulating; only display/solidification dedupes."""
    kept = []
    for v, t in pairs:
        if any(_sim(t, kt) >= THEME_DEDUP_SIM for _, kt in kept):
            continue
        kept.append((v, t))
    return kept


def _sim(a, b):
    A, B = norm(a), norm(b)
    return len(A & B) / len(A | B) if A and B else 0.0


def update_streaks(st, rows):
    """Each house's current #1 (highest effect among its assigned lessons)
    extends its streak; everyone else's resets. A rule that MOVED houses
    restarts its streak in the new house."""
    by_house = {}
    for h, v, t, effs, i in rows:
        if h is not None and v is not None:
            by_house.setdefault(h, []).append((v, i))
    for h, cand in by_house.items():
        cand.sort(key=lambda x: -x[0])
        winner = cand[0][1]
        for v, i in cand:
            e = st["lessons"][i]
            if i == winner and e.get("streak_house") == h:
                e["streak"] = e.get("streak", 0) + 1
            elif i == winner:
                e["streak"], e["streak_house"] = 1, h
            else:
                e["streak"], e["streak_house"] = 0, h


def manage_golden(st, rows):
    """streak >= STREAK_BAR → solidify. Beyond GOLDEN_MAX, the member with the
    lowest CURRENT effect (ties: oldest solidification) is demoted back into
    the pool — golden_since=None, streak=0: it re-enters house assignment and
    display like any other lesson."""
    eff = {i: v for h, v, t, effs, i in rows}
    for i, e in st["lessons"].items():
        if e.get("fused_into") or not e.get("text"):
            continue
        if not e.get("golden_since") and e.get("streak", 0) >= STREAK_BAR:
            e["golden_since"] = int(time.time())
    members = [(i, e) for i, e in st["lessons"].items() if e.get("golden_since")]
    if len(members) > GOLDEN_MAX:
        members.sort(key=lambda ie: (eff.get(ie[0]) if eff.get(ie[0]) is not None else -1e9,
                                     ie[1]["golden_since"]))
        for i, e in members[:len(members) - GOLDEN_MAX]:
            e["golden_since"] = None
            e["streak"] = 0
    return {i for i, e in st["lessons"].items() if e.get("golden_since")}


def write_houses_section(rows, H, golden_ids=frozenset()):
    HEADER = "## Rolling additions (eight houses, effect-weighted by iterations)"
    lines = [HEADER, "",
             "Houses are octiles of recent %s issue runs by iteration count (bounds "
             "EMA-smoothed; a rule lives where it saves the most iterations and may "
             "only move between adjacent houses). House load = its share of total "
             "iterations. effect = median iterations saved since the rule entered "
             "(pending = window too thin)." % MODEL, ""]
    for h in range(8):
        lo = H["bounds"][h - 1] if h else None
        hi = H["bounds"][h] if h < 7 else None
        rng = ("%d–%d" % (lo, hi)) if lo is not None and hi is not None else \
              ("≥%d" % lo if lo is not None else "≤%d" % hi)
        lines.append("### %s %s · %s iters · load %.0f%%"
                     % (HOUSES[h], PLANETS[h], rng, H["weights"][h] * 100))
        house_rules = [(v, t) for hh, v, t, _, i in rows if hh == h and i not in golden_ids]
        house_rules.sort(key=lambda x: -(x[0] if x[0] is not None else -1e9))
        house_rules = dedupe_themes(house_rules)   # one lesson per theme per house
        if not house_rules:
            lines.append("- (no rules assigned yet)")
        for v, t in house_rules[:8]:      # cap 8 per house: 8×8=64 slots, scannable
            tag = ("saves %.1f iters" % v) if (v is not None and v >= 0) else \
                  ("costs %.1f iters" % -v if v is not None else "pending")
            lines.append("- %s  (%s)" % (t, tag))
        lines.append("")
    old = open(PLAYBOOK).read().splitlines()
    cut = len(old)
    for i, l in enumerate(old):
        if l.startswith("## Rolling additions") or l.startswith("## 滚动补充"):
            cut = i
            break
    body = old[:cut]
    while body and not body[-1].strip():
        body.pop()
    open(PLAYBOOK, "w").write("\n".join(body + ["", ""] + lines) + "\n")


def emit_golden(st, rows):
    """Golden = lessons on a >=STREAK_BAR house-best streak, at most GOLDEN_MAX,
    best effect first. Until the first lesson qualifies, the existing golden
    file is left UNTOUCHED (the effect-proven list stays as the interim
    golden); once any lesson qualifies, golden switches to the elite list and
    the interim bulk is dropped for good. Returns the member count."""
    eff = {i: v for h, v, t, effs, i in rows}
    members = [(eff.get(i), e["text"]) for i, e in st["lessons"].items()
               if e.get("golden_since") and e.get("text")]
    if not members:
        return 0
    members.sort(key=lambda x: -(x[0] if x[0] is not None else -1e9))
    body = ["# Golden lessons (solidified after %d consecutive tasks at a house's "
            "top; at most %d — demoted members re-enter the pool; generated by "
            "playbook-effect — do not hand-edit)" % (STREAK_BAR, GOLDEN_MAX), ""]
    body += ["- " + t for _, t in members[:GOLDEN_MAX]]
    open(GOLDEN_F, "w").write("\n".join(body) + "\n")
    return len(members[:GOLDEN_MAX])


if __name__ == "__main__":
    sys.exit(main())
