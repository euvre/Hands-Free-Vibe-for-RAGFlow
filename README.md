# hands-free-vibe

[中文](README.zh-cn.md)

hands-free-vibe (hfv) is an unattended maintenance robot for one open-source repository — currently a RAGFlow fork. A bug report lands in a Feishu group; hfv claims it, reproduces it, fixes it, verifies the fix, and opens a PR on GitHub. Answering reviewers, rebasing, chasing CI, and the merge-readiness report afterwards are part of the job too. Nobody is in the loop from report to merge.

## What it does

**Intake.** A recorder daemon scans the Feishu group on a timer. New reports land in a local store with their attachments; screenshots and screen recordings are transcribed into text by a vision model, so the fixing agent never has to open an image. Sources are pluggable: next to the main Lark group source there is an experimental GitHub issue source — open issues picked up by label, with screenshot links in body and comments downloaded and transcribed the same way. Both sources write into the same store; downstream stages dispatch on the message_id prefix and never care where a record came from.

**Fixing and verification, for real.** Every task runs in a throwaway container started from a frozen golden image: the full service stack (MySQL / Elasticsearch / Redis / MinIO / NATS), the model providers, and the login state are all in the image, and task containers never see each other. Inside, the agent brings the whole app up, reproduces the bug in a real browser (chrome-devtools MCP), runs tiered tests, and verifies the fix before anything goes out — it does not argue from the diff alone.

**Delivery.** The agent has no git access. It stages a branch name, a commit message, PR title and body, and verification screenshots; a host-side script takes over: a backup ref first, then an ownership check on the staged content (a mismatched worktree stamp gets archived, not shipped), then commit, push, and the PR. The classic ways this used to go wrong — sweeping the whole worktree pool into a commit, an empty staged set, delivering at the main-repo root — all have hard guards that refuse outright.

**PR follow-through.** Once a PR is out, four lines split the rest:

- **review** reads new review comments from the local snapshot, judges which are valid, fixes, pushes, and answers item by item;
- **rebase** sends conflict-free branches through a ~15-second script-only fast path and only spends an LLM on real conflicts; its force-with-lease push goes through the outbox as well;
- **ci** watches check runs, tells flakes from real failures, re-trips the label-gated suite, fixes our own PRs, and leaves a comment on external ones;
- **follow** is a script-only state machine: merged/closed flips, stall nudges, and the "ready to merge" DM to the merge owner.

**The reverse role.** The pr-audit line reviews other people's PRs to the upstream repo: meta and comments come pre-scanned by the recorder, the audit actually launches the app in a container for end-to-end verification, and the verdict is LGTM / PROBLEMS / INCOMPLETE. An LGTM applies the gate label — the same merge signal our own deliveries use.

**Feature work from a spec.** A manual feat line: `hfv feat -f spec.md` implements a full feature from a spec document and reuses the same delivery machinery.

**It learns.** Every task writes lessons into a rolling playbook. An effect engine ranks lessons by outcome rather than hit rate: how many iterations later tasks of the same kind saved after a lesson appeared. The useful ones float up, the stale ones sink and get purged.

## Why hfv

Same job — one bug from report to merge — three ways of doing it:

