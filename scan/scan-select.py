#!/usr/bin/env python3
"""scan-select.py — bug-scan batch picker with an adaptive "middle band" window.

Scans the repo's git history, picks source files that are neither too new
(still hot, the author is watching) nor too old (long-stable, low bug density),
and stages one batch into scan/current-<slot>.json for the scan line.

The window is DYNAMIC (mode=auto): every file's age is days since its last
commit on the scan ref (origin/main, fallback HEAD).

  * newest band excluded:  age <  new_days            (default 14)
  * oldest band excluded:  age >  P(old_pct) of ages  (default P85)
  * middle band = candidates, minus already-scanned files whose last-commit
    oid has not changed since (a new commit re-enters a file automatically).

Batch choice inside the band is UCB1 over calendar-month buckets
(hits/scanned + exploration bonus), so buckets that historically yielded
reproduced bugs get scanned more, without starving the rest.

Two-level adaptation:
  1. bucket selection reacts to hit history (UCB1);
  2. window edges: `zero_hit_expand` consecutive clean rounds expand the band
     one step (new_days -7, floor 3; old_pct +5, cap 95); a near-empty
     candidate pool also triggers one inline expansion at select time.

Subcommands:
  select --slot N --slots M   pick a batch → scan/current-N.json (no file when
                              the pool is exhausted — the runner then rests)
  report --slot N             fold the round's outcome back into state.json
                              (bucket stats, zero-hit counter, auto-expansion)
  status                      human summary (hfv scan status)
  window [--set ND OP | --auto]
                              show / pin / re-dynamic the window
  self-test                   synthetic-data unit tests (no repo needed)

Config comes from env (config.sh exports SCAN_*): SCAN_NEW_EXCLUDE_DAYS,
SCAN_OLD_PCT, SCAN_BATCH_SIZE, SCAN_DYNAMIC(1/0), SCAN_ZERO_HIT_EXPAND,
SCAN_EXTS (comma), SCAN_EXCLUDE (comma path prefixes/substrings).
"""
import json
import math
import os
import random
import subprocess
import sys
import tempfile
import time

DIR = os.path.dirname(os.path.abspath(__file__))          # scan/
STATE = os.path.join(DIR, "state.json")

sys.path.insert(0, os.path.dirname(DIR))                  # repo root, for hfv_config
try:
    from hfv_config import load as _hfv_load
    _CFG = _hfv_load()
except Exception:
    _CFG = {}


def cfg(key, default):
    """env (exported by the line scripts) > hfv.conf > built-in default.
    Empty strings fall through — an explicit empty override is meaningless."""
    v = os.environ.get(key)
    if v:
        return v
    return _CFG.get(key) or default

DEFAULT_EXTS = ".py,.go,.ts,.tsx,.js,.jsx,.mjs,.cjs"
DEFAULT_EXCLUDE = ("vendor/,third_party/,node_modules/,dist/,build/,docs/,doc/,"
                   ".github/,docker/,deploy/,testdata/,test/,tests/,"
                   "web/public/,conf/,helm/,.min.js,"
                   ".generated.,_generated,.pb.go,/mocks/,mock_")
MAX_FILE_BYTES = 200 * 1024   # bigger files are usually generated/bundled


# ---------------------------------------------------------------- state -----

def load_state():
    try:
        with open(STATE) as f:
            s = json.load(f)
        s.setdefault("window", {})
        s.setdefault("buckets", {})
        s.setdefault("scanned", {})
        s.setdefault("history", [])
        s.setdefault("totals", {})
        return s
    except Exception:
        return {"version": 1, "rounds": 0, "zero_hit_rounds": 0,
                "window": {}, "buckets": {}, "scanned": {},
                "totals": {"files": 0, "suspects": 0, "reproduced": 0},
                "history": []}


def save_state(s):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f, ensure_ascii=False, indent=1)
    os.replace(tmp, STATE)



# ------------------------------------------------------------- git index ----

def git(repo, *args, timeout=120):
    return subprocess.run(["git", "-C", repo] + list(args),
                          capture_output=True, timeout=timeout)


