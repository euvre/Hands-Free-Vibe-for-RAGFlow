#!/usr/bin/env bash
# env-up.sh — framework-side service pre-launch + bounded readiness wait, run
# by the runners BEFORE the LLM stage.
#
# usage:
#   env-up.sh local [worktree]        # issue/feat lines: services in THIS
#                                     # namespace — always the LLM's own
#                                     # container (a slot worker); there is
#                                     # no host-direct form any more
#   env-up.sh e2e <num|audit> <wt>    # audit/review lines: bring up the e2e
#                                     # group, then the app services inside it
#
# What it produces:
#   * services at READY (or an honest NOT-READY), and
#   * a markdown status section for prompt injection:
#       local → $LOG_DIR/env-status${HFV_SUF}.md
#       e2e   → $LOG_DIR/env-status-e2e-<suffix>.md
#     The runners append it to the task prompt ("Framework pre-flight"), and
#     the task files forbid the agent from redoing bring-up on a READY.
#
# NEVER blocks the caller: exit 0 throughout — a botched pre-flight only
# degrades the injected section; the task file's own failure paths apply.
set -u
DIR="$HOME/hands-free-vibe"
source "$DIR/config.sh"
LOG_DIR="$DIR/logs"
mkdir -p "$LOG_DIR"

# ragflow-up.sh's watcher budgets ~7.5min; we pad it. A warm stack usually
# reports READY in well under a minute.
WAIT_LIMIT="${ENV_UP_WAIT_SECONDS:-560}"
POLL=10

MODE="${1:-local}"

log() { echo "[$(date +%Y%m%d-%H%M%S)] env-up: $*" >> "$LOG_DIR/daemon.log"; }

# Fast pre-check: the exact trio the feat task's §3.1 used (go api + web + py).
pre_check() {
  curl -sf -o /dev/null --max-time 3 http://127.0.0.1:9384/api/v1/system/version \
    && curl -sf -o /dev/null --max-time 3 http://127.0.0.1:9222/ \
    && ss -tln 2>/dev/null | grep -q ':9380\b'
}

# wait_status <cat-cmd...> — poll a status-file producer until all=READY /
# all=TIMEOUT / budget out. Echoes READY|TIMEOUT|PARTIAL|MISSING + seconds.
wait_status() {
  local waited=0 st=""
  while (( waited < WAIT_LIMIT )); do
    st="$("$@" 2>/dev/null || true)"
    grep -q 'all=READY'   <<<"$st" && { echo "READY $waited"; return; }
    grep -q 'all=TIMEOUT' <<<"$st" && { echo "TIMEOUT $waited"; return; }
    sleep "$POLL"; waited=$((waited + POLL))
  done
  [[ -n "$st" ]] && echo "PARTIAL $waited" || echo "MISSING $waited"
}

# preflight_block <cmd...> — render the env-preflight output as a markdown
# bullet list, keeping only non-OK lines (OK is the default state; the LLM
# only needs to see deviations).
preflight_block() {
  local out
  out="$("$@" 2>/dev/null || true)"
  local summary; summary="$(grep '^PREFLIGHT_SUMMARY' <<<"$out" | head -1 | sed 's/^PREFLIGHT_SUMMARY //')"
  echo "- **Pre-flight checks**: ${summary:-unavailable}"
  grep '^PREFLIGHT ' <<<"$out" | grep -v '^PREFLIGHT OK ' | grep -v '^PREFLIGHT SKIP ' \
    | sed 's/^PREFLIGHT \([A-Z]*\) \([a-z-]*\) — /  - `\1 \2` — /' || true
}

write_section() { # <file> — stdin is the markdown body
  local tmp="$1.tmp"
  cat > "$tmp" && mv "$tmp" "$1"
}

