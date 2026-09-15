# hands-free-vibe

[中文](README.zh-cn.md)

hands-free-vibe (hfv) is an unattended maintenance robot for one open-source
repository — a RAGFlow fork. Bug reports arrive in a Feishu group; what comes
out is pull requests on GitHub, plus everything between review and merge. Nobody
is in the loop: claiming, reproducing, fixing, verifying, delivering, answering
reviewers, rebasing, and the merge-readiness report all happen on their own.

## The life of one report

**Intake.** A recorder daemon scans the Feishu group on a timer. New reports
land in a local store as opaque records; attachments are downloaded, and
screenshots and screen recordings are transcribed into text by a vision model,
so the fixer never has to open an image. The recorder is a generic component
with pluggable sources — GitHub issues once fed the same store as a second
source (that line is retired, the code remains), and downstream stages only ever
dispatch on the message_id prefix, never on where a record came from.

**The fix.** Every task runs in a throwaway container. The golden image is
frozen: the full service stack (MySQL / Elasticsearch / Redis / MinIO / NATS),
the model providers, and the login state are all baked in, and task containers
never see each other. The agent reproduces and verifies for real inside — the
whole app is launched, browser-level checks run through the chrome-devtools
MCP, tests run in tiers — instead of arguing from the diff alone.

**Delivery.** The agent never touches git. It stages files — branch name,
commit message, PR title and body, verification screenshots — and a host-side
script takes over: a backup ref first, then an ownership check on the staged
content (a mismatched worktree stamp gets archived, not shipped), then commit
and push. The classic ways this used to go wrong — sweeping the whole worktree
pool into a commit, an empty staged set, delivering at the main-repo root — all
have hard guards that refuse outright.

**Every GitHub call funnels through one background service.** gh-recorder runs
once a minute and is the only component that talks to GitHub. Every write —
creating a PR, posting a comment, flipping a label, even a git push — is
enqueued to an on-disk outbox first and executed with retries, with dependency
chaining (a "fixed" reply only posts once its push has actually landed). Pushes
pass three guards: pool worktrees only, the fork remote only, never the base
branch. The same service asynchronously scans every tracked PR: a complete
comment inventory reconciled across all three channels, review states, CI
buckets, and image attachments in comments are downloaded and transcribed too.
Line scripts and containers read local snapshots and never touch GitHub; the
containers carry no credentials at all.

**Follow-through.** Four lines share the work after a PR goes out. The review
line reads new review comments from the snapshot, judges which are valid,
fixes, pushes and answers item by item. The rebase line sends conflict-free
branches through a fifteen-second script-only fast path and only spends an LLM
on real conflicts; its force-with-lease push goes through the outbox as well.
The ci line watches check runs, tells flakes from real failures, re-trips the
label-gated suite, fixes our own PRs and leaves a comment on external ones. And
follow is a script-only state machine: merged/closed flips, stall nudges, and
the "ready to merge" DM.

**The reverse role.** The pr-audit line reviews other people's PRs to the
upstream repo: the recorder has the meta and comments pre-scanned, the audit
actually launches the app in a container for end-to-end verification, and the
verdict is LGTM / PROBLEMS / INCOMPLETE. An LGTM applies the gate label — the
same merge signal our own deliveries use.

**It gets better at its job.** Every task writes lessons into a rolling
playbook; an effect engine ranks them by how many iterations they saved on
later runs — the useful ones float up, the stale ones sink and get purged. The
playbook keeps its rolling and archive sections apart and enforces a language
gate on each.

## Shape

systemd user timers drive the lines, and the lines are independent of each
other. Each line scales on its own (`hfv scale <line> <n>`) with per-instance
locks and modulo sharding so instances never step on each other. The task
worktree pool reaps husks after 48 hours; idle per-PR service groups are
stopped after an hour (volumes kept, so the next round starts warm). ClickHouse
collects metrics; `hfv ps` / `hfv log` / `hfv follow` give a live task view.

There is also a manual feat line: `hfv feat -f spec.md` implements a full
feature from a spec document and reuses the same delivery machinery.

## Scope

It is built for one repository plus one Feishu group and does not try to be
general. Site-specific configuration (repo paths, GitHub identities, the merge
owner, Feishu credentials) is gitignored throughout; templates live in
`hfv.conf.example` and `issues/config.example`.

## Install

Prerequisites: Linux with a systemd user session, Docker, Node 22+, Python
3.11+, uv, Google Chrome, and a desktop session (lark-mcp's encrypted token
store needs the D-Bus Secret Service).

```bash
git clone <this-repo> ~/hands-free-vibe && cd ~/hands-free-vibe
bash install.sh
```

install.sh checks the prerequisites, installs the cline CLI, installs the MCP
tools from the official npm registry and generates wrappers that pin the
desktop-session environment, creates the site configs from templates, builds
the `hfv-task:base` image, and installs the systemd units. Idempotent;
`--check` verifies without changing anything.

First golden bootstrap: start one throwaway container, bring the stack up with
`ragflow-up.sh`, log in once via the browser, then `docker commit <container>
hfv-task:latest`. The golden is frozen afterwards — nothing flows back from
task runs; updates go through a manual bootstrap pass.

## Daily use

```bash
hfv on                    # enable every line (1 instance each)
hfv scale issue 2         # run 2 parallel issue instances
hfv ps                    # task view: what every line instance is working on
hfv log / hfv follow      # read logs (defaults to the first running task)
hfv run [n]               # trigger an issue run right now
hfv stop                  # stop everything (containers included)
```

## License

[MIT](LICENSE)
