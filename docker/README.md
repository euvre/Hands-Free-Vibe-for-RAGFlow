# docker/ — N-slot concurrency infrastructure

Turns the daemon from "one LLM run at a time on the host" into "N worker
containers, each running one issue task", WITHOUT docker-in-docker.

## Why no DinD (design constraint)

Running a docker daemon inside each worker container (true DinD) needs
`--privileged`, overlayfs-on-overlayfs storage, and manual cgroup wiring —
fragile and a security hole. We don't need it: a task run only needs docker
to manage the RAGFlow service stack (ES/MySQL/Redis/MinIO/NATS), and that is
done through the regular HOST daemon via the mounted `/var/run/docker.sock`
(worker ships docker CLI + compose plugin only, `--group-add <socket-gid>`).

## Architecture

```
HOST (framework, systemd template units)
  cline-feishu-triage@<n>.timer → cline-feishu-triage@<n>.service
    Environment=HFV_SLOT=<n> flows through EVERY framework script:
      ExecStartPre   pre-task.sh     (Feishu scan+vision gated to slot 1)
      ExecStart      run-slot.sh <n> (bootstrap + docker run, see below)
      ExecStartPost  post-task.sh    (reply / deliver / release / close)
    OnFailure=cline-feishu-post-onfail@<n>.service (same post group)

  Per-slot state, derived from HFV_SUF="-s<n>" (empty = legacy host run,
  byte-identical historical names — zero regression while both coexist):
    run-s<n>.lock  issues/current-s<n>.json  deliver-s<n>/
    logs/.rested-s<n>  logs/run-<ts>-s<n>.log (still matches the
    summarize-run.sh `run-2*.log` glob)  tasks/.current-s<n>
    tasks/.last-run-info-s<n>
  Shared state, lock-protected:
    issues/issues.jsonl + .store.lock    — in_flight_slot markers (slot n,
      or "host" for the legacy line) make a pick exclusive across ALL lines;
      released by post-task (issue-release.py), self-heal in issue-select.sh
      when the owning line's run-s<n>.lock / run.lock is free (crash path)
    tasks/tasks.jsonl + .registry.lock   — tasks.py assign/close/abandon
      serialized (task_id stays monotonic across slots)
    ClickHouse (cline-clickhouse.service, loopback-only) exposed to
      containers via cline-ch-forward.service (socat 18123→8123, range
      172.16.0.0/12); workers reach it as host.docker.internal:18123

WORKER CONTAINER hfv-worker-s<n> (one issue task, ~5-7 GB RSS)
  Image = SYSTEM LAYER ONLY: chrome, node 22 + cline CLI + chrome-devtools-mcp,
  go 1.26, uv, docker CLI + compose plugin, socat, tini. No repo, no venv.
  worker-entrypoint.sh lives BOTH baked into the image (/usr/local/bin, keeps
  bare `docker run hfv-worker` usable for debugging) and in the mounted hfv
  repo — rebuild only when the toolchain changes, edit the mounted copy to
  iterate on the port-forward table.
  Mounts (same paths inside and outside, so prompt-baked paths always work):
    /home/inf/hands-free-vibe           framework repo (rw: logs, deliver,
                                         breadcrumbs, model-keys.json)
    /home/inf/.cline/data/sessions      shared sessions (breadcrumb matching
                                         keys on cwd — unique per slot)
    /home/inf/hfv-slots/slot<n>/        ragflow clone + chrome login profile
                                         + uv/go/npm caches (persists)
    /home/inf/.gitconfig                docker/gitconfig.worker (ro — no gh
                                         credential helper inside workers)
    /var/run/docker.sock                sibling stack management only
  Inside the container the task is EXACTLY the host dev flow:
    - fresh ragflow clone at /home/inf/hfv-slots/slot<n>/ragflow
      (--reference to the host repo: no history re-download; remotes
      mirrored verbatim so host-side delivery pushes identically)
    - ragflow-up.sh starts the py/go/web stacks as container processes on
      container-localhost (9380/9383/9384/9222 exist only inside → zero
      host port conflicts across slots and with the host dev stack)
    - conf/service_conf.yaml stays BYTE-IDENTICAL to origin/main: instead of
      editing its localhost endpoints, worker-entrypoint.sh runs socat
      forwards on container-localhost:
        1200→es01:9200  3306→mysql:3306  6379→redis:6379
        9000→minio:9000 9001→minio:9001 4222→nats:4222
        6380→host.docker.internal:6380   (host tei-cpu, shared+stateless)
        8123→host.docker.internal:18123  (host ClickHouse via ch-forward)
    - chrome-devtools-mcp runs headless with a per-slot userDataDir (browser
      login state persists across runs/retries, like on the host)

  Sibling service stack, per slot, via the socket:
    docker compose -p hfv-svc-<n> --env-file <ragflow4>/docker/.env \
      -f docker/svc-compose.yml up -d
    (es01, mysql, redis, minio, nats — NO published host ports; the worker
     was started with --network hfv-net-<n> so DNS resolves both ways.
     Volumes are project-scoped → per-slot service data persists across
     ticks: logins, datasets and ES indices survive between runs.
     The SAME host .env provides the passwords the tracked
     conf/service_conf.yaml expects. tei is deliberately NOT duplicated:
     embeddings are stateless and shared from the host container.)

  PID namespace isolation also fixes the old hazard of ragflow-up.sh's
  global pattern kills: a worker only sees its own processes, and
  mcp-cleanup.sh treats tini (container PID 1) as an orphan parent.

## Secrets boundary

  Into the container:  model keys (ride the hfv repo mount via
                       model-keys.json → -P/-m/-k CLI args), git identity
                       (docker/gitconfig.worker: user only, NO credential
                       helper).
  NOT into containers: gh token — push/PR stay host-side: post-deliver.sh
                       runs issue-deliver.sh from the SLOT workdir
                       (config.sh points RAGFLOW_MAIN at the slot clone when
                       HFV_SLOT is set) using the host ~/.gitconfig + gh.
                       Feishu app credentials — reply/sync/claim stay
                       host-side in the pre/post groups.

## Slot lifecycle

  1. run-slot.sh bootstraps the slot once (clone, caches, image, svc stack)
     and stays a no-op-fast path afterwards
  2. pre group: issue-select picks ONE open record under the store lock,
     marks it in_flight_slot=<n>; tasks.py assign numbers it under the
     registry lock into the slot's own current file
  3. docker run --rm hfv-worker → worker-entrypoint.sh (socat + readiness)
     → run-task.sh (per-slot run-s<n>.lock, same retry/breadcrumb logic)
  4. host post group consumes the slot's deliver-s<n>/ files, pushes + PRs
     from the slot workdir, replies in the thread, releases the in-flight
     marker, closes the task row
  5. slot stack keeps idling (warm next tick); `hfv slot down <n>` stops it
     without dropping data (`--purge` also drops volumes + the clone)

## Enabling slots (rollout)

  One-time:
    systemctl --user daemon-reload
    systemctl --user enable --now cline-ch-forward.service
    bash docker/build-worker.sh        # or let run-slot.sh build on demand

  The legacy single-run units (cline-feishu-triage.service/.timer) keep
  working untouched — HFV_SLOT unset means "the historical host run". To
  parallelize, DISABLE the legacy timer and enable one template timer per
  slot (slot 1 also does the Feishu recorder/vision sweep for everyone):

    systemctl --user disable --now cline-feishu-triage.timer
    hfv slot up 1
    # trigger immediately instead of waiting for the first tick (~30s):
    hfv slot run 1          # or: hfv slot run all — every enabled slot
    # later, memory permitting:
    hfv slot up 2

  Memory budget (~62 GB host): each slot ≈ ES ≤8G + mysql ~1G + minio/redis/
  nats ~1G + worker 5-7G ≈ 15-17G. Start with one slot beside the host dev
  stack (~29G available today), add the second after the host stack retires.

  Known shared leftovers (documented, acceptable):
    - tasks/.pin is a single manual pin file (hfv task resume/follow); a
      pinned task is also in_flight-marked, so slots still cannot collide
    - Feishu claim replies are mid-keyed and unique across slots