if [[ "$MODE" == "local" ]]; then
  WT="${2:-$RAGFLOW_MAIN}"
  STATUS_FILE="${RAGFLOW_STATUS_FILE:-/tmp/ragflow-ready.status}"
  OUT="$LOG_DIR/env-status${HFV_SUF}.md"
  UPLOG="$LOG_DIR/env-up${HFV_SUF}.log"

  if pre_check; then
    svc_line="READY — services already healthy (pre-check passed: go api 9384 / web 9222 / py api 9380; NO relaunch was needed)"
    log "local: pre-check passed, no relaunch"
  else
    log "local: pre-check failed — relaunching via ragflow-up.sh"
    # never let wait_status read a stale all= line from the image layer or a
    # crashed run (ragflow-up.sh ≥3.5 also resets it at launch; belt+braces)
    rm -f "$STATUS_FILE"
    bash "$DIR/framework/ragflow-up.sh" >>"$UPLOG" 2>&1 || true
    res="$(wait_status cat "$STATUS_FILE")"
    verdict="${res%% *}"; secs="${res##* }"
    case "$verdict" in
      READY)
        svc_line="READY — relaunched by env-up.sh at $(date +%H:%M:%S), all=READY after ~${secs}s" ;;
      *)
        # py+web READY without the go gateway still fully serves the browser
        # path (web proxies /api to py by default): degrade to PARTIAL, not
        # NOT-READY, so the agent does not abandon the browser tier over a
        # go-only outage.
        last="$(grep '^py=' "$STATUS_FILE" 2>/dev/null | tail -1 || true)"
        py_s="$(grep -o 'py=[A-Z]*' <<<"$last" | head -1 | cut -d= -f2)"
        go_s="$(grep -o 'go=[A-Z]*' <<<"$last" | head -1 | cut -d= -f2)"
        web_s="$(grep -o 'web=[A-Z]*' <<<"$last" | head -1 | cut -d= -f2)"
        if [[ "$py_s" == READY && "$web_s" == READY ]]; then
          svc_line="PARTIAL — py api 9380 + web 9222 READY (browser path fully usable: web proxies /api to py by default); go api 9384 still ${go_s:-PENDING} after ~${secs}s — go-gateway-specific surface is out of scope this round. Do NOT retry the launch in a loop"
        else
          svc_line="NOT-READY ($verdict after ~${secs}s) — inspect /tmp/ragflow-backend.log, /tmp/ragflow-go.log, /tmp/ragflow-web.log ONCE; if unrecoverable, take the task file's failure path. Do NOT retry the launch in a loop (restarts race for ports)"
        fi ;;
    esac
  fi
  # Session keep-alive on the browser MCP's own profile (READY services only):
  # a valid session skips the LLM's login dance entirely; an expired one is
  # refreshed through the sanctioned form path (browser-login.py — script-driven
  # form submit, no API login, no token planting).
  login_line="not attempted (services not READY)"
  if [[ "$svc_line" == READY* || "$svc_line" == PARTIAL* ]]; then
    login_line="$(bash "$DIR/framework/browser-ensure-login.sh" http://127.0.0.1:9222 2>/dev/null || true)"
  fi
  {
    echo "## Framework pre-flight (the runner already did this — do NOT redo)"
    echo
    echo "- **Services**: $svc_line"
    echo "- **Status file**: \`$STATUS_FILE\` is the live truth; layout py 9380 / go admin 9383 / go api 9384 / web 9222 in THIS namespace"
    echo "- **Browser session**: $login_line"
    preflight_block bash "$DIR/framework/env-preflight.sh" local "$WT"
    echo "- **Only justified relaunch**: a service dies MID-WORK (a live port drops) → \`bash $DIR/framework/ragflow-up.sh\` once, then re-cat the status file. NEVER \`pkill -f\` (your own cmdline embeds the prompt text)."
  } | write_section "$OUT"
  log "local: section written to $OUT ($svc_line)"
  exit 0
fi

