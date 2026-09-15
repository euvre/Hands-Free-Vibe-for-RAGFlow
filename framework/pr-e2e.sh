#!/usr/bin/env bash
# pr-e2e.sh — per-PR isolated end-to-end environment (one container group per PR).
#
# The PR follow-up lines (review/rebase in ragflow4 worktrees) run their LLM
# agents on the HOST, where the shared ragflow dev services (host ports
# 9380/9383/9384/9222 + the localhost es/mysql/... endpoints) belong to the
# issue line. docker/svc-compose.yml already supports N parallel groups (the
# slots prove it); this script gives ONE PR its own throwaway group reusing
# that machinery:
#
#   hfv-svc-pr<N>    service stack (es/mysql/redis/minio/nats) on its own
#                    network hfv-net-pr<N>; project-scoped volumes stay warm
#                    across review/rebase rounds of the same PR
#   hfv-e2e-pr<N>    hfv-worker container on that network. worker-entrypoint
#                    socat-forwards container-localhost service ports exactly
#                    like a slot worker, so the git-tracked
#                    conf/service_conf.yaml works byte-identically inside.
#                    The PR worktree AND its parent clone are mounted at their
#                    host paths (the worktree's .venv / web/node_modules
#                    symlinks into the clone keep resolving); per-PR
#                    go/uv/npm caches live under ~/hfv-slots/e2e/pr<N>/. App
#                    ports are relayed inside (0.0.0.0:29380/29383/29384/29222
#                    -> localhost 9380/9383/9384/9222) and published on
#                    127.0.0.1:<random> for browser-level e2e from the
#                    host-side agent.
#
# Usage (<num> must be numeric; every name is derived from it, so this can
# never touch the host stack, the slots, or another PR's group):
#   pr-e2e.sh up <num> <worktree>    bring the group up, wait for service
#                                    readiness (first boot ~3-8 min), print
#                                    the host port mapping
#   pr-e2e.sh exec <num> -- <cmd...> run a command inside the group, cwd = the
#                                    PR worktree; RAGFLOW_MAIN is preset to it
#                                    and HFV_SLOT cleared, so config.sh /
#                                    ragflow-up.sh resolve the right repo.
#                                    Ports and PID namespace are isolated:
#                                    ragflow-up.sh and friends are safe here.
#   pr-e2e.sh ports <num>            host port mapping (py 9380 / admin 9383 /
#                                    go 9384 / web 9222 via relay ports)
#   pr-e2e.sh status <num>           group state summary
#   pr-e2e.sh down <num>             stop container + services (volumes kept
#                                    warm); the line scripts call this as a
#                                    safety net after every LLM stage
#   pr-e2e.sh purge <num>            down + drop volumes, network and caches
set -u
DIR="$HOME/hands-free-vibe"
source "$DIR/config.sh"
LOG_DIR="$DIR/logs"
SVC_YML="$DIR/docker/svc-compose.yml"
ENVF="$RAGFLOW_HOST_REPO/docker/.env"
TZV="$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo Asia/Shanghai)"

log() { echo "[$(date +%Y%m%d-%H%M%S)] pr-e2e: $*" >> "$LOG_DIR/daemon.log"; }
die() { echo "pr-e2e: $*" >&2; exit 1; }
usage() {
  cat >&2 <<'USG'
usage: pr-e2e.sh up <num|audit> <worktree> | exec <num|audit> -- <cmd...> |
                 ports <num|audit> | status <num|audit> | down <num|audit> | purge <num|audit>

A numeric argument gives a throwaway per-PR cluster (hfv-svc-pr<N>).
Any other name is a named group (own namespace, volumes persist across runs).
USG
}

names() { # <num|name> — derive every group-local name from the argument
  case "$1" in
    *[!0-9]*) SUFFIX="$1" ;;      # named group (manual/debug use; volumes persist)
    *)        SUFFIX="pr$1" ;;    # numeric: throwaway per-PR cluster
  esac
  NET="hfv-net-$SUFFIX"; PROJ="hfv-svc-$SUFFIX"
  CTR="hfv-e2e-$SUFFIX"; STATE="$LOG_DIR/e2e-$SUFFIX.env"
  E2E_ROOT="$HOME/hfv-slots/e2e/$SUFFIX"
}

wt_of_state() { # worktree recorded by 'up' (empty when absent)
  [[ -s "${STATE:-}" ]] && sed -n 's/^WORKTREE=//p' "$STATE" | head -1 || true
}

