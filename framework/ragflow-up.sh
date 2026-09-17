#!/usr/bin/env bash
# ragflow-up.sh — one-shot dev-services launcher for the ragflow4 workspace.
#
# Usage:
#   bash /home/inf/hands-free-vibe/ragflow-up.sh          restart all dev services
#   bash /home/inf/hands-free-vibe/ragflow-up.sh --watch  (internal) readiness watcher
#
# What a restart does:
#   1. kills the previous service TREES, not just port listeners:
#        - python stack: bash docker/launch_backend_service.sh + its port-less
#          redis workers rag/svr/task_executor.py (~1.2GB RSS each)
#        - go stack:     bash build.sh --run + bin/ragflow_server
#                        --api/--admin/--ingestor (ingestor listens on no port)
#        - web stack:    bash -c "... npm run dev" + sh/vite/esbuild children
#   2. sweeps leftover port listeners (9380 py api / 9383 go admin /
#      9384 go api / 9222 vite) with fuser/lsof as a catch-all.
#   3. reaps the stale watcher from the previous launch via pidfile.
#   4. starts python/go/web detached (logs: /tmp/ragflow-{backend,go,web}.log)
#      and forks the watcher, which mirrors readiness progress into
#      $RAGFLOW_STATUS_FILE (default /tmp/ragflow-ready.status).
#
# KILL-SAFETY (hard rule, do not relax): every stale-process match below is a
# ^-anchored, argv-shaped regex. NEVER turn these into plain substrings or
# pkill -f: the cline agent's own cmdline embeds the task-file text (it
# literally contains "task_executor.py", "launch_backend_service.sh",
# All kills skip our own process group.
#
# Safe to re-run: a re-run IS a restart. Normally returns in ~1s; worst case
# ~12s (graceful-shutdown grace for workers). Judge readiness later by
# cat-ing the status file (all=READY / all=TIMEOUT, ~7.5min budget).
set -u
HFV_DIR="$HOME/hands-free-vibe"
source "$HFV_DIR/config.sh"

REPO="$RAGFLOW_MAIN"
STATUS="${RAGFLOW_STATUS_FILE:-/tmp/ragflow-ready.status}"
WATCH_PIDFILE=/tmp/ragflow-watch.pid
PORTS=(9380 9383 9384 9222)

# --- demo login seed ---------------------------------------------------------
# Every throwaway group DB starts EMPTY (fresh volume): the hard-rule browser
# account 1@1.com/1 (task.md) does not exist until something creates it, and
# self-registration is not a sanctioned path. Seed it ONCE per ragflow-up run,
# right after the python api reports READY (its launch does DB init +
# migrations, so the tables are guaranteed to exist by then). Idempotent:
# INSERT IGNORE by primary key — re-runs and pre-seeded DBs (audit/slot
# clusters) are no-ops. The scrypt hash below is the verified one for the
# demo account (the password is literally "1") — NOT a newly-invented
# credential.
seed_demo_user() { # seed_demo_user — idempotent; needs the worktree venv on PATH
  python3 - <<'PY' >/dev/null 2>&1 || true
import os, sys, time
sys.path.insert(0, os.environ.get("PYTHONPATH", "."))
try:
    from api.db.db_models import DB
except Exception:
    sys.exit(1)
now_ms = int(time.time() * 1000)
now_s = time.strftime("%Y-%m-%d %H:%M:%S")
uid = "a11e48de4d5043ec8e1936651c935057"
pw = "scrypt:32768:8:1$CwxQMZqhnw69Ay7F$e0fca0d3c3b906a03867a232abe70920f63ecef7e725489d9ba2d64cfe369e31bf40ff42503c896797e95eb276845aa89d4a3518e02411d0274a3c9ce1f4fdd7"
parsers = "naive:General,qa:Q&A,manual:Manual,table:Table,paper:Research Paper,book:Book,laws:Laws,presentation:Presentation,picture:Picture,one:One,audio:Audio,email:Email,tag:Tag"
try:
    with DB.atomic():
        DB.execute_sql(
            "INSERT IGNORE INTO user (id,create_time,create_date,update_time,update_date,nickname,password,email,language,color_schema,timezone,is_authenticated,is_active,is_anonymous,login_channel,status,is_superuser)"
            " VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
            (uid, now_ms, now_s, now_ms, now_s, "1", pw, "1@1.com", "en", "Bright", "UTC+8\tAsia/Shanghai", "1", "1", "0", "password", "1", 0))
        DB.execute_sql(
            "INSERT IGNORE INTO tenant (id,create_time,create_date,update_time,update_date,name,llm_id,embd_id,asr_id,img2txt_id,rerank_id,tts_id,ocr_id,parser_ids,credit,status)"
            " VALUES (%s,%s,%s,%s,%s,%s,'','','','','','','',%s,512,'1')",
            (uid, now_ms, now_s, now_ms, now_s, "1's Kingdom", parsers))
        DB.execute_sql(
            "INSERT IGNORE INTO user_tenant (id,create_time,create_date,update_time,update_date,user_id,tenant_id,role,invited_by,status)"
            " VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,'1')",
            ("e6a31f8fb4384d0c86cad30fac69c855", now_ms, now_s, now_ms, now_s, uid, uid, "owner", uid))
except Exception:
    sys.exit(1)
print("demo user 1@1.com seeded (or already present)")
PY
}

