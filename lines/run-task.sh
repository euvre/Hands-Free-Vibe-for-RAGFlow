#!/usr/bin/env bash
# cline-feishu-triage runner: execute the Feishu issue triage task once via
# the Cline CLI. Guards against overlapping runs via flock; logs per run.
#
# LLM failure handling — two retry classes, both with waiting time EXCLUDED
# from any timeout accounting:
#   1. quota     — account quota exhausted ("usage limit ... billing cycle"):
#                  wait 30 min for the next billing cycle, up to 6h total.
#   2. transient — LLM temporarily unavailable (rate limit / 429 / overloaded /
#                  5xx / timeouts on the provider side): wait 2 min, up to 30
#                  min total.
# Each attempt gets a fresh full MAX_SECONDS budget; the sleeps between
# attempts are plain waits and never consume it. While waiting, the flock
# keeps the 20-minute timer ticks skipped, so exactly one run is ever active.
set -u

DAEMON_DIR="$HOME/hands-free-vibe"
source "$DAEMON_DIR/config.sh"
LOG_DIR="$DAEMON_DIR/logs"
# Per-instance lock / issue file / deliver dir (HFV_SUF comes from config.sh;
# empty on an unnumbered run → run.lock / current.json / deliver).
LOCK_FILE="$DAEMON_DIR/run${HFV_SUF}.lock"
TASK_FILE="$(resolve_prompt task)"
ISSUE_FILE="$DAEMON_DIR/issues/current${HFV_SUF}.json"
WORKDIR="$RAGFLOW_MAIN"
DELIVER_DIR="$DAEMON_DIR/deliver${HFV_SUF}"
mkdir -p "$DELIVER_DIR"
# Hard cap per attempt (2h). Bounds pathological hangs of a single attempt;
# retries start a fresh attempt with a fresh full budget.
MAX_SECONDS="$MAIN_MAX_SECONDS"

