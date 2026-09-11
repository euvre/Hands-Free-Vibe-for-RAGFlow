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


## Rolling additions (eight houses, effect-weighted by iterations)

Houses are octiles of recent glm-5.3 issue runs by iteration count (bounds EMA-smoothed; a rule lives where it saves the most iterations and may only move between adjacent houses). House load = its share of total iterations. effect = median iterations saved since the rule entered (pending = window too thin).

### 水 Mercury · ≤66 iters · load 4%
- (no rules assigned yet)

### 金 Venus · 66–76 iters · load 5%
- (no rules assigned yet)

### 地 Earth · 76–91 iters · load 10%
- avoid giant multi-branch regexes in search_codebase  (saves 4.0 iters)
- run >30s commands in background with log redirection  (saves 4.0 iters)
- on odd output, check env vars and silent Mock degradation first  (saves 4.0 iters)
- verify fixes by comparing artifact counts and types, not just sampled content  (saves 4.0 iters)
- Add explicit short timeouts to port, process, and service-readiness checks so hung probes fail fast.  (saves 4.0 iters)
- Run the full type check once into a log file, then grep the saved log instead of recompiling.  (saves 4.0 iters)
- Read the exact lines to be replaced immediately before editing so the replacement anchor matches and the edit does not f  (saves 4.0 iters)
- Trim verbose command output with tail, head, or grep to limit context growth and repeated auto-compactions.  (saves 4.0 iters)

### 火 Mars · 91–110 iters · load 11%
- Replace fixed sleeps after service or build launches with a single bounded readiness poll loop that exits on success or  (costs 4.5 iters)
- When one compile error recurs, search the codebase for all identical occurrences and fix them in a single pass.  (costs 4.5 iters)
- Reconnect the browser or open a fresh page upon target-closed errors instead of retrying against the dead session.  (costs 4.5 iters)
- Verify installed client type definitions and use type guards or optional chaining before accessing response properties.  (costs 4.5 iters)
- Check remaining usage quota before long tasks and checkpoint progress so interruption by limits wastes no completed work  (costs 4.5 iters)
- Run test commands in the foreground with timeout and captured output instead of background launches plus busy-poll log l  (costs 4.5 iters)
- Avoid shell ls on large dependency directories; use targeted searches or reads on known paths to skip slow scans.  (costs 4.5 iters)
- Search specific identifiers and code patterns rather than generic error keywords to avoid noisy match dumps.  (costs 4.5 iters)

### 木 Jupiter · 110–125 iters · load 11%
- (no rules assigned yet)

### 土 Saturn · 125–156 iters · load 13%
- (no rules assigned yet)

### 天 Uranus · 156–215 iters · load 18%
- Run long dependency downloads and builds in the background; poll their logs with combined sleep-and-tail commands instea  (costs 16.0 iters)
- Confirm required packages import cleanly in the target environment before writing scripts that depend on them.  (costs 16.0 iters)
- Never clear build caches before rebuilding unless corruption is proven; forced full recompilation wastes many minutes.  (costs 16.0 iters)
- Write Go diagnostics with Errorf format verbs directly instead of Error(fmt.Sprintf(...)) to avoid large lint remediatio  (costs 16.0 iters)
- Start long builds once in the background and poll logs at longer intervals instead of repeated sub-minute sleep checks.  (costs 16.0 iters)
- Confirm which backend actually serves the web UI before editing frontend code; the UI may proxy to a different service.  (costs 16.0 iters)
- Validate shell command strings before submission; never send empty, whitespace-only, or truncated command payloads.  (costs 16.0 iters)
- Replace fixed-sleep polling loops with one bounded wait on a readiness signal; repeated sleep commands waste run time.  (costs 16.0 iters)

### 海 Neptune · ≥215 iters · load 28%
- Verify TLS certificate trust and CA bundle configuration for required endpoints before starting network-dependent tasks.  (saves 28.5 iters)
- Probe endpoint connectivity with a minimal request early; abort promptly on certificate verification failures instead of  (saves 28.5 iters)
- Capture full certificate error diagnostics, including host and chain details, so failures are attributable rather than u  (saves 28.5 iters)
- Prefer the codebase search tool over recursive shell grep for symbol lookups in large repositories.  (saves 28.5 iters)
- Launch long native builds detached with nohup and redirected logs, then poll instead of blocking one shell call.  (saves 28.5 iters)
- Run long test suites in background with nohup redirecting to a log, then poll that log instead of blocking.  (saves 28.5 iters)
- Keep sleep durations below the command timeout cap; a longer sleep wastes the entire call and returns truncated output.  (saves 28.5 iters)
- Locate native libraries via pkg-config or standard prefix directories before falling back to a filesystem-wide find.  (saves 28.5 iters)