if [[ "${1:-}" == "--watch" ]]; then
  py=PENDING; go=PENDING; web=PENDING; seeded=""
  for i in $(seq 1 90); do
    [ "$py" != READY ] && ss -tln | grep -q :9380 && py=READY
    [ "$py" = READY ] && [ -z "$seeded" ] && { seed_demo_user && seeded=1; }
    [ "$go" != READY ] && curl -sf -o /dev/null --max-time 3 http://127.0.0.1:9384/api/v1/system/version && go=READY
    [ "$web" != READY ] && curl -sf -o /dev/null --max-time 3 http://127.0.0.1:9222/ && web=READY
    printf 'py=%s go=%s web=%s elapsed=%ds\n' "$py" "$go" "$web" "$((i*5))" > "$STATUS"
    [ "$py" = READY ] && [ "$go" = READY ] && [ "$web" = READY ] && { echo all=READY >> "$STATUS"; exit 0; }
    sleep 5
  done
  echo all=TIMEOUT >> "$STATUS"
  exit 0
fi

# --- 1) stop stale service trees ------------------------------------------
MY_PGID="$(ps -o pgid= -p $$ | tr -d '[:space:]')"

# Stack supervisors. Killed whole-process-group FIRST so their retry loops
# die before they can respawn the children we kill right after.
# NOTE web: the launcher uses `bash -c "... && exec npm run dev"`, so after
# exec the supervisor's argv is literally "npm run dev" — hence that pattern.
TREE_PATTERNS=(
  '^bash .*docker/launch_backend_service\.sh'
  '^bash .*build\.sh --run'
  '^npm run dev'
)
# Port-less workers, plus orphans whose supervisor already died.
WORKER_PATTERNS=(
  '^python3 ([^ ]*/)?rag/svr/task_executor\.py'
  '^python3 ([^ ]*/)?api/ragflow_server\.py'
  '^([^ ]*/)?bin/ragflow_server --'
)

pids_of() { pgrep -f "$1" 2>/dev/null || true; }

kill_trees() { # kill_trees <SIG> — signal every stale supervisor's whole group
  local sig="$1" pat p pg
  for pat in "${TREE_PATTERNS[@]}"; do
    for p in $(pids_of "$pat"); do
      pg="$(ps -o pgid= -p "$p" 2>/dev/null | tr -d '[:space:]')"
      [[ -n "$pg" && "$pg" != "$MY_PGID" && "$pg" != 1 ]] || continue
      kill -s "$sig" -- "-$pg" 2>/dev/null || true
    done
  done
}

