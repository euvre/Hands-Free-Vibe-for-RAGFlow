# hands-free-vibe

[中文](README.md)

**hands-free-vibe (hfv)** is an unattended maintenance robot for an open-source
repository. It takes issue reports from a Feishu (Lark) group and drives the
full loop — **claim → reproduce → fix → verify → deliver a PR → follow the
review → rebase → report merge-readiness** — with an LLM agent (the Cline CLI)
running inside a throwaway Docker container per task.

## The lines

| Line | What it does |
|---|---|
| **issue** | Watches the Feishu group for new reports; screenshots are transcribed by a vision model, then the LLM reproduces/fixes/verifies in a one-shot container, delivers a PR and replies in the thread |
| **feat** | Manual (`hfv feat -f spec.md`): implements a full feature from a spec and delivers a PR |
| **pr-review** | Follows our submitted PRs: reads review comments, judges validity, fixes and replies |
| **pr-rebase** | Semantically rebases conflicted PRs onto main (conflict-free branches go through a script-only fast path) |
| **pr-audit** | The reverse role: reviews **other people's** PRs end-to-end and posts LGTM / PROBLEMS / INCOMPLETE (an LGTM auto-applies the gate label) |
| **pr-ci** | Locates and fixes CI failures automatically |
| **follow** | Script-only state machine: merged/closed flips, stalled-PR nudges, ready-to-merge DMs |

Supporting systems: a task-level playbook that improves itself (an
eight-houses effect engine ranks lessons by iterations saved), ClickHouse
metrics, and one throwaway container per task off a golden image that rolls
forward on clean exit (accounts / login state / model config persist via the
image layer).

## Architecture in one breath

Every LLM run happens inside a container (golden image `hfv-task:latest`, one
throwaway instance per task, `docker commit` rolls the golden forward on clean
exit); systemd user timers drive the lines; every line scales independently
(`hfv scale <line> <n>`) with per-instance locks and modulo candidate
sharding so instances never step on each other.

## Install

Prerequisites: Linux with a systemd user session, Docker, Node 22+, Python
3.11+, uv, Google Chrome, and a desktop session (lark-mcp's encrypted token
store needs the D-Bus Secret Service).

```bash
git clone <this-repo> ~/hands-free-vibe && cd ~/hands-free-vibe
bash install.sh
```

`install.sh` checks system prerequisites → installs the cline CLI →
**installs the MCP tools from the official npm registry**
(`@larksuiteoapi/lark-mcp`, `chrome-devtools-mcp`; the filesystem server runs
via npx) **and generates wrappers** that pin the desktop-session environment →
creates the site configs from templates → builds the `hfv-task:base` image →
installs the systemd units. Idempotent; `--check` verifies without changing
anything.

Then fill in the real configuration (all gitignored, never committed):

| File | Contents |
|---|---|
| `hfv.conf` | repo paths, GitHub identities, the merge owner, … (template: `hfv.conf.example`) |
| `issues/config` | Feishu group + app credentials, the Kimi key for vision transcription (template: `issues/config.example`) |
| `model-keys.json` | LLM key lists (rotated automatically on quota exhaustion) |

First golden bootstrap: start one throwaway container → bring the stack up
with `ragflow-up.sh` and log in once via the browser →
`docker commit <container> hfv-task:latest`.

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
