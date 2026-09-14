# Run playbook

Goal: full delivery ≤60 min, rest ≤10 min. Where this conflicts with task.md / feat-task.md, the task file wins.

## 0. Time budget (hard checkpoints)

| Stage | Cap |
|---|---|
| Select + claim | 5 min |
| Reproduce | 20 min |
| Fix + tests | 50 min |
| Deliver (branch/PR/reply) | 15 min |

Stuck >10 min on one point → switch approach immediately; same move retried ≤2 times.

## 1. Context discipline

- Browser probing prefers `evaluate_script` for precise data; `take_snapshot` at most once per page; screenshots only when pixels matter.
- Command output must converge: cut with `grep/head/tail/jq`; never dump whole large files, big JSON, or full git logs.
- Exception — PR comment collection: run `pr-comments-fetch.sh` (complete, paginated, count-reconciled) instead of cutting a comment listing; a cut comment is a silently dropped work item (2026-08-27: one stayed hidden 17h).
- Read files with line ranges; never re-read the same path in full.
- Feishu scanning: one page pull, no repeated paging; probe each candidate thread once and stop.

## 2. Troubleshooting order

- Reproduce the reporter's exact scenario before theorizing; ask "what is the simplest explanation" and verify it with one DB row or one API call before reading deeper code.
- Before changing code, build a global, three-dimensional understanding of RAGFlow and of the problem — the owning code path's role in the whole architecture, the full data flow / storage location across layers, all callers and callees, and same-topic history — and only then choose interfaces and approaches and write code. Never patch from a single-file local view.
- Write no comments by default: the code must explain itself through naming, structure, and small functions. Delete existing comments in the hunks you touch wherever the code reads clearly without them. Only architecture-level signposts survive (why a layer/module boundary exists, a non-obvious invariant) — never line-by-line narration. No history/incident narration either (dates, PR/issue numbers, "used to", "previously", "incident", "post-mortem"): a comment describes the code as it IS, never how it came to be.
- Always check same-topic historical PRs: a rejected approach must not be resubmitted in disguise; when the approach differs, state the difference in the PR description.
- When external resources are unavailable (e.g. LLM quota exhausted), switch immediately to code-level evidence (alignment analysis, unit tests); never retry in a loop.

## 3. Environment & tool discipline

- Service start/readiness only via `~/hands-free-vibe/framework/ragflow-up.sh` + `/tmp/ragflow-ready.status`; never hand-write setsid, never foreground-sleep-poll.
- Tool timeouts/empty output ≠ service down: curl the port before concluding.
- Login only through the browser form; never touch the DB over a plaintext-API login failure.
- Every `/api` call through the web UI 500s while the backend is provably alive → check `API_PROXY_SCHEME` in `/tmp/ragflow-web.log` FIRST. The worktree's `web/.env.development` pins `go`, and the Go gateway is the first thing to die in throwaway groups (ES ping / missing native deps) — restart web with `setsid env API_PROXY_SCHEME=python bash -c "cd $REPO/web && exec npm run dev"` instead of debugging the Python API (ragflow-up.sh ≥2026-09-09 already defaults to python; treat a `go` reading there as a stale launch).
- Never use `pkill -f`; clean ports with `fuser -k`.

## 4. Delivery speedups

- Run `npm run type-check` once after all edits; use oxlint on changed files meanwhile.
- Run the narrowest Go test package; leave full runs to CI.
- Run `git push` in the background; write the PR description while waiting.
- A failed gh label/reviewer call is logged once and skipped — permission errors gain nothing from retries.
- All Feishu actions go through lark-mcp tools; never hand-roll curl.
- Never end by asking permission: if the approach holds, deliver and note the difference from precedents in the PR; if delivery is truly wrong, reply with the reason via the failure path and terminate.

## 5. Resting & skipping

- No qualified message → end immediately; no digging through old topics, no make-up work.
- Skipped threads stay skipped; follow-up posts are never a restart order.