kill_workers() { # kill_workers <SIG> — signal stale/orphaned worker pids
  local sig="$1" pat p pg
  for pat in "${WORKER_PATTERNS[@]}"; do
    for p in $(pids_of "$pat"); do
      pg="$(ps -o pgid= -p "$p" 2>/dev/null | tr -d '[:space:]')"
      [[ "$pg" == "$MY_PGID" ]] && continue # never signal our own group
      kill -s "$sig" "$p" 2>/dev/null || true
    done
  done
}

stale_left() {
  local pat
  for pat in "${TREE_PATTERNS[@]}" "${WORKER_PATTERNS[@]}"; do
    pids_of "$pat" | grep -q . && return 0
  done
  return 1
}

if command -v pgrep >/dev/null 2>&1; then
  kill_trees TERM
  kill_workers TERM
  # python executors trap SIGTERM and drain gracefully; give them a moment
  for _ in $(seq 1 12); do
    stale_left || break
    sleep 0.5
  done
  if stale_left; then
    kill_trees KILL
    kill_workers KILL
    sleep 0.5
  fi
fi

# --- 2) sweep leftover port listeners; fuser errors on free ports are normal
for p in "${PORTS[@]}"; do
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "$p/tcp" >/dev/null 2>&1 || true
  else
    lsof -ti "tcp:$p" 2>/dev/null | xargs -r kill >/dev/null 2>&1 || true
  fi
done
# give the ports a moment to actually free (up to 5s), then proceed regardless
for _ in 1 2 3 4 5; do
  ss -tln | grep -qE ':(9380|9383|9384|9222) ' || break
  sleep 1
done

# --- 3) reap the stale watcher from the previous launch (best-effort; a missed
# pid only means one extra writer of identical probe results)
if [[ -f "$WATCH_PIDFILE" ]]; then
  wpid="$(cat "$WATCH_PIDFILE" 2>/dev/null || true)"
  [[ -n "$wpid" ]] && kill "$wpid" 2>/dev/null || true
  rm -f "$WATCH_PIDFILE"
fi

# --- 3.5) reset the readiness file BEFORE the new watcher starts: without
# this, a stale all=READY/all=TIMEOUT (baked into the golden image layer or
# left by a crashed run) gets read by env-up.sh's wait_status in the first
# seconds and misreported as THIS launch's outcome.
printf 'py=PENDING go=PENDING web=PENDING elapsed=0s\n' > "$STATUS"

# --- 4) launch all stacks detached ------------------------------------------
cd "$REPO"
# HFV_VENV overrides the venv path (default .venv). The all-in-one task
# container sets HFV_VENV=/home/inf/venv-base: the host's .venv is
# glibc-pinned (its numpy needs GLIBC_2.43; the container runs 2.39), so the
# container builds its own venv once into the image layer.
source "${HFV_VENV:-.venv}/bin/activate"
export PYTHONPATH="$REPO"
setsid bash docker/launch_backend_service.sh >/tmp/ragflow-backend.log 2>&1 </dev/null &
setsid bash -c "cd $REPO && { [[ -x bin/ragflow_server ]] || bash build.sh --go; } && bash build.sh --run" >/tmp/ragflow-go.log 2>&1 </dev/null &
# Web dev server: default the API proxy to the PYTHON backend. Upstream's
# web/.env.development pins API_PROXY_SCHEME='go', but in the throwaway
# groups the Go gateway is the first thing to die (ES ping / missing native
# deps) — with go selected, EVERY /api call 500s through the vite proxy and
# the hard-rule browser login (task.md) can never succeed; the LLM then burns
# a dozen iterations rediscovering this or works around the UI entirely.
# vite's loadEnv gives process.env
# priority over .env files, so this export wins; export API_PROXY_SCHEME=go
# before calling this script to opt back into the Go gateway explicitly.
setsid env API_PROXY_SCHEME="${API_PROXY_SCHEME:-python}" \
  bash -c "cd $REPO/web && exec npm run dev" >/tmp/ragflow-web.log 2>&1 </dev/null &
setsid bash "$0" --watch >/dev/null 2>&1 </dev/null &
echo $! > "$WATCH_PIDFILE"

echo "services launched; judge readiness with: cat $STATUS (all=READY within ~7.5min)"
exit 0