def scan_ref(repo):
    for ref in ("origin/main", "HEAD"):
        if git(repo, "rev-parse", "--verify", "--quiet", ref).returncode == 0:
            return ref
    raise SystemExit("scan-select: no usable ref (origin/main or HEAD) in %s" % repo)


def build_index(repo, ref):
    """{path: (commit_ct, oid)} of every tracked file at <ref>, each file's
    newest commit. One streaming git-log pass; stops early once every tracked
    file has been seen (most files surface in the first few hundred commits).
    """
    ls = git(repo, "ls-tree", "-r", "--name-only", ref)
    if ls.returncode != 0:
        raise SystemExit("scan-select: git ls-tree failed: %s" % ls.stderr.decode(errors="replace")[:200])
    tracked = set(ls.stdout.decode("utf-8", errors="replace").splitlines())
    idx = {}
    cmd = ["git", "-C", repo, "log", "--no-renames",
           "--format=%x00%H %ct", "--name-only", ref, "--"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, bufsize=1024 * 1024)
    cur = None
    try:
        for raw in p.stdout:
            line = raw.decode("utf-8", errors="replace").rstrip("\n")
            if not line:
                continue
            if line.startswith("\x00"):                # commit header line
                parts = line[1:].split()
                cur = (int(parts[1]), parts[0]) if len(parts) == 2 else None
                continue
            if cur and line in tracked and line not in idx:
                idx[line] = cur
                if len(idx) >= len(tracked):           # full coverage: stop early
                    break
    finally:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
    return idx


# ------------------------------------------------------------- filtering ----

def eligible(path, repo=None):
    ext = os.path.splitext(path)[1].lower()
    if ext not in eligible.exts:
        return False
    # test files themselves are never audit targets: pytest test_*.py /
    # *_test.py, Go *_test.go (bare substrings would false-positive on
    # paths like latest_*/contest_*, so match the basename only)
    base = path.rsplit("/", 1)[-1]
    if base.startswith("test_") or base.endswith(("_test.go", "_test.py")):
        return False
    for pat in eligible.exclude:
        if pat.endswith("/"):
            if path.startswith(pat) or ("/" + pat) in path:
                return False
        elif pat in path:
            return False
    if repo:
        try:
            if os.path.getsize(os.path.join(repo, path)) > MAX_FILE_BYTES:
                return False
        except OSError:
            return False
    return True


def init_filter():
    exts = cfg("SCAN_EXTS", DEFAULT_EXTS)
    excl = cfg("SCAN_EXCLUDE", DEFAULT_EXCLUDE)
    eligible.exts = {e if e.startswith(".") else "." + e
                     for e in exts.split(",") if e.strip()}
    eligible.exclude = [p.strip() for p in excl.split(",") if p.strip()]

# ------------------------------------------------------------- selection ----

def band_candidates(idx, window, state, repo=None, now=None):
    """Middle-band files: not too new, not too old, not already scanned at the
    same oid. Returns (candidates list of (path, ct, oid), stats dict)."""
    now = now or int(time.time())
    ages = [(p, c[0], c[1]) for p, c in idx.items() if eligible(p, repo)]
    if not ages:
        return [], {"eligible": 0, "band": None, "candidates": 0}
    days = sorted((now - ct) / 86400.0 for _, ct, _ in ages)
    old_cut = percentile(days, window["old_pct"])
    scanned = state.get("scanned", {})
    cand = []
    for path, ct, oid in ages:
        age = (now - ct) / 86400.0
        if age < window["new_days"] or age > old_cut:
            continue
        if scanned.get(path) == oid:
            continue
        cand.append((path, ct, oid))
    return cand, {"eligible": len(ages),
                  "band": [window["new_days"], round(old_cut, 1)],
                  "candidates": len(cand)}


