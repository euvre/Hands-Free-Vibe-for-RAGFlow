#!/usr/bin/env python3
"""issue-sheet.py — write delivery/merge status back to the Feishu issue sheet.

The "v1.0 issue" sheet (Sheet1) is the human-maintained bug ledger. When the
pipeline delivers a fix for a bug that IS already registered there, fill in:
  deliver <mid> <pr_url>   ownership-aware fill of the matched row:
                             H empty      -> H <- @肖毅 AND PR link appended
                                             into 备注 (M)
                             H == @肖毅   -> PR link appended into M only
                             H = someone  -> row left untouched entirely
                                             (a human owns this bug; our
                                             delivery is not registered)
                           link append is idempotent (skipped when present)
  merged  <pr_url>         set 已修复 (G) to "Y" on the row whose 备注 cell
                           carries this PR link (only when G is empty)
  backfill [--dry-run]     re-apply the two rules above to every done/merged
                           store record carrying a PR (one-off history repair)

Bugs NOT registered in the sheet are left alone entirely (matched against the
description column; zero or ambiguous matches are a no-op either way).

Config (issues/config): SHEET_TOKEN, SHEET_TAB (sheetId, not the tab title),
SHEET_OWNER (default "@肖毅").
"""
import json
import os
import re
import sys

DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, DIR)
import issue_recorder as ir  # noqa: E402  (load_config / tenant_token / http)

STORE = os.path.join(DIR, "issues.jsonl")

COL_DESC, COL_FIXED, COL_OWNER, COL_NOTE = 4, 6, 7, 12  # E, G, H, M (0-based)


def norm(s):
    return re.sub(r"[\s　\-_/()（）:：,，.。、\[\]【】!！?？'\"“”]+", "", s or "").lower()


def load_cfg():
    cfg = ir.load_config()
    return (cfg.get("SHEET_TOKEN", "THA6sa82dh0mFRtcrYfcO1PjnUc"),
            cfg.get("SHEET_TAB", "5776ac"),
            cfg.get("SHEET_OWNER", "@肖毅"))


def read_rows(token, tok, tab):
    d = ir.http("GET", f"{ir.BASE}/sheets/v3/spreadsheets/{tok}/sheets/query",
                token=token)
    n = 200
    for s in ((d.get("data") or {}).get("sheets") or []):
        if s.get("sheet_id") == tab:
            n = int((s.get("grid_properties") or {}).get("row_count") or 200)
    d = ir.http("GET", f"{ir.BASE}/sheets/v2/spreadsheets/{tok}/values/"
                       f"{tab}!A2:M{n}?valueRenderOption=ToString", token=token)
    return ((d.get("data") or {}).get("valueRange") or {}).get("values") or []


def cell(row, idx):
    v = row[idx] if len(row) > idx else None
    return (str(v).strip() if v is not None else "")


def find_row(rows, text, text_full):
    """Unique description match (normalized equality or containment); the
    row NUMBER (1-based, header = row 1) or None."""
    nt, nf = norm(text), norm(text_full[:500])
    cands = []
    for i, row in enumerate(rows, 2):
        nd = norm(cell(row, COL_DESC))
        if not nd or len(nd) < 4:
            continue
        if nd == nt or nd == nf:
            cands.append(i)
        elif len(nd) >= 6 and ((nt and (nd in nt or nt in nd))
                               or (nf and nd in nf)):
            cands.append(i)
    return cands[0] if len(cands) == 1 else None


def batch_write(token, tok, writes, dry_run=False):
    if not writes:
        return True
    # values_batch_update rejects single-cell ranges ("tab!M658" -> 90202
    # wrong range); the same cell as a 1x1 span ("tab!M658:M658") is accepted
    fixed = []
    for rng, vals in writes:
        if ":" not in rng.split("!", 1)[1]:
            rng = rng + ":" + rng.split("!", 1)[1]
        fixed.append((rng, vals))
    if dry_run:
        for rng, vals in fixed:
            print("  DRY-RUN write %s <- %s" % (rng, vals))
        return True
    body = {"valueRanges": [{"range": rng, "values": vals} for rng, vals in fixed]}
    d = ir.http("POST", f"{ir.BASE}/sheets/v2/spreadsheets/{tok}/values_batch_update",
                token=token, body=body)
    if not (d and d.get("code") == 0):
        print("batch_write failed: %s" % json.dumps(d, ensure_ascii=False)[:200])
        return False
    return True


def store_record(mid):
    if not os.path.exists(STORE):
        return None
    for line in open(STORE):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        if r.get("message_id") == mid:
            return r
    return None


def deliver(mid, pr_url, dry_run=False):
    tok, tab, owner = load_cfg()
    rec = store_record(mid) or {}
    text, text_full = rec.get("text") or "", rec.get("text_full") or ""
    if not (text or text_full):
        print("deliver %s: no store record (cannot match description) — skip" % mid)
        return 0
    token = ir.tenant_token(ir.load_config())
    rows = read_rows(token, tok, tab)
    n = find_row(rows, text, text_full)
    if n is None:
        print("deliver %s: bug not in sheet (or ambiguous) — left alone" % mid)
        return 0
    row = rows[n - 2]
    owner_now = cell(row, COL_OWNER)
    if owner_now and norm(owner_now) != norm(owner):
        print("deliver %s: row %d owned by %s (not %s) — left alone"
              % (mid, n, owner_now, owner))
        return 0
    writes = []
    note = cell(row, COL_NOTE)
    if pr_url not in note:
        writes.append(("%s!M%d" % (tab, n), [[(note + " " + pr_url).strip()]]))
    if not owner_now:
        writes.append(("%s!H%d" % (tab, n), [[owner]]))
    if not writes:
        print("deliver %s: row %d already up to date" % (mid, n))
        return 0
    ok = batch_write(token, tok, writes, dry_run)
    print("deliver %s: row %d %s (%s)" % (
        mid, n, "updated" if ok else "WRITE FAILED",
        ", ".join(w[0].split("!")[1] for w in writes)))
    return 0 if ok else 1


def merged(pr_url, dry_run=False):
    tok, tab, _ = load_cfg()
    token = ir.tenant_token(ir.load_config())
    rows = read_rows(token, tok, tab)
    hits = [i for i, row in enumerate(rows, 2) if pr_url in cell(row, COL_NOTE)]
    if not hits:
        print("merged %s: PR link not found in sheet — skip" % pr_url)
        return 0
    n = hits[0]
    if cell(rows[n - 2], COL_FIXED):
        print("merged %s: row %d already marked fixed" % (pr_url, n))
        return 0
    ok = batch_write(token, tok, [("%s!G%d" % (tab, n), [["Y"]])], dry_run)
    print("merged %s: row %d %s" % (pr_url, n, "marked Y" if ok else "WRITE FAILED"))
    return 0 if ok else 1


def backfill(dry_run=False):
    if not os.path.exists(STORE):
        return 0
    for line in open(STORE):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        pr = r.get("pr") or ""
        mid = r.get("message_id", "")
        if not pr or not mid or ir.is_gh(mid):
            continue
        if r.get("state") not in ("done", "merged"):
            continue
        print("backfill %s (%s, %s)" % (mid, r["state"], pr))
        deliver(mid, pr, dry_run)
        if r.get("state") == "merged":
            merged(pr, dry_run)
    return 0


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__, file=sys.stderr)
        return 1
    cmd = args[0]
    if cmd == "deliver" and len(args) == 3:
        return deliver(args[1], args[2])
    if cmd == "merged" and len(args) == 2:
        return merged(args[1])
    if cmd == "backfill":
        return backfill("--dry-run" in args[1:])
    print(__doc__, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
