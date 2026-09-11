#!/usr/bin/env python3
"""stats.py — quick ClickHouse summary of cline daemon runs.

Usage: stats.py [hours]   (default 24; use 168 for the last 7 days)
"""
import json
import sys
import urllib.parse
import urllib.request

CH = "http://127.0.0.1:8123/"


def q(sql):
    url = CH + "?query=" + urllib.parse.quote(sql)
    req = urllib.request.Request(url, data=b"")
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read().decode().strip()


def fmt_tok(n):
    if n >= 1_000_000_000:
        return f"{n/1_000_000_000:.1f}B"
    if n >= 1_000_000:
        return f"{n/1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n/1_000:.0f}k"
    return str(n)


def fmt_ms(ms):
    s = ms / 1000
    if s >= 3600:
        return f"{s/3600:.1f}h"
    if s >= 60:
        return f"{s/60:.1f}m"
    return f"{s:.0f}s"


def main():
    hours = int(sys.argv[1]) if len(sys.argv) > 1 else 24
    w = f"ts_start > now() - INTERVAL {hours} HOUR"
    print(f"=== cline runs, last {hours}h ===")

    rows = q(f"""SELECT kind, count(), countIf(status='completed'),
        round(countIf(status='completed')/count()*100, 0), sum(attempt_count)
        FROM cline.runs WHERE {w} GROUP BY kind ORDER BY kind""")
    if not rows:
        print("(no runs)")
        return
    print(f"{'kind':10s} {'runs':>5s} {'ok':>4s} {'ok%':>5s} {'attempts':>8s}")
    for line in rows.splitlines():
        k, n, ok, pct, att = line.split("\t")
        print(f"{k:10s} {n:>5s} {ok:>4s} {pct:>5s}% {att:>8s}")

    tot = q(f"""SELECT sum(input_tokens), sum(output_tokens), sum(total_cost),
        countDistinct(run_id) FROM cline.runs WHERE {w}""").split("\t")
    print(f"tokens: in {fmt_tok(int(tot[0]))} / out {fmt_tok(int(tot[1]))}   cost ${float(tot[2]):.2f}")

    dur = q(f"""SELECT round(median(duration_ms)), round(quantile(0.9)(duration_ms)), max(duration_ms)
        FROM cline.runs WHERE {w} AND kind='issue' AND status='completed'""").split("\t")
    if dur[0]:
        print(f"issue duration (ok runs): median {fmt_ms(int(dur[0]))}  p90 {fmt_ms(int(dur[1]))}  max {fmt_ms(int(dur[2]))}")

    fails = q(f"""SELECT coalesce(nullIf(error_kind,''),'unknown'), count()
        FROM cline.runs WHERE {w} AND status != 'completed' GROUP BY 1 ORDER BY 2 DESC""")
    if fails:
        print("failures: " + ", ".join(f"{k}×{v}" for k, v in
              (l.split("\t") for l in fails.splitlines())))

    waste = q(f"""SELECT countIf(attempt > 1), sum(input_tokens)
        FROM cline.attempts WHERE {w} AND attempt > 1""").split("\t")
    if int(waste[0]) > 0:
        print(f"retry waste: {waste[0]} retried attempts, {fmt_tok(int(waste[1]))} extra input tokens")

    phases = q(f"""SELECT phase, round(median(since_start_ms)/1000)
        FROM cline.phases WHERE ts > now() - INTERVAL {hours} HOUR
          AND run_id IN (SELECT run_id FROM cline.runs WHERE {w} AND kind='issue')
        GROUP BY phase ORDER BY 2""")
    if phases:
        print("phases (median minutes from run start): " + ", ".join(
            f"{p}={int(s)//60}m" for p, s in (l.split("\t") for l in phases.splitlines())))

    last = q("""SELECT run_id, kind, status, coalesce(error_kind,''), duration_ms
        FROM cline.runs ORDER BY ts_start DESC LIMIT 5""")
    print("latest runs:")
    for line in last.splitlines():
        rid, k, st, ek, d = line.split("\t")
        flag = "" if st == "completed" else f" [{ek or 'unknown'}]"
        print(f"  {rid}  {k:9s} {st}{flag}  {fmt_ms(int(d))}")


if __name__ == "__main__":
    main()