do_up() { # <num> <worktree>
  local num="$1" wt="$2" clone i r
  [[ -d "$wt" ]] || die "worktree $wt not found"
  clone="$(dirname "$(dirname "$wt")")"
  command -v docker >/dev/null 2>&1 || die "docker CLI missing"
  [[ -n "$(docker images -q hfv-worker:latest)" ]] \
    || die "hfv-worker image missing (bash $DIR/docker/build-worker.sh)"
  HFV_SLOT="$SUFFIX" docker compose -p "$PROJ" --env-file "$ENVF" -f "$SVC_YML" up -d \
    >>"$LOG_DIR/daemon.log" 2>&1 || die "service stack up failed (see daemon.log)"
  if [[ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null)" == "true" ]] \
     && [[ "$(wt_of_state)" == "$wt" ]]; then
    echo "pr-e2e: $CTR already up — reusing"
  else
    # no worker, or the live worker still points at a STALE worktree
    # (a named group serves different worktrees across uses) — (re)create it.
    docker rm -f "$CTR" >/dev/null 2>&1 || true
    mkdir -p "$E2E_ROOT/go" "$E2E_ROOT/go-build" "$E2E_ROOT/uv-cache" "$E2E_ROOT/npm-cache"
    # native-libs view: upstream build.sh --go does `mkdir -p` + `ln -sf`
    # INSIDE $HOME/ragflow-native-libs (paths hardcoded, and build.sh runs
    # under set -e), so the read-only bind-mount breaks every in-container
    # WRITABLE mirror instead. Entries are HARDLINKS (-P: files and symlinks
    # alike), not symlinks — build.sh finds ORT archives via
    # `find -type f -name '*.a'`, which never matches a symlink. Hardlinks
    # share the inode (zero copy, same fs under $HOME); a container-side
    # `ln -sf` replacement only drops the view's link, never the real file;
    # cp -a is the cross-fs fallback.
    local nlview="$E2E_ROOT/native-libs"
    if [[ ! -e "$nlview/office_oxide" ]]; then
      ( cd "$HOME/ragflow-native-libs" \
        && find . -type d -exec mkdir -p "$nlview/{}" \; \
        && find . ! -type d -print0 | while IFS= read -rd '' p; do
             ln -P "$p" "$nlview/$p" 2>/dev/null || cp -a "$p" "$nlview/$p"
           done ) >>"$LOG_DIR/daemon.log" 2>&1 || die "native-libs view build failed"
    fi
    docker run -d \
      --name "$CTR" \
      --network "$NET" \
      --add-host host.docker.internal:host-gateway \
      --shm-size 2g \
      -e HFV_SLOT="$SUFFIX" \
      -e TZ="$TZV" \
      -v "$wt":"$wt" \
      -v "$clone":"$clone" \
      -v "$DIR":"$DIR" \
      -v "$HOME/ragflow-native-libs":/mnt/native-libs-ro:ro \
      -v "$nlview":/home/inf/ragflow-native-libs \
      -v /usr/share/infinity/resource:/usr/share/infinity/resource:ro \
      -v "$HOME/.local/share/uv":"$HOME/.local/share/uv":ro \
      -v "$E2E_ROOT/go":/home/inf/go \
      -v "$E2E_ROOT/go-build":/home/inf/.cache/go-build \
      -v "$E2E_ROOT/uv-cache":/home/inf/.cache/uv \
      -v "$E2E_ROOT/npm-cache":/home/inf/.npm \
      -p 127.0.0.1::29380 -p 127.0.0.1::29383 -p 127.0.0.1::29384 -p 127.0.0.1::29222 \
      hfv-worker:latest tail -f /dev/null >>"$LOG_DIR/daemon.log" 2>&1 \
      || die "worker container start failed (see daemon.log)"
    log "group $SUFFIX up: $CTR (worktree $wt)"
  fi
  # relay container-localhost app ports to 0.0.0.0 relay ports, so the
  # published ports reach them no matter how the app binds (localhost vs *)
  for r in 29380:9380 29383:9383 29384:9384 29222:9222; do
    docker exec -d "$CTR" socat TCP-LISTEN:"${r%%:*}",bind=0.0.0.0,fork,reuseaddr \
      TCP:127.0.0.1:"${r##*:}" >/dev/null 2>&1 || true
  done
  # worker-entrypoint deep-probes every service before handing over; wait for
  # its done-marker (first ES boot on a fresh volume takes a few minutes)
  for i in $(seq 1 96); do
    [[ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null)" == "true" ]] \
      || die "$CTR died during startup (docker logs $CTR)"
    docker logs "$CTR" 2>/dev/null | grep -q "all forwards up" && break
    [[ $i -eq 96 ]] && die "service readiness timeout after 480s (docker logs $CTR)"
    sleep 5
  done
  printf 'WORKTREE=%s\nCLONE=%s\n' "$wt" "$clone" > "$STATE"
  # python venv: the interpreter must match the CONTAINER's glibc. sdist-built
  # wheels (numpy 1.26.4 on cp313, etc.) compile against the BUILD host's
  # glibc — a host-synced venv ImportErrors in the container (glibc 2.43 vs
  # 2.39). Sync inside the group instead;
  # the .e2e-built marker keeps warm rounds on a fast plain sync.
  if [[ -f "$wt/pyproject.toml" ]]; then
    if [[ ! -f "$wt/.venv/.e2e-built" ]]; then
      do_exec "$num" -- bash -c "cd '$wt' && uv sync --frozen --reinstall" >>"$LOG_DIR/daemon.log" 2>&1 \
        && do_exec "$num" -- touch "$wt/.venv/.e2e-built" >>"$LOG_DIR/daemon.log" 2>&1 \
        && log "group $SUFFIX: venv rebuilt in-container (glibc-matched)" \
        || log "group $SUFFIX: venv sync FAILED (python stack will not boot)"
    else
      do_exec "$num" -- bash -c "cd '$wt' && uv sync --frozen" >>"$LOG_DIR/daemon.log" 2>&1 || true
    fi
  fi
  echo "e2e group $SUFFIX READY (worktree $wt)"
  docker port "$CTR" 2>/dev/null | grep -E '2938|2922' | sed 's/^/  /'
  echo "  inside:   bash $DIR/framework/pr-e2e.sh exec $num -- <cmd>"
  echo "  teardown: bash $DIR/framework/pr-e2e.sh down $num"
}

do_exec() { # <num> <cmd...> — docker exec passthrough, cwd = PR worktree
  local num="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  local wt; wt="$(wt_of_state)"
  [[ -n "$wt" ]] || die "no 'up' recorded for $SUFFIX (run up first)"
  # HFV_SLOT= (empty) + RAGFLOW_MAIN=$wt: config.sh then keeps the env-preset
  # repo instead of rewriting it to a slot clone path that does not exist here
  # One retry: right after a down/up cycle `docker exec` can hit a transient
  # runc setns failure while the container's init is still coming up.
  docker exec -w "$wt" -e HFV_SLOT= -e RAGFLOW_MAIN="$wt" "$CTR" "$@" && return
  sleep 3
  docker exec -w "$wt" -e HFV_SLOT= -e RAGFLOW_MAIN="$wt" "$CTR" "$@"
}

do_ports() {
  docker port "$CTR" 2>/dev/null | grep -E '2938|2922' \
    || echo "pr-e2e: no published ports ($CTR not up?)"
}

do_status() {
  echo "== container $CTR"
  docker ps -a --filter "name=^$CTR$" --format '{{.Status}}  {{.Image}}' || true
  echo "== services (project $PROJ)"
  HFV_SLOT="$SUFFIX" docker compose -p "$PROJ" --env-file "$ENVF" -f "$SVC_YML" ps 2>/dev/null || true
  echo "== published ports"
  do_ports
}

do_down() {
  docker rm -f "$CTR" >/dev/null 2>&1 || true
  HFV_SLOT="$SUFFIX" docker compose -p "$PROJ" --env-file "$ENVF" -f "$SVC_YML" stop \
    >>"$LOG_DIR/daemon.log" 2>&1 || true
  rm -f "$STATE"
  log "group $SUFFIX down (volumes kept)"
  echo "pr-e2e: group $SUFFIX down (service volumes kept warm; purge to drop)"
}

do_purge() {
  do_down
  HFV_SLOT="$SUFFIX" docker compose -p "$PROJ" --env-file "$ENVF" -f "$SVC_YML" down -v --remove-orphans \
    >>"$LOG_DIR/daemon.log" 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  # go/pkg/mod cache files are read-only (0555/0444) by design — a plain
  # rm -rf fails with Permission denied and silently leaves the tree behind
  [[ -d "$E2E_ROOT" ]] && chmod -R u+w "$E2E_ROOT" 2>/dev/null || true
  rm -rf "$E2E_ROOT"
  log "group $SUFFIX purged (volumes/network/caches dropped)"
  echo "pr-e2e: group $SUFFIX purged"
}

do_sweep() { # purge per-PR groups whose PR is no longer OPEN (merged/closed).
  # `down` keeps volumes warm for the NEXT round — but for a terminal-state
  # PR that round never comes, so the esdata/mysql/... volumes and the e2e
  # caches would sit on disk forever.
  # gh failures yield an empty state → skipped (never purge on doubt).
  local num state
  for num in $(docker volume ls --format '{{.Name}}' 2>/dev/null \
               | sed -n 's/^hfv-svc-pr\([0-9][0-9]*\)_.*/\1/p' | sort -u); do
    state="$(gh pr view "$num" --repo "$GITHUB_REPO" --json state --jq .state 2>/dev/null || true)"
    if [[ -n "$state" && "$state" != "OPEN" ]]; then
      echo "pr-e2e: pr$num is $state — purging leftover group"
      names "$num"
      do_purge
    fi
  done
}

cmd="${1:-}"; num="${2:-}"
case "$cmd" in
  up)
    [[ $# -eq 3 && "$num" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { usage; exit 2; }
    names "$num"; do_up "$num" "$3" ;;
  exec)
    [[ $# -ge 3 && "$num" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { usage; exit 2; }
    names "$num"; shift 2; do_exec "$num" "$@" ;;
  ports|status|down|purge)
    [[ -n "$num" && "$num" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { usage; exit 2; }
    names "$num"; "do_$cmd" ;;
  sweep)
    do_sweep ;;
  *)
    usage; exit 2 ;;
esac
