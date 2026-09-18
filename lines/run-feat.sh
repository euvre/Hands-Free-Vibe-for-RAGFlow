#!/usr/bin/env bash
# cline-feishu-feat runner: execute the feature-implementation task once via
# the Cline CLI, using the spec file staged by `hfv feat -f <file>`.
# Shares the flock with run-task.sh, so a feat run and an issue-triage run
# never overlap (same repo, same services, same git state).
#
# LLM failure handling — two retry classes, both with waiting time EXCLUDED
# from any timeout accounting:
#   1. quota     — account quota exhausted ("usage limit ... billing cycle"):
#                  wait 30 min for the next billing cycle, up to 6h total.
#   2. transient — LLM temporarily unavailable (rate limit / 429 / overloaded /
#                  5xx / timeouts on the provider side): wait 2 min, up to 30
#                  min total.
# Each attempt gets a fresh full MAX_SECONDS budget; the sleeps between
# attempts are plain waits and never consume it.
set -u

# Re-exec from a private snapshot: editing this file mid-run would make bash
# resume reading it at a stale byte offset and die on a spurious syntax error.
if [[ -z "${HFV_EXEC_SNAPSHOT:-}" ]]; then
  HFV_EXEC_SNAPSHOT="$(mktemp /tmp/hfv-exec-snap.XXXXXX.sh)" || exit 1
  cat -- "$0" > "$HFV_EXEC_SNAPSHOT" || exit 1
  export HFV_EXEC_SNAPSHOT
  exec bash "$HFV_EXEC_SNAPSHOT" "$@"
fi
# The EXIT trap and the status marker are installed AFTER the lock below: a
# lock-busy no-op exit must not remove the ACTIVE run's .current-feat marker
# (the audit line learned this first; same trap shape now everywhere).
: "${HFV_EXEC_SNAPSHOT:?}"

DAEMON_DIR="$HOME/hands-free-vibe"
LOG_DIR="$DAEMON_DIR/logs"
source "$DAEMON_DIR/config.sh"
# Per-instance lock (hfv scale feat <N>): each feat instance owns
# run-feat-<inst>.lock and its own spec/deliver staging. A feat run has its
# own throwaway worktree, so it no longer shares the issue line's lock.
FEAT_INST="${HFV_FEAT_INST:-1}"
LOCK_FILE="$DAEMON_DIR/locks/run-feat-$FEAT_INST.lock"
FEAT_SPEC="$DAEMON_DIR/feat/current-feature-$FEAT_INST.md"
FEAT_DELIVER="$DAEMON_DIR/feat/deliver-$FEAT_INST"
CUR_FILE="$DAEMON_DIR/.current-feat-$FEAT_INST"
TASK_FILE="$(resolve_prompt feat-task)"
WORKDIR="$RAGFLOW_MAIN"
# Hard cap per attempt (2h). Bounds pathological hangs of a single attempt;
# retries start a fresh attempt with a fresh full budget.
MAX_SECONDS="$MAIN_MAX_SECONDS"

