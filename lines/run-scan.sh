#!/usr/bin/env bash
# cline-feishu-scan runner: execute one repo bug-scan round via the Cline CLI
# (in-container, from run-container.sh). Guards against overlapping runs via
# flock; logs per run.
#
# LLM failure handling — same two retry classes as run-task.sh / run-feat.sh,
# waiting time EXCLUDED from timeout accounting:
#   1. quota     — account quota exhausted: rotate to the next key NOW; billing
#                  cycle wait (30 min, ≤6h) only once the key list is exhausted.
#   2. transient — provider temporarily unavailable: wait 2 min, ≤30 min total.
#   3. other     — CLI/session crashes: wait 4 min, ≤12 min total.
set -u

# Re-exec from a private snapshot: editing this file mid-run would make bash
# resume reading it at a stale byte offset and die on a spurious syntax error.
if [[ -z "${HFV_EXEC_SNAPSHOT:-}" ]]; then
  HFV_EXEC_SNAPSHOT="$(mktemp /tmp/hfv-exec-snap.XXXXXX.sh)" || exit 1
  cat -- "$0" > "$HFV_EXEC_SNAPSHOT" || exit 1
  export HFV_EXEC_SNAPSHOT
  exec bash "$HFV_EXEC_SNAPSHOT" "$@"
fi
: "${HFV_EXEC_SNAPSHOT:?}"

DAEMON_DIR="$HOME/hands-free-vibe"
LOG_DIR="$DAEMON_DIR/logs"
source "$DAEMON_DIR/config.sh"
# Per-instance identity (hfv scale scan <N>): scan-N.json / deliver-N / lock.
SCAN_INST="${HFV_SCAN_INST:-1}"
LOCK_FILE="$DAEMON_DIR/locks/run-scan-$SCAN_INST.lock"
TASK_FILE="$(resolve_prompt scan-task)"
SCAN_FILE="$DAEMON_DIR/scan/current-$SCAN_INST.json"
DELIVER_DIR="$DAEMON_DIR/scan/deliver-$SCAN_INST"
CUR_FILE="$DAEMON_DIR/state/.current-scan-$SCAN_INST"
WORKDIR="$RAGFLOW_MAIN"
MAX_SECONDS="$MAIN_MAX_SECONDS"

