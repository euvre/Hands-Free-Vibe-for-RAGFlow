#!/usr/bin/env bash
# task-entrypoint.sh — PID-1 (tini) child for an hfv-task all-in-one container.
#
# Lifecycle:
#   1. start the in-container service stack via supervisord (mysql / es /
#      redis / minio / nats — see task-services.conf);
#   2. FIRST BOOT ONLY (mysql's rag_flow DB absent): set the root password and
#      apply docker/init.sql from the mounted repo — later boots (i.e. runs off
#      the frozen golden image, whose data dirs are already populated) skip this;
#   3. socat-forward the host's shared stateless services (tei embeddings,
#      ClickHouse metrics) onto container-localhost, so the git-tracked
#      conf/service_conf.yaml keeps working byte-identical;
#   4. wait for every endpoint to actually answer (deep probes — a plain TCP
#      connect would succeed against a dead upstream's socat listener);
#   5. drop to the unprivileged user and exec the framework runner.
#
# ragflow itself is NOT started here: the task flow's env-up.sh →
# framework/ragflow-up.sh does that (and its launch_backend_service.sh carries
# the DB migrations).
set -u
export HOME=/home/inf
REPO="${RAGFLOW_MAIN:-/home/inf/code/ragflow4}"

mkdir -p /var/log/hfv-task
/usr/bin/supervisord -c /etc/supervisor/supervisord.conf >>/var/log/hfv-task/supervisord.log 2>&1 &

# host-shared stateless services onto container-localhost (same trick as the
# slot workers: tei embeddings, ClickHouse metrics)
socat TCP-LISTEN:6380,bind=127.0.0.1,fork,reuseaddr TCP:host.docker.internal:6380 &
socat TCP-LISTEN:8123,bind=127.0.0.1,fork,reuseaddr TCP:host.docker.internal:18123 &

# --- readiness probes (5-min budget per endpoint) ---------------------------
http_ok() {
  local code
  code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$1/" 2>/dev/null || true)"
  [[ "$code" != "" && "$code" != "000" ]]
}
banner_ok() { timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1 && head -c1 <&3 >/dev/null" 2>/dev/null; }
redis_ok() { printf 'PING\r\n' | timeout 3 socat - TCP:127.0.0.1:"$1" 2>/dev/null | grep -qE 'PONG|NOAUTH'; }

wait_for() {
  local label="$1"; shift
  for _ in $(seq 1 60); do
    "$@" && { echo "[task] $label ready"; return 0; }
    sleep 5
  done
  echo "[task] WARNING: $label not answering after 300s — continuing anyway" >&2
}

wait_for "mysql(localhost:3306)"        banner_ok 3306

# first boot: debian's mysql data dir has no rag_flow DB yet → set the root
# password to the repo's dev credential and apply the tracked init.sql.
if ! mysql -uroot -pinfini_rag_flow -e 'USE rag_flow' >/dev/null 2>&1; then
  echo "[task] first boot: initializing mysql root password + init.sql"
  # debian's mysql initializes root@localhost to auth_socket — connect over the
  # socket without a password on first boot, then switch to the dev credential
  mysql -uroot --socket=/var/run/mysqld/mysqld.sock <<'SQL'
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'infini_rag_flow';
CREATE DATABASE IF NOT EXISTS rag_flow;
SQL
  [[ -f "$REPO/docker/init.sql" ]] && mysql -uroot -pinfini_rag_flow < "$REPO/docker/init.sql" || true
fi

wait_for "es(http://localhost:1200)"      http_ok 1200
wait_for "redis(localhost:6379)"        redis_ok 6379
wait_for "minio(localhost:9000)"        http_ok 9000
wait_for "minio-console(localhost:9001)" http_ok 9001
wait_for "nats(localhost:4222)"         banner_ok 4222
wait_for "tei(host:6380)"               http_ok 6380
wait_for "clickhouse(host:8123)"        http_ok 8123

echo "[task] stack ready; exec runner as inf: $*"
# venv: the host's .venv is glibc-pinned to the host (its numpy was built
# against GLIBC_2.43 and cannot load under this container's 2.39). Build the
# container's own venv ONCE into /home/inf/venv-base (it lives in the frozen
# golden image; only a manual golden rebuild re-runs this), then link it into
# the
# mounted worktree so ragflow-up.sh's `source .venv/bin/activate` works
# unchanged.
if [[ ! -x /home/inf/venv-base/bin/python ]]; then
  echo "[task] first boot: building the container venv (uv sync; warm after the first golden commit)"
  su -s /bin/bash inf -c "UV_PROJECT_ENVIRONMENT=/home/inf/venv-base uv sync --project '$REPO'" >>/var/log/hfv-task/uv-sync.log 2>&1 || true
fi
# Point the container venv through HFV_VENV (ragflow-up.sh reads it). No mount
# tricks: bind-mounting over $REPO/.venv inside an already-bind-mounted repo
# fails in this namespace, and needs no SYS_ADMIN at all.
export HFV_VENV=/home/inf/venv-base
# drop privileges for the actual work (bind-mounted files keep host
# ownership). "$@" preserves argument boundaries — never re-wrap through
# `bash -c "... $*"`: a runner string containing ';' would be split there.
exec setpriv --reuid inf --regid inf --init-groups -- "$@"
