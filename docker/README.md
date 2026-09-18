# docker/ — hfv-task all-in-one task container

Every task run (issue fix, PR review/rebase/ci/audit/repr, feat) executes in
ONE throwaway container off the frozen `hfv-task` image. The image bakes the
full service stack (MySQL / Elasticsearch / Redis / MinIO / NATS via
supervisord), the model providers and the browser login state, so a task
container needs nothing from the host but bind mounts.

## Architecture

```
HOST (framework, systemd template units)
  cline-feishu-triage@<n>.timer → cline-feishu-triage@<n>.service
    Environment=HFV_SLOT=<n> flows through EVERY framework script:
      ExecStartPre   pre-task.sh      (Feishu scan+vision on slot 1; select →
                                       claim → start notice → sheet write-back)
      ExecStart      run-container.sh (docker run --rm hfv-task … run-task.sh)
      ExecStartPost  post-task.sh     (reply / deliver / sheet / sync /
                                       release / close)
    OnFailure=cline-feishu-post-onfail@<n>.service (same post group)

TASK CONTAINER hfv-task-<ts>-s<n> (one task, throwaway, --rm)
  task-entrypoint.sh (tini → supervisord): the whole service stack starts
  INSIDE the container (docker/task-services.conf), data lives on container
  volumes — containers never share state.
  Mounts (same paths inside and outside, so prompt-baked paths always work):
    /home/inf/hands-free-vibe           framework repo (rw: logs/, deliver-s*/,
                                        state/, locks/)
    /home/inf/.cline/data/sessions      shared sessions (breadcrumb matching
                                         keys on cwd — unique per slot)
    /home/inf/hfv-cache/{uv,go,go-build,npm}  build caches (shared, persist)
    /home/inf/ragflow-native-libs       ORT/native libs (build.sh hardcodes it)
    <ragflow4> + <worktree>             the main clone and this task's worktree
    docker/gitconfig.worker             git identity ONLY (ro — no credential
                                         helper, see secrets boundary)
  NOT mounted: /var/run/docker.sock — the worker-era sibling-stack management
  is gone; the service stack runs inside, not beside, the container.

## Secrets boundary

  Task containers carry ZERO credentials. git push / gh / Feishu writes all
  stay host-side: the agent stages deliverables as files under deliver-s<n>/
  (reply-*.md, branch.txt, pr-title.txt, pr-body.md, shots/), the post group
  ships them, and every GitHub mutation goes through the disk outbox
  (lines/gh-outbox.py → gh-recorder; comments carry an idempotency key).
  Exception: PR read access (comment inventory) for the review/audit lines —
  run-container.sh --creds mounts ~/.config/gh read-only and exports GH_TOKEN.
  Feishu app credentials never enter containers: reply/sync/claim/sheet
  write-back all run in the host-side pre/post groups.

## Shared state

  issues/issues.jsonl + locks/.store.lock — in_flight_slot markers make a pick
    exclusive across all lines; released by post-task (issue-release.py),
    self-heal in issue-select.sh when the owning line's locks/run-s<n>.lock is
    free (crash path)
  tasks/tasks.jsonl + tasks/.registry.lock — tasks.py assign/close serialized
  locks/    — every flock file (run*, pr-*, .store.lock, .gh-recorder.lock, …)
  state/    — runtime markers (.scale-*, .current-*, .model-profile, …)
  ClickHouse (cline-clickhouse.service, loopback-only) is exposed to
    containers via cline-ch-forward.service (socat 18123→8123); containers
    reach it as host.docker.internal:18123 (--add-host …:host-gateway).

## Files here

  Dockerfile.task        the hfv-task image (frozen golden base)
  task-entrypoint.sh     PID-1 child: supervisord + env sync + login refresh
  task-services.conf     the in-container service stack definition
  gitconfig.worker       container git identity (ro mount; no credentials)
  mcp-settings.worker.json  chrome-devtools-mcp config sample (copied manually
                         into sessions; not referenced by code)
```