# Explicit model override (same marker as run-task.sh / summarize-run.sh).
# Multi-key rotation (same as run-task.sh): quota failure rotates -k to the
# next key and retries immediately; the billing-cycle wait is the last resort.
MODEL_BASE="$(python3 "$DAEMON_DIR/tools/model-profile.py" args-base)" || exit 1
mapfile -t API_KEYS < <(python3 "$DAEMON_DIR/tools/model-profile.py" keylist) || exit 1
((${#API_KEYS[@]})) || exit 1
key_idx=0

# Failure classification patterns. Retry timings (QUOTA_*/TRANSIENT_*/
# OTHER_*) come from config.sh / hfv.conf — do NOT hardcode them here.
# Patterns match both English and the provider's Chinese variants (e.g.
# "已达到 5 小时的使用上限。您的限额将在 … 重置。").
QUOTA_PATTERN='usage limit|billing cycle|quota.{0,40}(refresh|exceed|exhaust)|insufficient.{0,20}quota|使用上限|限额.{0,20}重置|额度.{0,20}(耗尽|不足)'

# Transient unavailability (load / rate limiting on the provider side).
TRANSIENT_PATTERN='rate.?limit|too many requests|\b429\b|overloaded|temporarily unavailable|service unavailable|\b50[23]\b|try again later|high load|capacity exceeded|out of capacity|timed out|负载|限流|稍后重试'

mkdir -p "$LOG_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="$LOG_DIR/run-feat-$TS.log"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[$TS] previous run still active, skipping feat run" >> "$LOG_DIR/daemon.log"
  rm -f "$HFV_EXEC_SNAPSHOT"   # busy-exit cleans its own snapshot; no trap yet
  exit 0
fi
# Marker write and EXIT trap only once the lock is held: a lock-busy no-op
# exit must not touch the ACTIVE run's marker file.
basename "$FEAT_SPEC" > "$CUR_FILE"
trap 'rm -f "$HFV_EXEC_SNAPSHOT" "${CUR_FILE:-}"' EXIT

# new task starts: reclaim MCP servers leaked by previous (finished) runs
bash "$DAEMON_DIR/framework/mcp-cleanup.sh"

if [[ ! -x "$CLINE_BIN" ]]; then
  echo "[$TS] cline CLI not found at $CLINE_BIN" >> "$LOG_DIR/daemon.log"
  exit 1
fi

# --- framework pre-flight (same rationale as run-task.sh) ---------------------
# Services pre-launched + known-failure diagnostics BEFORE the LLM starts;
# the status section (logs/env-status.md) is appended to the prompt so the
# agent never redoes bring-up. Best-effort: never blocks the run.
bash "$DAEMON_DIR/framework/env-up.sh" local "$WORKDIR" >"$LOG_DIR/env-up-feat${HFV_SUF}.log" 2>&1 || true
ENV_SECTION="$(cat "$LOG_DIR/env-status${HFV_SUF}.md" 2>/dev/null || true)"

rc=0
attempt=0
quota_waited=0
transient_waited=0
other_waited=0
: > "$RUN_LOG"
while true; do
  attempt=$((attempt + 1))
  start_line=$(wc -l < "$RUN_LOG")
  {
    echo "=== run started $(date -Is) attempt=$attempt mode=feat ==="
    timeout "$MAX_SECONDS" "$CLINE_BIN" \
      --json \
      --cwd "$WORKDIR" \
      -t "$MAX_SECONDS" \
      --auto-approve true \
      $MODEL_BASE -k "${API_KEYS[$key_idx]}" \
      "$(sed -e "s|__FEAT_SPEC__|$FEAT_SPEC|g" \
             -e "s|__FEAT_DELIVER__|$FEAT_DELIVER|g" \
             -e "s|__WORKDIR__|$WORKDIR|g" \
             -e "s|__GITHUB_REPO__|$GITHUB_REPO|g" \
             -e "s|__FORK_REMOTE__|$FORK_REMOTE|g" \
             -e "s|__MERGE_OWNER_LOGIN__|$MERGE_OWNER_LOGIN|g" \
             -e "s|__PR_BASE__|$PR_BASE|g" \
             -e "s|__HFV_DIR__|$DAEMON_DIR|g" "$TASK_FILE")

$ENV_SECTION"
    rc=$?
    echo "=== run finished $(date -Is) exit=$rc attempt=$attempt mode=feat ==="
  } >> "$RUN_LOG" 2>&1

  # rc=0: success. rc=124: our own hard cap fired — the attempt already did
  # hours of real work; do not retry inside this run.
  if [[ $rc -eq 0 || $rc -eq 124 ]]; then break; fi

  # Classify from error-channel lines ONLY ("type":"error" / agent_error):
  # whole-log grep would match prompt text quoting "quota exhausted". Every
  # failure class is retried here (quota / transient / other) — see
  # run-task.sh for the full rationale.
  err_lines() { tail -n "+$((start_line + 1))" "$RUN_LOG" | grep -E '"type":"error"|agent_error' || true; }
  kind=""
  if err_lines | grep -qiE "$QUOTA_PATTERN"; then
    kind=quota; wait_s=$QUOTA_RETRY_SECONDS; waited=$quota_waited; max_wait=$QUOTA_MAX_WAIT_SECONDS
  elif err_lines | grep -qiE "$TRANSIENT_PATTERN"; then
    kind=transient; wait_s=$TRANSIENT_RETRY_SECONDS; waited=$transient_waited; max_wait=$TRANSIENT_MAX_WAIT_SECONDS
  else
    kind=other; wait_s=$OTHER_RETRY_SECONDS; waited=$other_waited; max_wait=$OTHER_MAX_WAIT_SECONDS
  fi

  # Multi-key rotation (same as run-task.sh): quota → next key NOW; the
  # billing-cycle wait engages only once the list is exhausted.
  if [[ "$kind" == quota && $((key_idx + 1)) -lt ${#API_KEYS[@]} ]]; then
    key_idx=$((key_idx + 1))
    echo "[$TS] quota exhausted on key #$key_idx — rotating to key #$((key_idx + 1))/${#API_KEYS[@]}, retrying NOW" >> "$LOG_DIR/daemon.log"
    continue
  fi
  if [[ "$kind" == quota && ${#API_KEYS[@]} -gt 1 ]]; then
    echo "[$TS] all ${#API_KEYS[@]} keys quota-exhausted — billing-cycle wait engaged" >> "$LOG_DIR/daemon.log"
    key_idx=0
  fi

  if (( waited >= max_wait )); then
    echo "[$TS] LLM $kind failure persists after ${waited}s of waiting (attempt $attempt exit=$rc), giving up" >> "$LOG_DIR/daemon.log"
    break
  fi
  echo "[$TS] LLM $kind failure (attempt $attempt exit=$rc), waiting ${wait_s}s before retry (wait budget ${waited}/${max_wait}s; retry waiting does not consume the per-attempt timeout)" >> "$LOG_DIR/daemon.log"
  # parked-on-rate-limit marker for `hfv model` (see pr-llm-run.sh)
  if [[ "$kind" == quota || "$kind" == transient ]]; then
    mkdir -p "$DAEMON_DIR/logs/llm-wait"
    printf '%s\n' "$kind $(date +%s) feat-inst=$FEAT_INST" > "$DAEMON_DIR/logs/llm-wait/$(basename "$LOCK_FILE" .lock)"
  fi
  sleep "$wait_s"
  rm -f "$DAEMON_DIR/logs/llm-wait/$(basename "$LOCK_FILE" .lock)"
  case "$kind" in
    quota)     quota_waited=$((quota_waited + wait_s)) ;;
    transient) transient_waited=$((transient_waited + wait_s)) ;;
    other)     other_waited=$((other_waited + wait_s)) ;;
  esac
done

echo "[$TS] exit=$rc attempts=$attempt mode=feat log=$RUN_LOG" >> "$LOG_DIR/daemon.log"

# Metrics: parse the run log into ClickHouse (best-effort, never fails the run).
# On retries the log holds every attempt; metrics keeps the last run_result,
# i.e. the decisive attempt.
python3 "$DAEMON_DIR/tools/metrics.py" "$RUN_LOG" "$rc" >> "$LOG_DIR/metrics.log" 2>&1 || true

# no rotation: keep all run logs (issue and feat runs share the pool; 50-log cap removed)

# ALWAYS exit 0: oneshot services run ExecStartPost (feat-deliver.sh, which
# publishes the staged PR) only after a SUCCESSFUL ExecStart — and run-slot.sh
# transparently relays this exit code through docker run. The real rc lives in
# the daemon.log line above.
exit 0