# Explicit model override for every cline invocation (main/feat/summarize all
# derive from the same .model-profile marker): immune to drift in the global
# providers.json written by interactive sessions or migrations.
# Multi-key rotation: the runner holds the current profile's whole key list; a
# quota-class failure rotates -k to the next key and retries IMMEDIATELY — the
# billing-cycle wait engages only once the list is exhausted. Keylist lines
# are never logged (key material stays out of the run log).
MODEL_BASE="$(python3 "$DAEMON_DIR/tools/model-profile.py" args-base)" || exit 1
mapfile -t API_KEYS < <(python3 "$DAEMON_DIR/tools/model-profile.py" keylist) || exit 1
((${#API_KEYS[@]})) || exit 1
key_idx=0

# Quota-exhaustion: CLI fails within seconds with a billing-cycle message.
# Match both English and the provider's Chinese variants (e.g. "已达到 5 小时
# 的使用上限。您的限额将在 … 重置。").
QUOTA_PATTERN='usage limit|billing cycle|quota.{0,40}(refresh|exceed|exhaust)|insufficient.{0,20}quota|使用上限|限额.{0,20}重置|额度.{0,20}(耗尽|不足)'

TRANSIENT_PATTERN='rate.?limit|too many requests|\b429\b|overloaded|temporarily unavailable|service unavailable|\b50[23]\b|try again later|high load|capacity exceeded|out of capacity|timed out|负载|限流|稍后重试'

mkdir -p "$LOG_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="$LOG_DIR/run-$TS$HFV_SUF.log"   # slot suffix keeps run-2*.log glob (summarize-run.sh) working

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[$TS] previous run still active, skipping tick" >> "$LOG_DIR/daemon.log"
  exit 0
fi

# new task starts: reclaim MCP servers leaked by previous (finished) runs.
# Orphans only — the previous run is done, live hosts (VS Code/CLion/this
# run, which has not started yet) keep their MCP children.
bash "$DAEMON_DIR/framework/mcp-cleanup.sh"

if [[ ! -x "$CLINE_BIN" ]]; then
  echo "[$TS] cline CLI not found at $CLINE_BIN" >> "$LOG_DIR/daemon.log"
  exit 1
fi

# Framework-side issue selection (pre group wrote issues/current.json).
# Absent/empty => no open issue this tick: rest without starting an LLM run.
# The .rested marker tells post-task to skip entirely (no sync, no summarize:
# summarizing a tick that did nothing would just burn an LLM call).
if [[ ! -s "$ISSUE_FILE" ]]; then
  echo "[$TS] no open issue selected, resting" >> "$LOG_DIR/daemon.log"
  touch "$LOG_DIR/.rested${HFV_SUF}"
  exit 0
fi
MID="$(python3 -c "import json;print(json.load(open('$ISSUE_FILE')).get('message_id',''))" 2>/dev/null || true)"
SUMMARY="$(python3 -c "import json;d=json.load(open('$ISSUE_FILE'));print(((d.get('text_full') or d.get('text') or '')[:80]).replace(chr(10),' '))" 2>/dev/null || true)"
if [[ -z "$MID" ]]; then
  echo "[$TS] current.json unreadable, resting" >> "$LOG_DIR/daemon.log"
  touch "$LOG_DIR/.rested${HFV_SUF}"
  exit 0
fi
# a real run is starting: clear any stale rest marker from a previous tick
# (.quota-dead too: if a crashed post left one behind, THIS run's outcome —
# not the ghost — must decide demotion)
rm -f "$LOG_DIR/.rested${HFV_SUF}" "$LOG_DIR/.quota-dead${HFV_SUF}"
# current-task marker for hfv ps (instance = HFV_SLOT, empty → 1)
CUR_FILE="$DAEMON_DIR/.current-issue-${HFV_SLOT:-1}"
printf '%s\t%s\n' "$MID" "$SUMMARY" > "$CUR_FILE"
trap 'rm -f "$CUR_FILE"' EXIT

# --- deliver-dir ownership handoff -------------------------------------------
# post-deliver.sh ships whatever complete file set it finds in $DELIVER_DIR,
# attributing it to current.json's message_id. A run whose post group never
# ran (quota give-up with the daemon down, host reboot) leaves its staged
# files behind, and the NEXT task on this slot would inherit them. Enforced
# here, once per run:
#   * leftovers stamped with THIS issue's mid survive — the documented
#     continuation path ("check the current state of $DELIVER_DIR first and
#     complete what is missing" for retried/re-picked runs on the same issue);
#   * anything else (foreign mid, or no stamp) is archived
#     to tasks/<id>/deliver-orphan-<ts>/ and can never be shipped;
#   * .owner.json is then (re)stamped so post-deliver can verify ownership
#     before creating the PR.
TASK_ID="$(python3 -c "import json;print(json.load(open('$ISSUE_FILE')).get('task_id') or '')" 2>/dev/null || true)"
python3 - "$DELIVER_DIR" "$MID" "$TASK_ID" "$DAEMON_DIR" <<'PYEOF'
import json, os, shutil, sys, time
deliver, mid, task_id, hfv = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
owner_p = os.path.join(deliver, ".owner.json")
owner = {}
try:
    owner = json.load(open(owner_p))
except Exception:
    pass
entries = sorted(os.listdir(deliver)) if os.path.isdir(deliver) else []
entries = [e for e in entries if e != ".owner.json"]
if entries and owner.get("message_id", "") != mid:
    tid = str(owner.get("task_id") or "") or "unattributed"
    dest = os.path.join(hfv, "tasks", tid,
                        "deliver-orphan-" + time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(dest, exist_ok=True)
    for e in entries:
        shutil.move(os.path.join(deliver, e), os.path.join(dest, e))
    with open(os.path.join(hfv, "logs", "daemon.log"), "a") as f:
        f.write("[%s] run-task: archived %d foreign deliver file(s) "
                "(owner_mid=%s this_mid=%s) -> %s\n"
                % (time.strftime("%Y%m%d-%H%M%S"), len(entries),
                   owner.get("message_id") or "?", mid, dest))
os.makedirs(deliver, exist_ok=True)
tmp = owner_p + ".tmp"
with open(tmp, "w") as f:
    # worktree: the task's RAGFLOW_MAIN (the per-task wt/ worktree, same path on
    # the host via the bind mount; the legacy host line stamps the main root
    # itself). post-deliver.sh commits there.
    json.dump({"message_id": mid, "task_id": task_id or None,
               "worktree": os.environ.get("RAGFLOW_MAIN") or None,
               "written_at": int(time.time() * 1000)}, f)
os.replace(tmp, owner_p)
PYEOF

# Task identity + follow-up context from the assign step (best-effort: absent
# fields simply render an unnumbered run). The header builder and its
# per-kind prompt templates live in task-templates/ (builder + template files
# kept editable without touching this runner).
TASK_HEADER="$(python3 "$DAEMON_DIR/task-templates/build-header.py" "$ISSUE_FILE" 2>/dev/null || true)"

# --- framework pre-flight -----------------------------------------------------
# Services pre-launched + known-failure diagnostics BEFORE the LLM starts
# (env-up.sh local; the status section lands in logs/env-status$HFV_SUF.md).
# Best-effort: a pre-flight failure only degrades the injected section, never
# blocks the run.
bash "$DAEMON_DIR/framework/env-up.sh" local "$WORKDIR" >"$LOG_DIR/env-up${HFV_SUF}.log" 2>&1 || true
ENV_SECTION="$(cat "$LOG_DIR/env-status${HFV_SUF}.md" 2>/dev/null || true)"

TASK_PROMPT="$(sed -e "s|__WORKDIR__|$WORKDIR|g" \
                   -e "s|__GITHUB_REPO__|$GITHUB_REPO|g" \
                   -e "s|__FORK_REMOTE__|$FORK_REMOTE|g" \
                   -e "s|__MERGE_OWNER_LOGIN__|$MERGE_OWNER_LOGIN|g" \
                   -e "s|__PR_BASE__|$PR_BASE|g" \
                   -e "s|__DELIVER_DIR__|$DELIVER_DIR|g" \
                   -e "s|__HFV_DIR__|$DAEMON_DIR|g" "$TASK_FILE")

$TASK_HEADER

$ENV_SECTION

## 本轮选定 issue（任务框架注入，不得自选/改选；完整参数以 \`$ISSUE_FILE\` 为准）
- message_id: $MID
- 摘要: $SUMMARY"

# Every cline run persists its conversation under ~/.cline/data/sessions/<id>/
# (<id>.messages.json). The CLI's own resume (--id) is UNUSABLE in one-shot
# JSON mode: 3.0.57 force-sets interactive=true and drops the prompt whenever
# --id is present (verified in the shipped binary: `if(X){n={...n,interactive:
# !0,prompt:void 0}}`), so --id + --json always fails with "JSON output mode
# requires a prompt argument ...". Continuation is therefore framework-side:
# every retry is a COLD start whose prompt carries a breadcrumb digested from
# the interrupted attempt's session file (last assistant notes + files
# touched), so the agent continues instead of restarting from zero. The id is
# captured per attempt by diffing the sessions dir and mirrored to
# .last-session-<mid> so the next tick's run carries the breadcrumb too.
SESSIONS_DIR="$HOME/.cline/data/sessions"
RESUME_FILE=""
[[ -n "${MID:-}" ]] && RESUME_FILE="$LOG_DIR/.last-session-$MID"
RESUME_ID=""
[[ -n "$RESUME_FILE" ]] && RESUME_ID="$(cat "$RESUME_FILE" 2>/dev/null || true)"
CONT_PROMPT="A previous attempt on this same issue was interrupted mid-run (LLM/provider or CLI error). The breadcrumb below shows where it got to. Continue from there — do NOT start over: the browser login state, any agents/canvases it created, and its code changes are all still in place. If it was already preparing delivery, check the current state of $DELIVER_DIR first and complete what is missing."

rc=0
attempt=0
quota_waited=0
transient_waited=0
other_waited=0
# Killed-by-default marker: overwritten with the real rc below; if the whole
# script dies from a signal, the OnFailure post-task close reads 137 -> failed
# instead of a stale exit=0 from an earlier run.
mkdir -p "$DAEMON_DIR/tasks"
printf 'exit=137
log=%s
' "$RUN_LOG" > "$DAEMON_DIR/tasks/.last-run-info${HFV_SUF}"
: > "$RUN_LOG"
while true; do
  attempt=$((attempt + 1))
  start_line=$(wc -l < "$RUN_LOG")
  before_ls="$(ls "$SESSIONS_DIR" 2>/dev/null | sort)"
  # continuation breadcrumb from the interrupted attempt's session file (may
  # come back empty when that attempt died before doing anything — plain cold)
  BREADCRUMB=""
  if [[ -n "$RESUME_ID" && -f "$SESSIONS_DIR/$RESUME_ID/$RESUME_ID.messages.json" ]]; then
    BREADCRUMB="$(python3 "$DAEMON_DIR/tools/session-breadcrumb.py" \
      "$SESSIONS_DIR/$RESUME_ID/$RESUME_ID.messages.json" 2>/dev/null || true)"
  fi
  if [[ -n "$BREADCRUMB" ]]; then
    mode_line="cont=$RESUME_ID"
    PROMPT_ARGS=("$TASK_PROMPT

---

$CONT_PROMPT

$BREADCRUMB")
  else
    mode_line="cold"
    PROMPT_ARGS=("$TASK_PROMPT")
  fi
  {
    echo "=== run started $(date -Is) attempt=$attempt $mode_line ==="
    timeout "$MAX_SECONDS" "$CLINE_BIN" \
      --json \
      --cwd "$WORKDIR" \
      -t "$MAX_SECONDS" \
      --auto-approve true \
      $MODEL_BASE -k "${API_KEYS[$key_idx]}" \
      "${PROMPT_ARGS[@]}"
    rc=$?
    echo "=== run finished $(date -Is) exit=$rc attempt=$attempt ==="
  } >> "$RUN_LOG" 2>&1
  # capture this attempt's session id for a possible continuation (a resume
  # creates no new dir, so RESUME_ID then simply carries over). The sessions
  # dir is SHARED with concurrent pr-review/pr-follow/summarize runs, whose
  # fresh sessions also show up in the diff — a bare `tail -1` grabs whichever
  # id sorts last, not necessarily ours. Match each candidate's session meta
  # instead: cwd == our WORKDIR and the prompt carrying this task's
  # message_id — only this run's own session satisfies both (pr-* runs use
  # per-PR worktrees and their own prompts; summarize uses $DAEMON_DIR;
  # run-feat shares our flock).
  after_ls="$(ls "$SESSIONS_DIR" 2>/dev/null | sort)"
  new_sid="$(comm -13 <(printf '%s\n' "$before_ls") <(printf '%s\n' "$after_ls") \
    | python3 -c '
import json, os, sys
workdir, mid, sdir = sys.argv[1], sys.argv[2], sys.argv[3]
hit = ""
for cand in sys.stdin.read().split():
    try:
        d = json.load(open(os.path.join(sdir, cand, cand + ".json")))
    except Exception:
        continue  # meta not written yet / unreadable: cannot prove it is ours
    if d.get("cwd") == workdir and (not mid or mid in (d.get("prompt") or "")):
        hit = cand  # ids sort by creation ms; keep the last match
print(hit)
' "$WORKDIR" "${MID:-}" "$SESSIONS_DIR")"
  if [[ -n "$new_sid" ]]; then
    RESUME_ID="$new_sid"
    [[ -n "$RESUME_FILE" ]] && printf '%s' "$RESUME_ID" > "$RESUME_FILE"
  fi

  # rc=0: success. rc=124: our own hard cap fired — the attempt already did an
  # hour of real work; leave re-triage to the next timer tick instead of
  # retrying inside this run.
  if [[ $rc -eq 0 || $rc -eq 124 ]]; then break; fi

  # Classify the failure using ONLY this attempt's error-channel lines
  # ("type":"error" JSON events / agent_error hooks). Matching the whole log
  # would hit tool results echoing task.md, whose text itself contains
  # "LLM quota exhausted".
  # Three classes, ALL retried inside this run: quota / transient, plus
  # "other" (CLI bugs, session loss, pre-JSON crashes) — a cold+breadcrumb
  # retry beats giving up after one fluke failure.
  err_lines() { tail -n "+$((start_line + 1))" "$RUN_LOG" | grep -E '"type":"error"|agent_error' || true; }
  kind=""
  if err_lines | grep -qiE "$QUOTA_PATTERN"; then
    kind=quota; wait_s=$QUOTA_RETRY_SECONDS; waited=$quota_waited; max_wait=$QUOTA_MAX_WAIT_SECONDS
  elif err_lines | grep -qiE "$TRANSIENT_PATTERN"; then
    kind=transient; wait_s=$TRANSIENT_RETRY_SECONDS; waited=$transient_waited; max_wait=$TRANSIENT_MAX_WAIT_SECONDS
  else
    kind=other; wait_s=$OTHER_RETRY_SECONDS; waited=$other_waited; max_wait=$OTHER_MAX_WAIT_SECONDS
  fi

  # Multi-key rotation: quota → next key, retried NOW (no wait, no budget
  # consumed). Only once the whole list is exhausted does the billing-cycle
  # wait below engage (and that wait refreshes key #1's quota as well).
  if [[ "$kind" == quota && $((key_idx + 1)) -lt ${#API_KEYS[@]} ]]; then
    key_idx=$((key_idx + 1))
    echo "[$TS] quota exhausted on key #$key_idx — rotating to key #$((key_idx + 1))/${#API_KEYS[@]}, retrying NOW (no billing-cycle wait)" >> "$LOG_DIR/daemon.log"
    continue
  fi
  if [[ "$kind" == quota && ${#API_KEYS[@]} -gt 1 ]]; then
    echo "[$TS] all ${#API_KEYS[@]} keys quota-exhausted — billing-cycle wait engaged" >> "$LOG_DIR/daemon.log"
    key_idx=0
  fi

  if (( waited >= max_wait )); then
    echo "[$TS] $kind failure persists after ${waited}s of waiting (attempt $attempt exit=$rc), giving up" >> "$LOG_DIR/daemon.log"
    # marker to un-count the pick and demote the issue one priority class
    # (issues/issue-quota-demote.py) instead of letting it burn toward the
    # terminal fail state.
    [[ "$kind" == "quota" ]] && touch "$LOG_DIR/.quota-dead${HFV_SUF}"
    break
  fi
  echo "[$TS] $kind failure (attempt $attempt exit=$rc), waiting ${wait_s}s before retry (wait budget ${waited}/${max_wait}s; retry waiting does not consume the per-attempt timeout)" >> "$LOG_DIR/daemon.log"
  sleep "$wait_s"
  case "$kind" in
    quota)     quota_waited=$((quota_waited + wait_s)) ;;
    transient) transient_waited=$((transient_waited + wait_s)) ;;
    other)     other_waited=$((other_waited + wait_s)) ;;
  esac
done

# success: the conversation is complete; drop the session marker so the NEXT
# task on this issue cold-starts cleanly instead of carrying a finished
# session's breadcrumb.
[[ $rc -eq 0 && -n "${RESUME_FILE:-}" ]] && rm -f "$RESUME_FILE"

echo "[$TS] exit=$rc attempts=$attempt log=$RUN_LOG" >> "$LOG_DIR/daemon.log"

# Record this run's outcome for tasks.py close (task numbering bookkeeping).
mkdir -p "$DAEMON_DIR/tasks"
printf 'exit=%s\nlog=%s\n' "$rc" "$RUN_LOG" > "$DAEMON_DIR/tasks/.last-run-info${HFV_SUF}"

# the selection is consumed by post-deliver.sh (needs message_id to reply in
# the thread); do NOT delete current.json here — post-deliver.sh removes it
# after the delivery reply is sent, and issue-sync reads it too.

# Metrics: parse the run log into ClickHouse (best-effort, never fails the run).
# On retries the log holds every attempt; metrics keeps the last run_result,
# i.e. the decisive attempt.
python3 "$DAEMON_DIR/tools/metrics.py" "$RUN_LOG" "$rc" >> "$LOG_DIR/metrics.log" 2>&1 || true

# ALWAYS exit 0: systemd runs ExecStartPost (post-task.sh, which closes
# the task bookkeeping) only after a SUCCESSFUL ExecStart. Exiting nonzero
# on LLM failures would skip the whole post group, leaving the task row
# stuck in "running" forever. The real rc is already persisted in
# tasks/.last-run-info (read by tasks.py close) and in daemon.log.
exit 0