# Explicit model override + multi-key rotation (same marker as the other lines).
MODEL_BASE="$(python3 "$DAEMON_DIR/tools/model-profile.py" args-base)" || exit 1
mapfile -t API_KEYS < <(python3 "$DAEMON_DIR/tools/model-profile.py" keylist) || exit 1
((${#API_KEYS[@]})) || exit 1
key_idx=0

QUOTA_PATTERN='usage limit|billing cycle|quota.{0,40}(refresh|exceed|exhaust)|insufficient.{0,20}quota|使用上限|限额.{0,20}重置|额度.{0,20}(耗尽|不足)'
TRANSIENT_PATTERN='rate.?limit|too many requests|\b429\b|overloaded|temporarily unavailable|service unavailable|\b50[23]\b|try again later|high load|capacity exceeded|out of capacity|timed out|负载|限流|稍后重试'

mkdir -p "$LOG_DIR" "$DELIVER_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="$LOG_DIR/run-scan-$TS-i$SCAN_INST.log"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[$TS] previous scan run still active, skipping tick" >> "$LOG_DIR/daemon.log"
  rm -f "$HFV_EXEC_SNAPSHOT"
  exit 0
fi
trap 'rm -f "$HFV_EXEC_SNAPSHOT" "${CUR_FILE:-}"' EXIT

# new task starts: reclaim MCP servers leaked by previous (finished) runs
bash "$DAEMON_DIR/framework/mcp-cleanup.sh"

if [[ ! -x "$CLINE_BIN" ]]; then
  echo "[$TS] cline CLI not found at $CLINE_BIN" >> "$LOG_DIR/daemon.log"
  exit 1
fi

# Framework-side batch selection (pre-scan.sh wrote scan/current-N.json).
# Absent/empty => middle band exhausted this tick: rest without an LLM run.
# The .rested marker tells post-scan.sh to skip entirely.
if [[ ! -s "$SCAN_FILE" ]]; then
  echo "[$TS] no scan batch selected, resting" >> "$LOG_DIR/daemon.log"
  touch "$LOG_DIR/.rested-scan-$SCAN_INST"
  exit 0
fi
rm -f "$LOG_DIR/.rested-scan-$SCAN_INST"
SCAN_ID="$(python3 -c "import json;print(json.load(open('$SCAN_FILE')).get('scan_id',''))" 2>/dev/null || true)"
NFILES="$(python3 -c "import json;print(len(json.load(open('$SCAN_FILE')).get('files',[])))" 2>/dev/null || echo 0)"
if [[ -z "$SCAN_ID" || "$NFILES" == "0" ]]; then
  echo "[$TS] current-$SCAN_INST.json unreadable/empty, resting" >> "$LOG_DIR/daemon.log"
  touch "$LOG_DIR/.rested-scan-$SCAN_INST"
  exit 0
fi
printf '%s\t%s files\n' "$SCAN_ID" "$NFILES" > "$CUR_FILE"

# --- framework pre-flight (same rationale as run-task.sh) ---------------------
bash "$DAEMON_DIR/framework/env-up.sh" local "$WORKDIR" >"$LOG_DIR/env-up-scan-$SCAN_INST.log" 2>&1 || true
ENV_SECTION="$(cat "$LOG_DIR/env-status${HFV_SUF}.md" 2>/dev/null || true)"

BATCH_SECTION="$(python3 - "$SCAN_FILE" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
w = d.get("window", {})
print("## 本轮扫描批次（任务框架注入，不得自选/改选；完整参数以 `%s` 为准）" % sys.argv[1])
print("- scan_id: %s" % d.get("scan_id"))
print("- 窗口: 排除最新 %s 天内、最老 P%s 之外（中间区段 %s 个候选文件）"
      % (w.get("new_days"), w.get("old_pct"), d.get("stats", {}).get("candidates", "?")))
print("- 文件清单:")
for f in d.get("files", []):
    print("  - `%s`（最后提交 %s 前，%s）" % (f["path"], f["age_days"], f["last_commit"]))
PYEOF
)"

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
    echo "=== run started $(date -Is) attempt=$attempt mode=scan id=$SCAN_ID ==="
    timeout "$MAX_SECONDS" "$CLINE_BIN" \
      --json \
      --cwd "$WORKDIR" \
      -t "$MAX_SECONDS" \
      --auto-approve true \
      $MODEL_BASE -k "${API_KEYS[$key_idx]}" \
      "$(sed -e "s|__WORKDIR__|$WORKDIR|g" \
             -e "s|__GITHUB_REPO__|$GITHUB_REPO|g" \
             -e "s|__FORK_REMOTE__|$FORK_REMOTE|g" \
             -e "s|__MERGE_OWNER_LOGIN__|$MERGE_OWNER_LOGIN|g" \
             -e "s|__PR_BASE__|$PR_BASE|g" \
             -e "s|__DELIVER_DIR__|$DELIVER_DIR|g" \
             -e "s|__SCAN_ID__|$SCAN_ID|g" \
             -e "s|__SCAN_SLOT__|$SCAN_INST|g" \
             -e "s|__HFV_DIR__|$DAEMON_DIR|g" "$TASK_FILE")

$ENV_SECTION

$BATCH_SECTION"
    rc=$?
    echo "=== run finished $(date -Is) exit=$rc attempt=$attempt mode=scan ==="
  } >> "$RUN_LOG" 2>&1

  # rc=0: success. rc=124: our own hard cap fired — the attempt already did
  # hours of real work; do not retry inside this run.
  if [[ $rc -eq 0 || $rc -eq 124 ]]; then break; fi

  # Classify from error-channel lines ONLY ("type":"error" / agent_error):
  # whole-log grep would match prompt text quoting "quota exhausted".
  err_lines() { tail -n "+$((start_line + 1))" "$RUN_LOG" | grep -E '"type":"error"|agent_error' || true; }
  kind=""
  if err_lines | grep -qiE "$QUOTA_PATTERN"; then
    kind=quota; wait_s=$QUOTA_RETRY_SECONDS; waited=$quota_waited; max_wait=$QUOTA_MAX_WAIT_SECONDS
  elif err_lines | grep -qiE "$TRANSIENT_PATTERN"; then
    kind=transient; wait_s=$TRANSIENT_RETRY_SECONDS; waited=$transient_waited; max_wait=$TRANSIENT_MAX_WAIT_SECONDS
  else
    kind=other; wait_s=$OTHER_RETRY_SECONDS; waited=$other_waited; max_wait=$OTHER_MAX_WAIT_SECONDS
  fi

  # Multi-key rotation: quota → next key NOW; the billing-cycle wait engages
  # only once the whole list is exhausted.
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
  echo "[$TS] LLM $kind failure (attempt $attempt exit=$rc), waiting ${wait_s}s before retry (wait budget ${waited}/${max_wait}s)" >> "$LOG_DIR/daemon.log"
  # parked-on-rate-limit marker for `hfv model`
  if [[ "$kind" == quota || "$kind" == transient ]]; then
    mkdir -p "$DAEMON_DIR/logs/llm-wait"
    printf '%s\n' "$kind $(date +%s) scan-inst=$SCAN_INST" > "$DAEMON_DIR/logs/llm-wait/$(basename "$LOCK_FILE" .lock)"
  fi
  sleep "$wait_s"
  rm -f "$DAEMON_DIR/logs/llm-wait/$(basename "$LOCK_FILE" .lock)"
  case "$kind" in
    quota)     quota_waited=$((quota_waited + wait_s)) ;;
    transient) transient_waited=$((transient_waited + wait_s)) ;;
    other)     other_waited=$((other_waited + wait_s)) ;;
  esac
done

echo "[$TS] exit=$rc attempts=$attempt mode=scan id=$SCAN_ID log=$RUN_LOG" >> "$LOG_DIR/daemon.log"

# Metrics: parse the run log into ClickHouse (best-effort, never fails the run).
python3 "$DAEMON_DIR/tools/metrics.py" "$RUN_LOG" "$rc" >> "$LOG_DIR/metrics.log" 2>&1 || true

# ALWAYS exit 0: oneshot services run ExecStartPost (post-scan.sh) only after a
# SUCCESSFUL ExecStart. Exiting nonzero on LLM failures would skip the whole
# post group. The real rc is already in daemon.log and the run log.
exit 0

