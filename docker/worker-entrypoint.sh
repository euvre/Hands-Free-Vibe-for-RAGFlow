#!/usr/bin/env bash
# worker-entrypoint.sh — PID-1 (tini) child for a hfv-worker slot container.
#
# Job: make the per-slot sibling service stack (hfv-net-<slot>, started by
# run-slot.sh through the host docker socket) look EXACTLY like the host dev
# environment, then exec the framework runner:
#
#   * conf/service_conf.yaml is git-tracked and hardcodes container-localhost
#     service endpoints (es localhost:1200, mysql 3306, redis 6379, minio
#     9000/9001, nats 4222, tei localhost:6380) — editing it inside the fresh
#     slot clone would leave a dirty tree that leaks into delivery. Instead
#     socat binds those ports on container-localhost and forwards to the
#     sibling service DNS names (es01:9200, mysql:3306, …) → the conf file
#     stays byte-identical to origin/main.
#   * tei (embeddings) and ClickHouse (metrics) stay on the HOST: forwarded
#     via host.docker.internal (host-gateway; see cline-ch-forward.service).
#   * waits for every endpoint to actually answer before handing over to
#     run-task.sh, so the LLM agent never races a booting service. First
#     ES boot initializes its volume and can take a couple of minutes.
set -u
export HOME=/home/inf
: "${HFV_SLOT:?run-slot.sh must set HFV_SLOT}"

# local-port : upstream-host : upstream-port
FORWARDS=(
  "1200:es01:9200"
  "3306:mysql:3306"
  "6379:redis:6379"
  "9000:minio:9000"
  "9001:minio:9001"
  "4222:nats:4222"
  "6380:host.docker.internal:6380"   # host tei-cpu (shared, stateless)
  "8123:host.docker.internal:18123"  # host cline-clickhouse via cline-ch-forward
)

for f in "${FORWARDS[@]}"; do
  lport="${f%%:*}"; rest="${f#*:}"; rhost="${rest%%:*}"; rport="${rest#*:}"
  socat TCP-LISTEN:"$lport",bind=127.0.0.1,fork,reuseaddr TCP:"$rhost":"$rport" &
done

# --- readiness: deep probes (a plain TCP connect would succeed against the
# socat listener even with the upstream dead). 5-minute budget per endpoint.
http_ok() { # http_ok <port> — any HTTP status (even 401/404) proves the path
  local code
  code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$1/" 2>/dev/null || true)"
  [[ "$code" != "" && "$code" != "000" ]]
}
banner_ok() { # banner_ok <port> — server speaks first (mysql greeting, nats INFO)
  timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1 && head -c1 <&3 >/dev/null" 2>/dev/null
}
redis_ok() {
  # svc redis runs with requirepass: an unauthenticated PING answers
  # "-NOAUTH ..." — any protocol answer (PONG or the NOAUTH error) proves
  # the endpoint is up; no password needed inside the worker.
  printf 'PING\r\n' | timeout 3 socat - TCP:127.0.0.1:"$1" 2>/dev/null | grep -qE 'PONG|NOAUTH'
}

wait_for() { # wait_for <label> <probe-cmd...>
  local label="$1"; shift
  local i
  for i in $(seq 1 60); do
    "$@" && { echo "[worker] $label ready"; return 0; }
    sleep 5
  done
  echo "[worker] WARNING: $label not answering after 300s — continuing anyway" >&2
}

wait_for "es01(http://localhost:1200)"  http_ok 1200
wait_for "mysql(localhost:3306)"        banner_ok 3306
wait_for "redis(localhost:6379)"        redis_ok 6379
wait_for "minio(localhost:9000)"        http_ok 9000
wait_for "minio-console(localhost:9001)" http_ok 9001
wait_for "nats(localhost:4222)"         banner_ok 4222
wait_for "tei(host:6380)"               http_ok 6380
wait_for "clickhouse(host:18123)"       http_ok 8123

echo "[worker] slot=$HFV_SLOT all forwards up; exec: $*"
exec "$@"