if [[ "$MODE" == "e2e" ]]; then
  SUFFIX="${2:-}"
  WT="${3:-}"
  [[ -n "$SUFFIX" && -n "$WT" ]] || { echo "usage: env-up.sh e2e <num|audit> <worktree>" >&2; exit 2; }
  case "$SUFFIX" in *[!0-9]*) NAME="$SUFFIX" ;; *) NAME="pr$SUFFIX" ;; esac
  OUT="$LOG_DIR/env-status-e2e-$NAME.md"
  UPLOG="$LOG_DIR/env-up-e2e-$NAME.log"

  if bash "$DIR/framework/pr-e2e.sh" up "$SUFFIX" "$WT" >>"$UPLOG" 2>&1; then
    grp_line="group hfv-e2e-$NAME up (service stack ready; worktree $WT mounted)"
  else
    grp_line="GROUP-UP FAILED — see $UPLOG; fall back to unit tiers + code-level evidence and choose INCOMPLETE per the task file"
  fi
  svc_line="not attempted"
  ports_line="unavailable"
  if [[ "$grp_line" == group* ]]; then
    bash "$DIR/framework/pr-e2e.sh" exec "$SUFFIX" -- bash "$DIR/framework/ragflow-up.sh" >>"$UPLOG" 2>&1 || true
    res="$(wait_status bash "$DIR/framework/pr-e2e.sh" exec "$SUFFIX" -- cat /tmp/ragflow-ready.status)"
    verdict="${res%% *}"; secs="${res##* }"
    case "$verdict" in
      READY) svc_line="READY — in-group ragflow-up.sh reported all=READY after ~${secs}s" ;;
      *)     svc_line="NOT-READY ($verdict after ~${secs}s) — check ONCE via \`bash $DIR/framework/pr-e2e.sh exec $SUFFIX -- tail -30 /tmp/ragflow-backend.log\` (and go/web logs); do NOT retry bring-up in a loop — fall back to unit tiers and choose INCOMPLETE per the task file" ;;
    esac
    ports_line="$(bash "$DIR/framework/pr-e2e.sh" ports "$SUFFIX" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g' || true)"
    [[ -n "$ports_line" ]] || ports_line="unavailable"
  fi
  # Session keep-alive against the group's published web port, on the HOST's
  # browser-MCP profile (the audit/review agents' chrome lives on the host).
  login_line="not attempted (services not READY)"
  if [[ "$svc_line" == READY* ]]; then
    web_port="$(bash "$DIR/framework/pr-e2e.sh" ports "$SUFFIX" 2>/dev/null | sed -n 's|^29222/tcp -> 127.0.0.1:\([0-9][0-9]*\)|\1|p' | head -1)"
    [[ -n "$web_port" ]] && login_line="$(bash "$DIR/framework/browser-ensure-login.sh" "http://127.0.0.1:$web_port" 2>/dev/null || true)"
  fi
  {
    echo "## Framework pre-flight (the runner already did this — do NOT redo)"
    echo
    echo "- **E2E group**: $grp_line"
    echo "- **App services in the group**: $svc_line"
    echo "- **Host port mapping**: $ports_line (re-print anytime: \`bash $DIR/framework/pr-e2e.sh ports $SUFFIX\`)"
    echo "- **Browser session**: $login_line"
    if [[ "$grp_line" == group* ]]; then
      preflight_block bash "$DIR/framework/env-preflight.sh" e2e "$SUFFIX" "$WT"
    fi
    echo "- **Only justified relaunch**: a service dies MID-WORK → \`bash $DIR/framework/pr-e2e.sh exec $SUFFIX -- bash $DIR/framework/ragflow-up.sh\` once, then re-check \`... -- cat /tmp/ragflow-ready.status\`. NEVER re-run \`pr-e2e.sh up\` on a READY pre-flight."
  } | write_section "$OUT"
  log "e2e $NAME: section written to $OUT ($svc_line)"
  exit 0
fi

echo "usage: env-up.sh local [worktree] | e2e <num|audit> <worktree>" >&2
exit 2