def ucb_pick(cand, buckets_stats, batch, rng):
    """UCB1 over month buckets. A picked bucket stays in the race with its
    remaining files, but its virtual count increments each pick, so picks
    round-robin across buckets and one hot bucket cannot swallow a batch.
    The exploration term uses (sc + 3): a bucket with zero history must not
    outrank a proven hit bucket forever — that would turn every round into
    pure exploration when many buckets exist."""
    by_bucket = {}
    for path, ct, oid in cand:
        by_bucket.setdefault(bucket_of(ct), []).append((path, ct, oid))
    total = sum(b.get("scanned", 0) for b in buckets_stats.values()) + 1
    virt = {b: dict(v) for b, v in buckets_stats.items()}   # don't mutate state
    picked = []
    while by_bucket and len(picked) < batch:
        order = list(by_bucket)          # shuffle: ties (cold start) go random
        rng.shuffle(order)
        best, best_score = None, -1.0
        for b in order:
            st = virt.get(b) or {"scanned": 0, "hits": 0}
            sc, hi = st["scanned"], st["hits"]
            score = hi / (sc + 1.0) + 0.4 * math.sqrt(math.log(total + 1) / (sc + 3.0))
            if score > best_score:
                best, best_score = b, score
        files = by_bucket[best]
        path, ct, oid = rng.choice(files)
        files.remove((path, ct, oid))    # in-place; the bucket stays in the
        if not files:                    # race with a lowered virtual count —
            del by_bucket[best]          # one hot bucket can't swallow a batch
        picked.append({"path": path, "last_commit": oid[:12],
                       "oid": oid, "age_days": round((time.time() - ct) / 86400.0, 1),
                       "bucket": best})
        st = virt.setdefault(best, {"scanned": 0, "hits": 0})
        st["scanned"] += 1
    return picked


def expand_window(window):
    window["new_days"] = max(3, window["new_days"] - 7)
    window["old_pct"] = min(95, window["old_pct"] + 5)
    return window


def percentile(sorted_vals, pct):
    if not sorted_vals:
        return 0
    k = min(len(sorted_vals) - 1, max(0, int(len(sorted_vals) * pct / 100)))
    return sorted_vals[k]


def bucket_of(ct):
    return time.strftime("%Y-%m", time.localtime(ct))

def cfg_window(state):
    """Effective window: pinned state wins; otherwise env/config defaults."""
    w = state.get("window") or {}
    return {
        "new_days": int(w.get("new_days") or cfg("SCAN_NEW_EXCLUDE_DAYS", 14)),
        "old_pct": int(w.get("old_pct") or cfg("SCAN_OLD_PCT", 85)),
        "mode": w.get("mode") or ("auto" if cfg("SCAN_DYNAMIC", "1") == "1" else "pinned"),
    }

# ------------------------------------------------------------ subcommands ---