| | Pure manual | Semi-manual + vibe coding | Hands Free Vibe |
|---|---|---|---|
| Verification | ❌ Repro and regression are each person's call; there is no enforced verification step | ❌ The agent only has the code; with no ready-made stack or browser, "verified" stops at "it compiles", sometimes at "looks right" | ✅ Every task boots the full stack from the golden image: browser repro, tiered tests, re-verified after the fix — decided by what the run shows |
| Credential boundary | ❌ Every credential sits on one dev machine; the leak surface is the whole work environment | ❌ The agent shares that environment with git/gh tokens at its fingertips; one hallucinated command pushes to the wrong place | ✅ Task containers carry zero credentials, the agent has no git access, every write goes through host-side guarded scripts |
| GitHub writes | ❌ No queue, no retry, no idempotency; a missed send or reply has no backstop | ❌ The agent calls gh directly; a failed call is lost, a retried one can double-post or open a second PR | ✅ Every write lands in an on-disk outbox first and runs with retries and dependency chains; PR creation is idempotent, comments carry an idempotency key so replays never double-post |
| Failure boundaries | ❌ No guards; a mis-operation lands directly on the repo | ❌ No guardrails — the damage scales linearly with the permissions handed over | ✅ Hard guards refuse outright: pushes are pool-worktrees-only, fork-only, never the base branch |
| Parallelism | ❌ One bug at a time | ❌ Extra windows share one environment; ports, branches, and login states collide | ✅ `hfv scale <line> <n>`; per-instance locks and modulo sharding, instances never step on each other |
| Experience | ❌ Lives only in people's heads; the process itself retains and passes on nothing | ❌ The session ends and the lesson is gone; the same pit gets fallen into again | ✅ Lessons go into a rolling playbook, ranked by iterations actually saved, dead ones purged |
| … | … | … | … |

## Architecture

```
feishu group ──┐
               │   recorder (timer): attachments downloaded,
github issues ─┘   screenshots/recordings transcribed to text
               │
               ▼
         issues store
               │
               ▼
   issue / feat lines ──► throwaway containers (golden image:
               │           full stack, browser repro, tiered tests)
               ▼
         staging dir ──► host-side delivery
               │           (backup ref, ownership check, hard guards)
               ▼
         gh-outbox ──► gh-recorder ──► GitHub
        (disk queue,     │ every minute; the only
         retries + dep   │ GitHub caller
         chains)         ▼
              gh-store (local PR snapshots:
              meta, comments, CI, review states)
                         │
                         ▼
      review / rebase / ci / follow / audit lines
```

systemd user timers drive the lines, and the lines are independent of each other. gh-recorder runs once a minute and is the only component that talks to GitHub. Each pass does two things: drain the outbox (every pending write, executed with retries), and refresh local snapshots of every tracked PR into gh-store — meta, the full comment inventory reconciled across all three channels, review states, CI buckets, with image attachments in comments downloaded and transcribed too. Line scripts and containers read these snapshots and never touch GitHub.

Housekeeping: the task worktree pool reaps husks after 48 hours; idle per-PR service groups are stopped after an hour with volumes kept, so the next round starts warm. ClickHouse collects metrics; `hfv ps` / `hfv log` / `hfv follow` give a live task view.

## Install

Prerequisites: Linux with a systemd user session, Docker, Node 22+, Python 3.11+, uv, Google Chrome, and a desktop session (lark-mcp's encrypted token store needs the D-Bus Secret Service).

```bash
git clone <this-repo> ~/hands-free-vibe && cd ~/hands-free-vibe
bash install.sh
```

install.sh checks the prerequisites, installs the cline CLI, installs the MCP tools from the official npm registry and generates wrappers that pin the desktop-session environment, creates the site configs from templates, builds the `hfv-task:base` image, and installs the systemd units. Idempotent; `--check` verifies without changing anything.

First golden bootstrap: start one throwaway container, bring the stack up with `ragflow-up.sh`, log in once via the browser, then `docker commit <container> hfv-task:latest`. The golden is frozen afterwards — nothing flows back from task runs; updates go through a manual bootstrap pass.

Site configuration (all gitignored, never committed): copy `hfv.conf.example` to `hfv.conf`, `issues/config.example` to `issues/config`, and put your LLM keys in `model-keys.json`.

## Daily use

```bash
hfv on                    # enable every line (1 instance each)
hfv scale issue 2         # run 2 parallel issue instances
hfv ps                    # task view: what every line instance is working on
hfv log / hfv follow      # read logs (defaults to the first running task)
hfv run [n]               # trigger an issue run right now
hfv stop                  # stop everything (containers included)
```

## Scope

It is built for one repository plus one Feishu group and does not try to be general. Site-specific configuration (repo paths, GitHub identities, the merge owner, Feishu credentials) is gitignored throughout; templates live in `hfv.conf.example` and `issues/config.example`.

## License

[MIT](LICENSE)