def cmd_select(repo, slot, slots):
    state = load_state()
    window = cfg_window(state)
    git(repo, "fetch", "-q", "origin", "main")   # best-effort; offline is fine
    ref = scan_ref(repo)
    idx = build_index(repo, ref)
    batch = int(cfg("SCAN_BATCH_SIZE", 10))
    rng = random.Random()

    cand, stats = band_candidates(idx, window, state, repo)
    # Inline expansion: a near-empty pool in auto mode widens the band once
    # (two steps max) so the line keeps working instead of idling.
    if window["mode"] == "auto" and len(cand) < max(2, batch // 2):
        for _ in range(2):
            if len(cand) >= max(2, batch // 2):
                break
            expand_window(window)
            cand, stats = band_candidates(idx, window, state, repo)
        state["window"] = dict(window)

    cur_file = os.path.join(DIR, "current-%d.json" % slot)
    if not cand:
        state.setdefault("history", []).append(
            {"ts": int(time.time()), "slot": slot, "event": "exhausted",
             "window": dict(window), **stats})
        save_state(state)
        if os.path.exists(cur_file):
            os.unlink(cur_file)
        print("scan-select: middle band exhausted (eligible=%d) — resting" % stats["eligible"])
        return 1

    picked = ucb_pick(cand, state["buckets"], batch, rng)
    scan_id = time.strftime("scan-%Y%m%d-") + str(slot)
    rec = {"scan_id": scan_id, "slot": slot, "slots": slots, "ref": ref,
           "window": dict(window), "stats": stats,
           "picked_at": time.strftime("%Y-%m-%d %H:%M:%S"),
           "files": picked}
    with open(cur_file, "w") as f:
        json.dump(rec, f, ensure_ascii=False, indent=1)
    # Register the picks immediately so a concurrent slot / the next round
    # never re-picks them (oid change re-enters a file automatically).
    for p in picked:
        state["scanned"][p["path"]] = p["oid"]
    save_state(state)
    print("scan-select: %s → %d file(s) from %d candidates (band %dd..%dd, window %s)"
          % (scan_id, len(picked), stats["candidates"], stats["band"][0],
             stats["band"][1], window["mode"]))
    return 0


def cmd_report(slot):
    """Fold the round's outcome into state.json. Reads scan/current-<slot>.json
    (the batch) and scan/deliver-<slot>/result.json (the LLM's verdict)."""
    state = load_state()
    cur_p = os.path.join(DIR, "current-%d.json" % slot)
    res_p = os.path.join(DIR, "deliver-%d" % slot, "result.json")
    try:
        cur = json.load(open(cur_p))
    except Exception:
        print("scan-select report: no current-%d.json — nothing to fold" % slot)
        return 0
    try:
        res = json.load(open(res_p))
        outcome = res.get("outcome") or "unknown"
    except Exception:
        res, outcome = {}, "unknown"

    buckets = state.setdefault("buckets", {})
    for f_ in cur.get("files", []):
        b = buckets.setdefault(f_.get("bucket", "?"), {"scanned": 0, "hits": 0})
        b["scanned"] += 1
    totals = state.setdefault("totals", {"files": 0, "suspects": 0, "reproduced": 0})
    totals["files"] = totals.get("files", 0) + len(cur.get("files", []))
    totals["suspects"] = totals.get("suspects", 0) + int(res.get("suspects") or 0)

    window = cfg_window(state)
    event = None
    if outcome == "reported":
        totals["reproduced"] = totals.get("reproduced", 0) + 1
        bug_file = res.get("bug_file") or ""
        bf = next((f_ for f_ in cur.get("files", []) if f_["path"] == bug_file), None)
        if bf:
            buckets.setdefault(bf["bucket"], {"scanned": 0, "hits": 0})["hits"] += 1
        state["zero_hit_rounds"] = 0
    elif outcome in ("clean", "blocked"):
        state["zero_hit_rounds"] = state.get("zero_hit_rounds", 0) + 1
        limit = int(cfg("SCAN_ZERO_HIT_EXPAND", 3))
        if window["mode"] == "auto" and state["zero_hit_rounds"] >= limit:
            expand_window(window)
            state["window"] = dict(window)
            state["zero_hit_rounds"] = 0
            event = "window_expanded"

    state["rounds"] = state.get("rounds", 0) + 1
    hist = state.setdefault("history", [])
    hist.append({"ts": int(time.time()), "slot": slot,
                 "scan_id": cur.get("scan_id"), "outcome": outcome,
                 "files": len(cur.get("files", [])),
                 "suspects": int(res.get("suspects") or 0),
                 "window": dict(window), **({"event": event} if event else {})})
    del hist[:-100]
    save_state(state)
    print("scan-select report: %s outcome=%s zero_hit_rounds=%d window=%dd/P%d(%s)%s"
          % (cur.get("scan_id"), outcome, state.get("zero_hit_rounds", 0),
             window["new_days"], window["old_pct"], window["mode"],
             " [window expanded]" if event else ""))
    return 0


def cmd_status():
    state = load_state()
    w = cfg_window(state)
    t = state.get("totals", {})
    print("window: new<%dd excluded, oldest>P%d excluded, mode=%s"
          % (w["new_days"], w["old_pct"], w["mode"]))
    print("rounds: %d   files scanned: %d   suspects: %d   reproduced: %d   zero-hit streak: %d"
          % (state.get("rounds", 0), t.get("files", 0), t.get("suspects", 0),
             t.get("reproduced", 0), state.get("zero_hit_rounds", 0)))
    buckets = state.get("buckets", {})
    if buckets:
        print("buckets (month: scanned/hits):")
        for b in sorted(buckets):
            st = buckets[b]
            print("  %s  %4d / %d" % (b, st.get("scanned", 0), st.get("hits", 0)))
    print("scanned registry: %d file(s)" % len(state.get("scanned", {})))
    hist = state.get("history", [])[-5:]
    if hist:
        print("recent rounds:")
        for h in hist:
            ts = time.strftime("%m-%d %H:%M", time.localtime(h["ts"]))
            print("  [%s] %s files=%s outcome=%s %s"
                  % (ts, h.get("scan_id", "?"), h.get("files", "-"),
                     h.get("outcome", h.get("event", "?")),
                     h.get("event", "")))
    return 0


def cmd_window(args):
    state = load_state()
    if not args:
        w = cfg_window(state)
        print("window: new_days=%d old_pct=%d mode=%s (config defaults SCAN_NEW_EXCLUDE_DAYS=%s SCAN_OLD_PCT=%s)"
              % (w["new_days"], w["old_pct"], w["mode"],
                 cfg("SCAN_NEW_EXCLUDE_DAYS", 14),
                 cfg("SCAN_OLD_PCT", 85)))
        return 0
    if args[0] == "--auto":
        state.setdefault("window", {})["mode"] = "auto"
        save_state(state)
        print("window: dynamic adjustment ON (edges adapt to hit history)")
        return 0
    if args[0] == "--set" and len(args) == 3:
        try:
            nd, op = int(args[1]), int(args[2])
        except ValueError:
            nd = op = 0
        if not (1 <= nd <= 90 and 50 <= op <= 100):
            print("usage: window --set <new_days 1-90> <old_pct 50-100>", file=sys.stderr)
            return 1
        state["window"] = {"new_days": nd, "old_pct": op, "mode": "pinned"}
        save_state(state)
        print("window pinned: new_days=%d old_pct=%d "
              "(dynamic adjustment OFF; 'window --auto' re-enables)" % (nd, op))
        return 0
    print("usage: window [--set <new_days> <old_pct> | --auto]", file=sys.stderr)
    return 1


# -------------------------------------------------------------- self-test ---

def self_test():
    global STATE
    STATE = os.path.join(tempfile.mkdtemp(prefix="scan-select-test-"), "state.json")
    init_filter()
    now = int(time.time())
    day = 86400
    fails = []

    def check(name, cond):
        print(("PASS" if cond else "FAIL"), name)
        if not cond:
            fails.append(name)

    # synthetic index: path -> (ct, oid); ages spread 10d..400d
    idx = {}
    for i in range(1, 41):                      # 40 source files, 10d apart
        idx["rag/svc/file%02d.py" % i] = (now - i * 10 * day, "oid%03d" % i)
    idx["web/src/app.tsx"] = (now - 30 * day, "oidweb")
    idx["docs/readme.py"] = (now - 60 * day, "oiddoc")        # excluded path
    idx["rag/x_test.py"] = (now - 60 * day, "oidtest")        # excluded substr
    idx["rag/data.txt"] = (now - 60 * day, "oidtxt")          # excluded ext
    idx["deepdoc/a.go"] = (now - 5 * day, "oidnew")           # too new
    idx["api/old.py"] = (now - 400 * day, "oidold")           # very old

    st = load_state()
    w = {"new_days": 14, "old_pct": 85, "mode": "auto"}
    cand, stats = band_candidates(idx, w, st, repo=None, now=now)
    paths = {c[0] for c in cand}
    check("excludes newest band (<14d)", "deepdoc/a.go" not in paths)
    check("excludes oldest band (>P85)",
          "api/old.py" not in paths and "rag/svc/file40.py" not in paths)
    check("excludes docs/ and test files and non-source ext",
          not {"docs/readme.py", "rag/x_test.py", "rag/data.txt"} & paths)
    check("keeps middle band", "web/src/app.tsx" in paths and "rag/svc/file05.py" in paths)

    # dedup: scanned at same oid stays out; new oid re-enters
    st["scanned"] = {"web/src/app.tsx": "oidweb", "rag/svc/file05.py": "oidOLD"}
    cand2, _ = band_candidates(idx, w, st, repo=None, now=now)
    paths2 = {c[0] for c in cand2}
    check("same-oid file stays excluded", "web/src/app.tsx" not in paths2)
    check("changed-oid file re-enters", "rag/svc/file05.py" in paths2)

    # batch size + UCB hot-bucket bias
    st2 = load_state()
    ct_hot = now - 35 * day
    hot_bucket = bucket_of(ct_hot)
    st2["buckets"] = {hot_bucket: {"scanned": 10, "hits": 4},
                      bucket_of(now - 100 * day): {"scanned": 10, "hits": 0}}
    rng = random.Random(42)
    picks = ucb_pick([(p, c, o) for p, (c, o) in idx.items()], st2["buckets"], 5, rng)
    check("batch size honored", len(picks) == 5)
    check("UCB favors the hit bucket", any(p["bucket"] == hot_bucket for p in picks))

    # zero-hit expansion (auto) vs pinned
    os.environ["SCAN_ZERO_HIT_EXPAND"] = "3"
    os.makedirs(os.path.join(DIR, "deliver-9"), exist_ok=True)
    for i in range(3):
        json.dump({"outcome": "clean", "suspects": 0},
                  open(os.path.join(DIR, "deliver-9", "result.json"), "w"))
        json.dump({"scan_id": "t", "files": [{"path": "rag/svc/file05.py",
                                              "bucket": bucket_of(now - 50 * day)}]},
                  open(os.path.join(DIR, "current-9.json"), "w"))
        cmd_report(9)
    st3 = load_state()
    w3 = cfg_window(st3)
    check("auto window expands after 3 clean rounds",
          w3["new_days"] == 7 and w3["old_pct"] == 90)
    check("zero-hit streak reset on expansion", st3.get("zero_hit_rounds") == 0)

    st3["window"] = {"new_days": 14, "old_pct": 85, "mode": "pinned"}
    save_state(st3)
    for i in range(3):
        cmd_report(9)
    w4 = cfg_window(load_state())
    check("pinned window never expands", w4["new_days"] == 14 and w4["old_pct"] == 85)

    # a hit resets the streak and lands in the file's bucket
    st5 = load_state()
    st5["zero_hit_rounds"] = 2
    save_state(st5)
    json.dump({"outcome": "reported", "bug_file": "rag/svc/file05.py", "suspects": 1},
              open(os.path.join(DIR, "deliver-9", "result.json"), "w"))
    cmd_report(9)
    st6 = load_state()
    check("reported outcome resets streak", st6.get("zero_hit_rounds") == 0)
    check("hit lands in the file's bucket",
          st6["buckets"].get(bucket_of(now - 50 * day), {}).get("hits", 0) >= 1)

    print("self-test: %s" % ("ALL PASS" if not fails
                             else "%d FAILURES: %s" % (len(fails), fails)))
    return 1 if fails else 0


# ------------------------------------------------------------------ main ----

def main():
    init_filter()
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 1
    cmd = args[0]
    if cmd == "self-test":
        return self_test()
    if cmd == "status":
        return cmd_status()
    if cmd == "window":
        return cmd_window(args[1:])
    if cmd == "report":
        slot = int(args[args.index("--slot") + 1]) if "--slot" in args else 1
        return cmd_report(slot)
    if cmd == "select":
        def opt(name, default):
            return args[args.index(name) + 1] if name in args else default
        repo = opt("--repo", os.environ.get("RAGFLOW_MAIN", ""))
        if not repo or not os.path.isdir(os.path.join(repo, ".git")):
            print("scan-select: --repo (or RAGFLOW_MAIN) must point at the clone",
                  file=sys.stderr)
            return 1
        return cmd_select(repo, int(opt("--slot", 1)), int(opt("--slots", 1)))
    print("unknown subcommand: %s" % cmd, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())

