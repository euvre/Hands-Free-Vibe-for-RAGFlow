#!/usr/bin/env bash
# hfv — hands-free vibe: manual control for the Feishu issue-triage +
# PR follow-up daemon. Canonical location: the hands-free-vibe repo;
# ~/.local/bin/hfv is a symlink to this file.
set -u

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
UNIT_SVC="cline-feishu-triage.service"
UNIT_FEAT_SVC="cline-feishu-feat@1.service"
UNIT_PRFOLLOW_SVC="cline-feishu-pr-follow@1.service"
UNIT_REBASE_SVC="cline-feishu-pr-rebase@1.service"
UNIT_REVIEW_SVC="cline-feishu-pr-review@1.service"
UNIT_AUDIT_SVC="cline-feishu-pr-audit@1.service"
UNIT_CI_SVC="cline-feishu-pr-ci@1.service"
UNIT_SUMMARIZE_SVC="cline-feishu-summarize.service"
UNIT_TIMER="cline-feishu-triage.timer"
UNIT_PRFOLLOW_TIMER="cline-feishu-pr-follow@1.timer"
UNIT_REBASE_TIMER="cline-feishu-pr-rebase@1.timer"
UNIT_REVIEW_TIMER="cline-feishu-pr-review@1.timer"
UNIT_AUDIT_TIMER="cline-feishu-pr-audit@1.timer"
UNIT_CI_TIMER="cline-feishu-pr-ci@1.timer"
LOG_DIR="$DIR/logs"

usage() {
  cat <<'USAGE'
    __  _____    _   ______  _____       __________  ____________   _    __________  ______
   / / / /   |  / | / / __ \/ ___/      / ____/ __ \/ ____/ ____/  | |  / /  _/ __ )/ ____/
  / /_/ / /| | /  |/ / / / /\__ \______/ /_  / /_/ / __/ / __/     | | / // // __  / __/
 / __  / ___ |/ /|  / /_/ /___/ /_____/ __/ / _, _/ /___/ /___     | |/ // // /_/ / /___
/_/ /_/_/  |_/_/ |_/_____//____/     /_/   /_/ |_/_____/_____/     |___/___/_____/_____/

hfv — hands-free vibe: the Feishu issue-triage + PR follow-up daemon
(hfv = hands-free vibe)

Architecture (everything runs in containers — there is no host-direct form):
the ISSUE line runs one task per throwaway container off the golden image
(hfv-task:latest, via lines/run-container.sh); FEAT runs containerized the
same way; the PR lines (follow/review/rebase/audit/ci timers, pr-*.lock)
share the main clone with per-PR worktrees and per-PR e2e groups. Every LLM
run gets a framework pre-flight injected (services pre-launched, env checks,
unit tier) — agents never redo bring-up.

Run control:
  hfv run [n]                  trigger one issue-triage run NOW on every
                                 enabled instance (or only instance <n>);
                                 an instance mid-run is skipped
  hfv feat -f <file>           run one feature-implementation task from the
                                 given spec file (the LLM only commits locally
                                 — a host-side post step pushes and opens the PR)
  hfv stop                     stop the running task on ANY line (issue / feat / pr)
  hfv on | off                 enable / disable all six timers
  hfv scale <line> <n>         run <n> parallel instances of a task line
                                 (issue|review|rebase|audit|ci|follow|feat|repr;
                                 0 = line off)

Watching runs (one throwaway container per run, hfv-task-<ts>):
  hfv ps                       live task containers: name / age / latest run log
  hfv log [line] [inst]        last 40 lines of a line instance's run log
                                 (no args: the first RUNning task)
  hfv follow [line] [inst]     tail -f the same log; --clean renders complete
                                 per-iteration content instead of raw JSONL

Issue line:
  hfv issue log | follow       the latest issue-line run log (static / tail -f)
  hfv issue rec [reset]        one issue-recording pass now; 'reset' drops the
                                 cursor so the next pass re-scans the full window
  hfv issue window [days]      show / set the issue sliding window (1-30 days)

PR stages (manual single-shot; the pr timers also run them automatically —
watch a running stage with: hfv follow <line>):
  hfv pr review <pr-num>       handle new reviewer comments on one PR now
                                 (CodeRabbit rounds with actionable findings
                                 count too; pure-bot/noise sets are skipped)
  hfv pr repr <pr-num>         re-run the PR's original task with the full
                                 stack: real end-to-end verification, fixes for
                                 what fails, then push + a report comment (for
                                 PRs delivered without real e2e verification)
  hfv pr rebase <pr-num>       run the conflict-rebase on one PR now
                                 (conflict-free branches are handled by a ~15s
                                 script, no LLM; only real conflicts launch one)
  hfv pr ci <pr-num>           run the CI-failure fix stage on one PR now
  hfv pr audit <pr-num>        WE review someone else's PR as the reviewer:
                                 full code-quality audit + main-task-grade e2e
                                 test inside the run's golden container, then
                                 reply on the PR (LGTM when clean); the auto
                                 line also picks up PRs review-requested to us.
                                 HFV_AUDIT_DRY_RUN=1 publishes/stamps nothing

PR line control (per line — review|rebase|audit|ci — or all):
  hfv pr unlock [line|all]     cut a quota/transient retry wait NOW: the next
                                 attempt fires immediately, free of the retry
                                 budget, logged as MANUAL UNLOCK
  hfv pr abandon [line|all]    kill the in-flight run NOW (quota burn / wedged
                                 / wrong direction). NOT terminal: the next tick
                                 re-picks the PR from GitHub state (contrast:
                                 task abandon IS terminal)
  hfv pr restart [line|all]    abandon + IMMEDIATE fresh run (no tick wait).
                                 Escalation: unlock < abandon < restart

Environment (the framework pre-flight every LLM run gets injected):
  hfv env check [worktree]     run the known-failure-mode checks now (API proxy
                                 scheme of the running vite / chrome Singleton
                                 locks / tokenizer+office_oxide native libs /
                                 node_modules / python imports / port status)
  hfv env up [worktree]        pre-launch services + bounded readiness wait +
                                 session keep-alive, then print the status
                                 section exactly as the LLM would see it

Tasks & records:
  hfv task list [n]            newest issue-task records (default 20)
  hfv task latest              print the newest task number
  hfv task show <id>           full record of one task (+ its context files)
  hfv task resume <id>         re-run unfinished task <id> on its original snapshot
  hfv task follow <id>         re-run task <id> with the issue's newest thread
                                 replies plus the previous PR/context injected
  hfv task abandon <id>        terminate task <id> permanently (never resumed or
                                 auto-selected again; local only, no Feishu message)

LLM profiles & keys:
  hfv model [kimi|glm]         show / switch the LLM profile (applies to new
                                 runs; refused while an active run is working —
                                 quota-parked runs make the switch allowed)
  hfv key show                 per-profile api-key LIST (masked), in quota-
                                 rotation order — an exhausted key rotates to
                                 the next immediately; the billing-cycle wait
                                 engages only when the whole list is drained
  hfv key add <kimi|glm> <key> append a key (dedup; '--stdin' reads it from
                                 stdin so it never lands in the shell history;
                                 '--force' skips the provider shape guardrail)
  hfv key remove <kimi|glm> <key>
                                 remove a key by exact value (or '--stdin')
  hfv key rotate <kimi|glm> [n]
                                 left-rotate the key list by n (default 1: head
                                 moves to the end; negative rotates right) —
                                 the NEXT run starts from the new head;
                                 running tasks are unaffected

Prompts:
  hfv prompt list              prompt files with their variants and the active pick
  hfv prompt show <base>[@v]   print a prompt (default: the active version)
  hfv prompt use <base>[@v]    select a variant (writes PROMPT_VARIANT_* into
                                 hfv.conf; bare <base> falls back to the default)

Misc:
  hfv status                   services, timers, model profile, recent daemon log
  hfv stats [hours]            ClickHouse metrics summary (default 24h; 168 = 7d)
  hfv summarize                trigger one lesson-tree sweep now
USAGE
}

latest_log()        { ls -1t "$LOG_DIR"/run-[0-9]*.log "$LOG_DIR"/run-feat-[0-9]*.log 2>/dev/null | grep -vE -- '-s[0-9]+\.log$' | head -1; }
latest_stage_log()  { ls -1t "$LOG_DIR"/run-pr-"$1"-*.log 2>/dev/null | head -1; }

follow_log() { # follow_log <stage|main> <label>
  local f
  if [[ "$1" == "main" ]]; then f="$(latest_log)"; else f="$(latest_stage_log "$1")"; fi
  if [[ -n "$f" ]]; then
    echo "# following $2 log: $f"
    tail -n 20 "$f"
    tail -f "$f"
  else
    echo "no $2 logs yet"
  fi
}

# A run counts as active iff the shared flock is held — covers issue and feat
# runs regardless of how they were started (oneshot services report
# "activating", not "active", while running, so is-active is unreliable).
any_active() {
  # A run is active iff ANY run lock is held (legacy run.lock / run-s<n>.lock)
  # or any one-shot task container is live (hfv-task-*, run-container.sh —
  # those hold no run lock). Independent of systemd's oneshot "activating".
  local f
  for f in "$DIR"/locks/run.lock "$DIR"/locks/run-s*.lock; do
    [[ -e "$f" ]] || continue
    flock -n "$f" -c true 2>/dev/null || return 0
  done
  [[ -n "$(docker ps -q --filter 'name=hfv-task-' 2>/dev/null)" ]] && return 0
  return 1
}

any_pr_active() {
  local f
  for f in "$DIR"/locks/pr-follow-*.lock "$DIR"/locks/pr-rebase-*.lock "$DIR"/locks/pr-review-*.lock "$DIR"/locks/pr-audit-*.lock "$DIR"/locks/pr-ci-*.lock; do
    [[ -e "$f" ]] || continue
    flock -n "$f" -c true 2>/dev/null || return 0
  done
  return 1
}

# Every active run is parked in an LLM quota/transient wait? (markers are
# written by the runners' wait loops to logs/llm-wait/<lock-name> for exactly
# the wait's duration). Used by `hfv model`: a parked run is asleep, so
# switching the profile is safe; a WORKING run keeps the refusal.
all_active_llm_parked() {
  local f name c
  for f in "$DIR"/locks/run.lock "$DIR"/locks/run-s*.lock "$DIR"/locks/run-feat-*.lock \
           "$DIR"/locks/pr-follow-*.lock "$DIR"/locks/pr-rebase-*.lock "$DIR"/locks/pr-review-*.lock "$DIR"/locks/pr-audit-*.lock "$DIR"/locks/pr-ci-*.lock; do
    [[ -e "$f" ]] || continue
    if ! flock -n "$f" -c true 2>/dev/null; then
      name="$(basename "$f" .lock)"
      [[ -f "$DIR/logs/llm-wait/$name" ]] || return 1
    fi
  done
  for c in $(docker ps --format '{{.Names}}' --filter 'name=hfv-task-' 2>/dev/null); do
    case "$c" in
      *-spr-*) ;;                                    # PR line container — its line lock above carries the flag
      *-s[0-9]*) [[ -f "$DIR/logs/llm-wait/run-${c##*-}" ]] || return 1 ;;  # issue slot container
      *) return 1 ;;                                 # legacy/unnamed container — treat as working
    esac
  done
  return 0
}

pr_stage() { # pr_stage <review|rebase|audit|ci> <pr-num>
  local action="$1" sub="${2:-}"
  case "$sub" in
    ''|*[!0-9]*)
      echo "usage: hfv pr $action <pr-num>  (watch a running stage: hfv follow $action)" >&2; exit 1
      ;;
    *)
      # Serialize on the line's OWN lock only: the exec'd script takes it
      # (audit), or pr-follow.lock + the line lock (review/rebase via
      # pr-follow.sh). Other lines live in different clone/worktree
      # namespaces with their own locks — NOT conflicts; their timers
      # already run them concurrently with each other.
      if [[ "$action" == "audit" || "$action" == "ci" || "$action" == "repr" ]]; then
        if ! flock -n "$DIR/locks/pr-$action.lock" -c true 2>/dev/null; then
          echo "pr-$action line busy (its lock is held — often just an LLM retry wait). Wait, or 'hfv pr unlock $action' / 'hfv pr abandon $action'." >&2; exit 1
        fi
      else
        busy=0
        for f in "$DIR"/locks/pr-follow-*.lock; do
          [[ -e "$f" ]] || continue
          flock -n "$f" -c true 2>/dev/null || busy=1
        done
        if [[ $busy -eq 1 ]]; then
          echo "another manual PR run is active (pr-follow-*.lock). Wait for it or 'hfv stop'." >&2; exit 1
        fi
        # The line locks are per-instance (pr-review-1.lock etc.), not the
        # unnumbered name — checking only the unnumbered one let a manual run
        # start while the timer line was busy, then die silently on the real
        # lock (2026-09-18: manual review 19812 bounced behind review 19743).
        for f in "$DIR/locks/pr-$action.lock" "$DIR"/locks/pr-$action-*.lock; do
          [[ -e "$f" ]] || continue
          if ! flock -n "$f" -c true 2>/dev/null; then
            echo "pr-$action line busy ($(basename "$f") is held — often just an LLM retry wait). Wait, or 'hfv pr unlock $action' / 'hfv pr abandon $action'." >&2; exit 1
          fi
        done
      fi
      mlog="$LOG_DIR/manual-$action-$sub-$(date +%Y%m%d-%H%M%S).log"
      if [[ "$action" == "audit" ]]; then
        setsid nohup bash "$DIR/lines/pr-audit-line.sh" --single "$sub" >>"$mlog" 2>&1 </dev/null &
      elif [[ "$action" == "ci" ]]; then
        setsid nohup bash "$DIR/lines/pr-ci-line.sh" --single "$sub" >>"$mlog" 2>&1 </dev/null &
      elif [[ "$action" == "repr" ]]; then
        setsid nohup bash "$DIR/lines/pr-repr-line.sh" --single "$sub" >>"$mlog" 2>&1 </dev/null &
      else
        setsid nohup bash "$DIR/lines/pr-follow.sh" "$action" "$sub" >>"$mlog" 2>&1 </dev/null &
      fi
      echo "started PR #$sub $action stage in background (pid $!)"
      echo "trigger log: $mlog — watch the run with: hfv follow $action"
      ;;
  esac
}


# Manual unlock of a PR line stuck in an LLM retry wait (quota / transient /
# other). Writes the unlock flag consumed by run_llm's sliced wait loop in
# pr-llm-run.sh and kills the current sleep slice for an immediate effect.
# The unlocked retry does NOT consume the line's retry budget and is logged
# as MANUAL UNLOCK (daemon.log + run log) by the consuming loop.
pr_unlock() { # pr_unlock [review|rebase|audit|ci|all]
  local line="${1:-all}" ln lock flag flag_dir pids p comm sleeper owner
  case "$line" in
    review|rebase|audit|ci|all) ;;
    *) echo "usage: hfv pr unlock [review|rebase|audit|ci|all]" >&2; exit 1 ;;
  esac
  flag_dir="${HFV_UNLOCK_FLAG_DIR:-$DIR}"
  for ln in review rebase audit ci; do
    [[ "$line" == all || "$line" == "$ln" ]] || continue
    lock="$DIR/locks/pr-$ln.lock"; flag="$flag_dir/pr-unlock-$ln.flag"
    # Lock holders = the line's bash (fd 9) plus any child that inherited
    # fd 9. During an LLM retry wait the sleep child holds it too — that is
    # the only state a manual unlock makes sense in.
    pids="$(fuser "$lock" 2>/dev/null | tr -cs '0-9' '\n' | grep -E '^[0-9]+$' | sort -u || true)"
    if [[ -z "$pids" ]]; then
      rm -f "$flag"
      echo "pr-$ln line: not running (no lock holder) — nothing to unlock; stale flag (if any) removed"
      continue
    fi
    sleeper=""; owner=""
    for p in $pids; do
      comm="$(cat "/proc/$p/comm" 2>/dev/null || true)"
      if [[ "$comm" == "sleep" ]]; then sleeper="$p"; else owner="$p"; fi
    done
    if [[ -z "$sleeper" ]]; then
      echo "pr-$ln line: active (pid ${owner:-?}) but NOT inside an LLM retry wait — nothing to unlock"
      continue
    fi
    date +%s > "$flag"                      # consumed by run_llm (fresh ≤300s)
    kill "$sleeper" 2>/dev/null || true     # cut the current slice: immediate
    echo "[$(date +%Y%m%d-%H%M%S)] hfv: manual unlock: pr-$ln line (owner pid $owner, sleeper pid $sleeper cut) — next attempt fires immediately, retry budget NOT consumed" >> "$LOG_DIR/daemon.log"
    echo "pr-$ln line unblocked (owner pid $owner): retry fires immediately, logged as MANUAL UNLOCK, retry budget NOT consumed"
  done
}

pr_abandon() { # pr_abandon [review|rebase|audit|all] — kill the in-flight run
  # of a PR line NOW (quota burn / wedged / wrong direction). Unlike `task
  # abandon` (terminal: the local task registry owns selection) the PR lines
  # derive their candidates from GitHub state every tick and keep no local
  # terminal marker — so an abandoned PR simply becomes eligible again:
  #   review/rebase: unanswered comments / rebase need are still on GitHub
  #   audit: a mid-run kill writes no verdict, and shas without a verdict
  #          stamp are re-queued by pr-audit.py collect (proven by 19221)
  local line="${1:-all}" ln unit lock pids act i c others
  case "$line" in
    review|rebase|audit|ci|all) ;;
    *) echo "usage: hfv pr abandon [review|rebase|audit|ci|all]" >&2; exit 1 ;;
  esac
  for ln in review rebase audit ci; do
    [[ "$line" == all || "$line" == "$ln" ]] || continue
    unit="cline-feishu-pr-$ln.service"
    lock="$DIR/locks/pr-$ln.lock"
    pids="$(fuser "$lock" 2>/dev/null | tr -cs '0-9' '\n' | grep -E '^[0-9]+$' | sort -u || true)"
    act="$(systemctl --user is-active "$unit" 2>/dev/null || true)"
    if [[ -z "$pids" && "$act" != "active" && "$act" != "activating" ]]; then
      echo "pr-$ln line: not running — nothing to abandon"
      continue
    fi
    systemctl --user stop "$unit"   # kills the whole cgroup: line script + cline
    echo "[$(date +%Y%m%d-%H%M%S)] hfv: manual abandon: pr-$ln line killed (unit stopped; pids: ${pids:-unit-only}) — PR stays eligible, next tick re-picks from GitHub state" >> "$LOG_DIR/daemon.log"
    for i in 1 2 3 4 5; do
      flock -n "$lock" -c true 2>/dev/null && break
      sleep 1
    done
    if ! flock -n "$lock" -c true 2>/dev/null; then
      # Manual runs (setsid, outside the unit cgroup — e.g. `hfv pr audit <N>`
      # wrappers) survive systemctl stop; the LOCK is the ground truth for
      # "running", so kill its holders directly: TERM, then KILL.
      pids="$(fuser "$lock" 2>/dev/null | tr -cs '0-9' '\n' | grep -E '^[0-9]+$' | sort -u || true)"
      [[ -n "$pids" ]] && { kill $pids 2>/dev/null || true; sleep 2; }
      if ! flock -n "$lock" -c true 2>/dev/null; then
        pids="$(fuser "$lock" 2>/dev/null | tr -cs '0-9' '\n' | grep -E '^[0-9]+$' | sort -u || true)"
        [[ -n "$pids" ]] && { kill -9 $pids 2>/dev/null || true; sleep 1; }
      fi
    fi
    if flock -n "$lock" -c true 2>/dev/null; then
      echo "pr-$ln line: in-flight run killed, lock released — PR stays eligible (next tick re-picks; force now: hfv pr $ln <N>)"
    else
      echo "pr-$ln line: kill sent but the lock is STILL held — inspect: fuser $lock"
    fi
  done
}

pr_restart() { # pr_restart [review|rebase|audit|all] — kill the in-flight run
  # AND immediately trigger a FRESH line run (new PRE -> candidate selection ->
  # LLM). The three interventions, in order of escalation:
  #   unlock  : no kill; cuts an LLM retry WAIT inside the SAME run (budget kept)
  #   abandon : kill only; the PR stays eligible but waits for the next TICK
  #   restart : abandon + immediate fresh run (no tick wait); with nothing
  #             running it degrades to a plain trigger (like a manual tick)
  local line="${1:-all}" ln unit i
  case "$line" in
    review|rebase|audit|ci|all) ;;
    *) echo "usage: hfv pr restart [review|rebase|audit|ci|all]" >&2; exit 1 ;;
  esac
  for ln in review rebase audit ci; do
    [[ "$line" == all || "$line" == "$ln" ]] || continue
    unit="cline-feishu-pr-$ln.service"
    pr_abandon "$ln" || true
    # the abandon kill waits for the lock internally; give stragglers one more
    # beat so the fresh run does not lose the flock race and no-op out
    for i in 1 2 3 4 5; do
      flock -n "$DIR/locks/pr-$ln.lock" -c true 2>/dev/null && break
      sleep 1
    done
    # --no-block: oneshot unit — a plain start blocks until the whole run
    # finishes (potentially an hour+)
    systemctl --user start --no-block "$unit"
    echo "pr-$ln line: fresh run triggered (restart = kill + immediate tick); watch: hfv pr $ln log"
  done
}


case "${1:-help}" in
  run)
    # hfv run [n] — trigger one issue-triage run NOW on every enabled
    # instance (or only instance <n>); an instance whose run lock is held is
    # skipped. --no-block: these are Type=oneshot units — a plain `start`
    # blocks until the whole run finishes (an hour+), and if the waiting
    # client is killed systemd cancels its still-queued job, taking the run
    # down with it.
    only="${2:-}"
    triggered=0
    for l in "$HOME"/.config/systemd/user/timers.target.wants/cline-feishu-triage@[0-9]*.timer; do
      [[ -e "$l" ]] || continue
      inst="$(basename "$l" | sed -n 's/^cline-feishu-triage@\([0-9][0-9]*\)\.timer$/\1/p')"
      [[ -n "$only" && "$inst" != "$only" ]] && continue
      if ! flock -n "$DIR/locks/run-s$inst.lock" -c true 2>/dev/null; then
        echo "instance $inst: a run is already active; skipped (run-s$inst.lock held)"
        continue
      fi
      systemctl --user start --no-block "cline-feishu-triage@$inst.service"
      echo "instance $inst: run triggered"
      triggered=1
    done
    [[ "$triggered" -eq 1 ]] || { [[ -n "$only" ]] && echo "instance $only: not enabled (hfv scale issue <n>)" >&2; }
    if [[ "$triggered" -eq 0 && -z "$only" ]]; then
      echo "no issue instances enabled — scale up first: hfv scale issue <n>" >&2
      exit 1
    fi
    echo "watch with: hfv ps"
    ;;
  feat)
    shift
    SPEC=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -f|--file) SPEC="${2:-}"; shift 2 ;;
        *) echo "unknown argument: $1 (usage: hfv feat -f <spec-file>)"; exit 1 ;;
      esac
    done
    if [[ -z "$SPEC" ]]; then
      echo "usage: hfv feat -f <spec-file>"; exit 1
    fi
    if [[ ! -s "$SPEC" ]]; then
      echo "spec file not found or empty: $SPEC"; exit 1
    fi
    # assign the spec to the first free feat instance (hfv scale feat <N>)
    SPEC="$(readlink -f "$SPEC")"
    FEAT_DIR="$DIR/feat"
    mkdir -p "$FEAT_DIR"
    nfeat=1
    [[ -f "$DIR/state/.scale-feat" ]] && nfeat="$(cat "$DIR/state/.scale-feat" 2>/dev/null)"
    [[ "$nfeat" =~ ^[0-9]+$ && "$nfeat" -ge 1 ]] || nfeat=1
    inst=""
    for (( i = 1; i <= nfeat; i++ )); do
      if flock -n "$DIR/locks/run-feat-$i.lock" -c true 2>/dev/null; then inst="$i"; break; fi
    done
    if [[ -z "$inst" ]]; then
      echo "all $nfeat feat instance(s) busy; try again later (or: hfv scale feat <n>)"
      exit 1
    fi
    cp "$SPEC" "$FEAT_DIR/current-feature-$inst.md"
    echo "$SPEC" > "$FEAT_DIR/current-feature-$inst.source"
    cp "$SPEC" "$FEAT_DIR/feature-$(date +%Y%m%d-%H%M%S)-i$inst.md"
    systemctl --user start --no-block "cline-feishu-feat@$inst.service"
    echo "feat run triggered with spec: $SPEC"
    echo "watch with: hfv issue follow"
    ;;
  stop)
    systemctl --user stop "$UNIT_SVC" "$UNIT_PRFOLLOW_SVC" "$UNIT_REBASE_SVC" "$UNIT_REVIEW_SVC" "$UNIT_AUDIT_SVC"
    feat_units="$(systemctl --user list-units 'cline-feishu-feat@*.service' --state=activating,running --no-legend 2>/dev/null | awk '{print $1}')"
    [[ -z "$feat_units" ]] || systemctl --user stop $feat_units
    # Task containers are dockerd children, NOT in any unit's cgroup — remove
    # them explicitly or they would keep running headless.
    tasks="$(docker ps -q --filter 'name=hfv-task-' 2>/dev/null)"
    [[ -z "$tasks" ]] || docker rm -f $tasks >/dev/null 2>&1
    echo "stop signal sent (issue/feat/pr lines + any task containers; timers untouched)"
    ;;
  on)
    systemctl --user enable --now "$UNIT_TIMER" "$UNIT_PRFOLLOW_TIMER" "$UNIT_REBASE_TIMER" "$UNIT_REVIEW_TIMER" "$UNIT_AUDIT_TIMER" "$UNIT_CI_TIMER" && echo "timers enabled (triage + pr-follow + pr-review + pr-rebase + pr-audit + pr-ci)"
    ;;
  off)
    systemctl --user stop "$UNIT_TIMER" "$UNIT_PRFOLLOW_TIMER" "$UNIT_REBASE_TIMER" "$UNIT_REVIEW_TIMER" "$UNIT_AUDIT_TIMER" "$UNIT_CI_TIMER"; systemctl --user disable "$UNIT_TIMER" "$UNIT_PRFOLLOW_TIMER" "$UNIT_REBASE_TIMER" "$UNIT_REVIEW_TIMER" "$UNIT_AUDIT_TIMER" "$UNIT_CI_TIMER"
    echo "timers disabled (triage + pr-follow + pr-review + pr-rebase + pr-audit + pr-ci)"
    ;;
  scale)
    # hfv scale <line> <n> — run <n> parallel instances of a task line
    # (0 = line off). Lines: issue | review | rebase | audit | ci | follow |
    # feat. Each instance gets its own lock (…-<inst>.lock) and takes the
    # candidates where (index % N == inst-1); the instance count lands in
    # .scale-<line> for the line script to shard by.
    LINE="${2:-}"
    N="${3:-}"
    case "$LINE" in
      issue)  UNIT_PREFIX="cline-feishu-triage" ;;
      review|rebase|audit|ci|follow) UNIT_PREFIX="cline-feishu-pr-$LINE" ;;
      feat)   UNIT_PREFIX="cline-feishu-feat" ;;
      *) echo "usage: hfv scale <issue|review|rebase|audit|ci|follow|feat> <n>" >&2; exit 1 ;;
    esac
    [[ "$N" =~ ^[0-9]+$ ]] || { echo "usage: hfv scale $LINE <n>" >&2; exit 1; }
    avail_mb="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)"
    if (( N > 0 && avail_mb / N < 10240 )); then
      echo "warning: ${avail_mb}MiB available over $N instance(s) — each wants a ~15-17G budget. Continuing anyway."
    fi
    echo "$N" > "$DIR/state/.scale-$LINE"
    for (( i = 1; i <= N; i++ )); do
      systemctl --user enable --now "${UNIT_PREFIX}@${i}.timer" >/dev/null 2>&1
    done
    # disable every enabled instance above N (wants symlinks are the
    # enablement ground truth; list-unit-files hides template instances)
    for l in "$HOME"/.config/systemd/user/timers.target.wants/"${UNIT_PREFIX}"@[0-9]*.timer; do
      [[ -e "$l" ]] || continue
      inst="$(basename "$l" | sed -n "s/^${UNIT_PREFIX}@\([0-9][0-9]*\)\.timer\$/\1/p")"
      [[ -n "$inst" && "$inst" -le "$N" ]] && continue
      systemctl --user disable --now "${UNIT_PREFIX}@${inst}.timer" 2>/dev/null
    done
    echo "$LINE line scaled to $N instance(s). Watch with: hfv ps"
    ;;
  ps)
    python3 - "$DIR" "$LOG_DIR" <<'PYPS'
import fcntl, glob, os, re, subprocess, sys, time, unicodedata
DIR, LOG_DIR = sys.argv[1], sys.argv[2]

def width(s):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)

def fit(s, n):
    out, acc = "", 0
    for c in s:
        cw = 2 if unicodedata.east_asian_width(c) in "WF" else 1
        if acc + cw > n:
            return out + " " * (n - acc)
        out += c; acc += cw
    return out + " " * (n - acc)

def lock_held(path):
    if not os.path.exists(path):
        return False
    fd = os.open(path, os.O_WRONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    except OSError:
        return True
    finally:
        os.close(fd)

def latest(pat):
    fs = sorted(glob.glob(pat), key=os.path.getmtime, reverse=True)
    return os.path.basename(fs[0]) if fs else "-"

rows = []
now = time.time()

def emit(line, inst, lock, marker, log):
    state, task, age = "idle", "-", "-"
    if marker and os.path.exists(marker) and lock_held(lock):
        state = "RUN"
        raw = open(marker, errors="replace").read().strip()
        parts = raw.split("\t")
        task = (parts[1] if len(parts) > 1 and parts[1] else parts[0])[:60] if raw else "-"
        mmt = os.path.getmtime(marker)
        age = "%d min" % max(0, (now - mmt) // 60)
        lf = os.path.join(LOG_DIR, log)
        if log == "-" or not os.path.exists(lf) or os.path.getmtime(lf) < mmt:
            log = "(starting)"
    rows.append((line, inst, state, task, age, log))

home = os.path.expanduser("~")
for l in sorted(glob.glob(home + "/.config/systemd/user/timers.target.wants/cline-feishu-triage@[0-9]*.timer")):
    m = re.search(r"@(\d+)\.timer$", l)
    if not m:
        continue
    i = m.group(1)
    emit("issue", i, f"{DIR}/locks/run-s{i}.lock", f"{DIR}/state/.current-issue-{i}",
         latest(f"{LOG_DIR}/run-[0-9]*-s{i}.log"))
for line in ("review", "rebase", "audit", "ci", "follow"):
    n = 1
    f = f"{DIR}/state/.scale-{line}"
    if os.path.exists(f):
        try: n = max(1, int(open(f).read().strip()))
        except Exception: n = 1
    for i in range(1, n + 1):
        emit(line, str(i), f"{DIR}/locks/pr-{line}-{i}.lock", f"{DIR}/state/.current-{line}-{i}",
             latest(f"{LOG_DIR}/run-pr-{line}-*.log"))
# repr is manual-only: unnumbered lock and marker, never scaled
emit("repr", "1", f"{DIR}/locks/pr-repr.lock", f"{DIR}/state/.current-repr",
     latest(f"{LOG_DIR}/run-pr-repr-*.log"))
n = 1
f = f"{DIR}/state/.scale-feat"
if os.path.exists(f):
    try: n = max(1, int(open(f).read().strip()))
    except Exception: n = 1
for i in range(1, n + 1):
    emit("feat", str(i), f"{DIR}/locks/run-feat-{i}.lock", f"{DIR}/state/.current-feat-{i}",
         latest(f"{LOG_DIR}/run-feat-*.log"))

print(fit("LINE", 8) + " " + fit("INST", 4) + " " + fit("STATE", 5) + " "
      + fit("TASK", 42) + " " + fit("AGE", 8) + "LOG")
for r in rows:
    print(fit(r[0], 8) + " " + fit(r[1], 4) + " " + fit(r[2], 5) + " "
          + fit(r[3], 42) + " " + fit(r[4], 8) + r[5])
mem = subprocess.run(["free", "-h"], capture_output=True, text=True).stdout.splitlines()[1].split()
print("Mem: %s(total) %s(used) %s(free) %s(shared) %s(buff/cache) %s(available)"
      % tuple(mem[1:7]))
PYPS
    ;;
  log|follow)
    subcmd="$1"; shift
    # hfv log|follow [line] [inst] [--clean]: the run log of a line instance.
    # --clean renders each iteration's COMPLETE content instead of the raw
    # token-fragment JSONL (tools/cline-log-clean.py).
    # Defaults: the first RUNning task, else instance 1 of the issue line.
    clean=0
    for a in "$@"; do [[ "$a" == "--clean" ]] && clean=1; done
    line="${1:-}"; inst="${2:-1}"
    [[ "$line" == "--clean" ]] && line=""
    [[ "$inst" == "--clean" ]] && inst=1
    if [[ -z "$line" ]]; then
      for m in "$DIR"/state/.current-issue-* "$DIR"/state/.current-review-* "$DIR"/state/.current-rebase-* "$DIR"/state/.current-audit-* "$DIR"/state/.current-ci-* "$DIR"/state/.current-feat-* "$DIR"/state/.current-repr; do
        [[ -f "$m" ]] || continue
        base="$(basename "$m")"; line="${base#.current-}"; line="${line%-*}"; inst="${base##*-}"
        break
      done
      [[ -z "$line" ]] && line=issue
    fi
    case "$line" in
      issue) f="$(ls -1t "$LOG_DIR"/run-[0-9]*-s"$inst".log 2>/dev/null | head -1)" ;;
      feat)  f="$(ls -1t "$LOG_DIR"/run-feat-*.log 2>/dev/null | head -1)" ;;
      review|rebase|audit|ci|follow|repr)
             f="$(ls -1t "$LOG_DIR"/run-pr-"$line"-*.log 2>/dev/null | head -1)" ;;
      *) echo "usage: hfv $subcmd [issue|review|rebase|audit|ci|follow|feat|repr] [inst]" >&2; exit 1 ;;
    esac
    if [[ -z "$f" ]]; then
      echo "no run log for $line $inst yet"
    elif [[ "$subcmd" == "log" ]]; then
      if [[ $clean -eq 1 ]]; then
        tail -n 400 "$f" | python3 "$DIR/tools/cline-log-clean.py" | tail -n 60
      else
        tail -n 40 "$f"
      fi
    else
      echo "# following $line $inst: $f"
      if [[ $clean -eq 1 ]]; then
        tail -n 400 "$f" | python3 "$DIR/tools/cline-log-clean.py" | tail -n 40
        tail -f "$f" | python3 "$DIR/tools/cline-log-clean.py"
      else
        tail -n 20 "$f"
        tail -f "$f"
      fi
    fi
    ;;
  issue)
    shift
    case "${1:-}" in
      log)
        f="$(latest_log)"; [[ -n "$f" ]] && tail -n 40 "$f" || echo "no run logs yet"
        ;;
      follow)
        follow_log main "issue-line run"
        ;;
      rec)
        CURSOR="$DIR/issues/.cursor"
        case "${2:-}" in
          "")
            bash "$DIR/issues/issue-recorder.sh"
            echo "recording pass done. Watch with: tail -20 $DIR/logs/issues.log"
            ;;
          reset)
            if any_active; then
              echo "a run is active; cursor reset refused (a concurrent pass would re-advance it). Wait for it to finish or 'hfv stop'."
              exit 1
            fi
            if [[ -f "$CURSOR" ]]; then
              old="$(cat "$CURSOR")"
              rm -f "$CURSOR"
              echo "cursor removed (was $old). Next pass re-scans the full sliding window; records are deduped by message_id."
              echo "run 'hfv issue rec' to trigger the re-scan now."
            else
              echo "no cursor file present; nothing to reset."
            fi
            ;;
          *)
            echo "usage: hfv issue rec [reset]" >&2; exit 1 ;;
        esac
        ;;
      window)
        CFG="$DIR/issues/config"
        cur="$(grep -E '^WINDOW_DAYS=' "$CFG" 2>/dev/null | tail -1 | cut -d= -f2)"
        cur="${cur:-7}"
        if [[ $# -eq 1 ]]; then
          echo "window=${cur}d (issues older than this leave the store on the next recording pass)"
        elif [[ $# -eq 2 && "$2" =~ ^[0-9]+$ ]] && (( $2 >= 1 && $2 <= 30 )); then
          if any_active; then
            echo "a run is active; window change refused (a concurrent recording pass would race the config write). Wait for it to finish or 'hfv stop'."
            exit 1
          fi
          if [[ -z "$(grep -E '^WINDOW_DAYS=' "$CFG" 2>/dev/null)" ]]; then
            echo "WINDOW_DAYS=$2" >> "$CFG"
          else
            tmp="$(mktemp)"
            sed -i "s/^WINDOW_DAYS=.*/WINDOW_DAYS=$2/w $tmp" "$CFG"
            rm -f "$tmp"
          fi
          echo "window set: ${cur}d -> $2d"
          (( $2 > cur )) && echo "note: history beyond the old window is NOT re-scanned automatically; run 'hfv issue rec reset && hfv issue rec' to re-scan the full ${2}d window."
        else
          echo "usage: hfv issue window [days]  (1-30)" >&2
          exit 1
        fi
        ;;
      *)
        echo "usage: hfv issue log|follow|rec [reset]|window [days]" >&2; exit 1 ;;
    esac
    ;;
  pr)
    shift
    case "${1:-}" in
      review|rebase) pr_stage "$1" "${2:-}" ;;
      ci) pr_stage ci "${2:-}" ;;
      repr) pr_stage repr "${2:-}" ;;
      audit) pr_stage audit "${2:-}" ;;
      unlock) pr_unlock "${2:-all}" ;;
      abandon) pr_abandon "${2:-all}" ;;
      restart) pr_restart "${2:-all}" ;;
      *) echo "usage: hfv pr review|rebase|audit|ci|repr <pr-num> | unlock [line] | abandon [line] | restart [line]" >&2; exit 1 ;;
    esac
    ;;
  task)
    shift
    TASKS="$DIR/tools/tasks.py"
    case "${1:-}" in
      ""|list)
        python3 "$TASKS" list "${2:-20}"
        ;;
      latest)
        python3 "$TASKS" latest
        ;;
      show)
        [[ -n "${2:-}" ]] || { echo "usage: hfv task show <id>"; exit 1; }
        python3 "$TASKS" show "$2"
        ;;
      resume|follow)
        MODE="$1"; TID="${2:-}"
        [[ -n "$TID" && "$TID" =~ ^[0-9]+$ ]] || { echo "usage: hfv task $MODE <id>"; exit 1; }
        if any_active; then
          echo "a run is already active; task $MODE refused (flock). Wait for it to finish or 'hfv stop'."
          exit 1
        fi
        if ! python3 - "$TID" "$MODE" <<'CHK'
import json, os, sys
tid, mode = int(sys.argv[1]), sys.argv[2]
rows = [json.loads(l) for l in open(os.path.expanduser("~/hands-free-vibe/tasks/tasks.jsonl")) if l.strip()] \
    if os.path.exists(os.path.expanduser("~/hands-free-vibe/tasks/tasks.jsonl")) else []
row = next((r for r in rows if r["task_id"] == tid), None)
if not row:
    print(f"task #{tid} not found"); sys.exit(1)
if row.get("status") == "running":
    print(f"task #{tid} is still running"); sys.exit(1)
if row.get("status") == "abandoned":
    print(f"task #{tid} is abandoned (terminal); refusing to revive it"); sys.exit(1)
if mode == "follow" and not row.get("pr"):
    print(f"task #{tid} has no delivered PR to follow up on"); sys.exit(1)
store = os.path.expanduser("~/hands-free-vibe/issues/issues.jsonl")
if os.path.exists(store):
    mids = {json.loads(l).get("message_id") for l in open(store) if l.strip()}
    if row.get("message_id") not in mids:
        print(f"issue of task #{tid} is no longer tracked (dropped/handed over)"); sys.exit(1)
CHK
        then
          exit 1
        fi
        printf '{"task_id": %s, "mode": "%s"}\n' "$TID" "$MODE" > "$DIR/tasks/.pin"
        systemctl --user start "$UNIT_SVC"
        echo "task #$TID $MODE pinned and triggered. Watch with: hfv issue follow"
        ;;
      abandon)
        TID="${2:-}"
        [[ "$TID" =~ ^[0-9]+$ ]] || { echo "usage: hfv task abandon <id>"; exit 1; }
        OUT="$(python3 "$TASKS" abandon "$TID")" || exit 1
        MID="${OUT%%$'\t'*}"; CUR="${OUT##*$'\t'}"
        if [[ -n "$MID" ]]; then
          python3 - "$DIR/issues/issues.jsonl" "$MID" <<'PYEOF'
import json, os, sys, time
store, mid = sys.argv[1], sys.argv[2]
TERMINAL = ("done", "merged", "closed", "abandoned", "fail")
if not os.path.exists(store):
    print("issue store absent; nothing to pin")
    raise SystemExit(0)
records = [json.loads(l) for l in open(store) if l.strip()]
for r in records:
    if r.get("message_id") == mid:
        st = r.get("state")
        if st in TERMINAL:
            print(f"issue already terminal (state={st}); left as-is")
        else:
            r["state"] = "abandoned"
            r["abandoned_time"] = int(time.time() * 1000)
            tmp = store + ".tmp"
            with open(tmp, "w") as f:
                for rr in records:
                    f.write(json.dumps(rr, ensure_ascii=False) + "\n")
            os.replace(tmp, store)
            print(f"issue {mid} pinned to state=abandoned (never auto-selected again)")
        break
else:
    print(f"issue {mid} not in store (already dropped); nothing to pin")
PYEOF
        fi
        if [[ "$CUR" == "1" ]] && any_active; then
          systemctl --user stop "$UNIT_SVC"
          rm -f "$DIR/issues/current.json"
          rm -rf "$DIR/deliver"
          echo "task #$TID was the running task — LLM terminated, current.json/deliver cleaned"
        fi
        echo "task #$TID abandoned (terminal; never resumed/followed/auto-selected)"
        ;;
      *)
        echo "unknown task subcommand: $1 (usage: hfv task list|latest|show|resume|follow|abandon)" >&2
        exit 1
        ;;
    esac
    ;;
  env)
    # Manual entry to the framework pre-flight machinery (env-preflight.sh /
    # env-up.sh) — the same section every LLM run gets injected.
    shift
    source "$DIR/config.sh"
    case "${1:-check}" in
      check)
        bash "$DIR/framework/env-preflight.sh" local "${2:-$RAGFLOW_MAIN}"
        ;;
      up)
        bash "$DIR/framework/env-up.sh" local "${2:-$RAGFLOW_MAIN}"
        ;;
      *)
        echo "usage: hfv env [check [worktree] | up [worktree]]" >&2
        exit 1
        ;;
    esac
    ;;
  status)
    systemctl --user status "$UNIT_SVC" --no-pager | head -8
    echo "--- feat:"
    systemctl --user status 'cline-feishu-feat@*.service' --no-pager 2>/dev/null | head -8
    echo "--- pr-follow (state machine):"
    systemctl --user status "$UNIT_PRFOLLOW_SVC" --no-pager | head -4
    echo "--- pr-rebase line:"
    systemctl --user status "$UNIT_REBASE_SVC" --no-pager | head -4
    echo "--- pr-review line:"
    systemctl --user status "$UNIT_REVIEW_SVC" --no-pager | head -4
    echo "--- pr-audit line (we as reviewer):"
    systemctl --user status "$UNIT_AUDIT_SVC" --no-pager | head -4
    echo "--- pr-ci line (CI-failure fix):"
    systemctl --user status "$UNIT_CI_SVC" --no-pager | head -4
    echo "--- model:"
    python3 "$DIR/tools/model-profile.py" show
    echo "--- containers:"
    docker ps -a --format '  {{.Names}}\t{{.Status}}' 2>/dev/null | grep -E 'hfv-(task|svc)-' | head -14
    systemctl --user list-timers --all 'cline-feishu-triage*' --no-pager | head -8
    echo "---"
    systemctl --user list-timers "$UNIT_TIMER" "$UNIT_PRFOLLOW_TIMER" "$UNIT_REBASE_TIMER" "$UNIT_REVIEW_TIMER" "$UNIT_AUDIT_TIMER" "$UNIT_CI_TIMER" --no-pager
    echo "---"
    tail -5 "$LOG_DIR/daemon.log" 2>/dev/null
    ;;
  stats)
    shift
    python3 "$DIR/tools/stats.py" "${1:-24}"
    ;;
  key)
    # Daemon api-key rotation (model-keys.json, gitignored): masked status by
    # default; `hfv key <kimi|glm> <new-key> [--force]` replaces one profile's
    # key (atomic write, 0600 kept). `--stdin` reads the key from stdin so it
    # never lands in the shell history. Interactive cline / VS Code keys are a
    # separate store (~/.cline) and stay untouched.
    shift
    python3 "$DIR/tools/model-profile.py" key "$@"
    ;;
  model)
    shift
    if [[ $# -eq 0 ]]; then
      python3 "$DIR/tools/model-profile.py" show
    elif [[ $# -eq 1 && ( "$1" == "kimi" || "$1" == "glm" ) ]]; then
      if any_active || any_pr_active; then
        if all_active_llm_parked; then
          echo "note: every active run is parked in an LLM rate-limit wait — switching now; parked runs keep retrying with their in-memory model, new runs get '$1'"
        else
          echo "a run is active; model switch refused (config would change mid-run on the issue or PR line). Wait for it to finish or 'hfv stop'."
          exit 1
        fi
      fi
      python3 "$DIR/tools/model-profile.py" apply "$1"
    else
      echo "usage: hfv model [kimi|glm]"; exit 1
    fi
    ;;
  summarize)
    systemctl --user start --no-block "$UNIT_SUMMARIZE_SVC"
    echo "summarize sweep triggered"
    ;;
  prompt)
    # Prompt variants: prompts/<base>.md is the default, prompts/<base>@<v>.md
    # a variant. Selection lives in hfv.conf as PROMPT_VARIANT_<BASE> (uppercase,
    # dashes→underscores); the lines resolve through config.sh's resolve_prompt.
    shift
    subcmd="${1:-list}"; [[ $# -gt 0 ]] && shift
    CONF="$DIR/hfv.conf"
    case "$subcmd" in
      list)
        printf '%-16s %-14s %s\n' PROMPT ACTIVE VARIANTS
        for f in "$DIR"/prompts/*.md; do
          base="$(basename "$f" .md)"
          [[ "$base" == *@* ]] && continue
          vars="$(ls "$DIR/prompts/$base"@*.md 2>/dev/null | sed 's/.*@//; s/\.md$//' | paste -sd, -)"
          key="PROMPT_VARIANT_$(tr 'a-z-' 'A-Z_' <<<"$base")"
          cur="$(grep -oP "^${key}=\K[^#[:space:]]+" "$CONF" 2>/dev/null || true)"
          [[ -n "$cur" && ! -f "$DIR/prompts/$base@$cur.md" ]] && cur=""   # dangling pick → base
          printf '%-16s %-14s %s\n' "$base" "${cur:-base}" "${vars:--}"
        done
        ;;
      show|use)
        arg="${1:-}"
        [[ -n "$arg" ]] || { echo "usage: hfv prompt $subcmd <base>[@variant]"; exit 1; }
        base="${arg%%@*}"; var=""; [[ "$arg" == *@* ]] && var="${arg#*@}"
        key="PROMPT_VARIANT_$(tr 'a-z-' 'A-Z_' <<<"$base")"
        [[ -f "$DIR/prompts/$base.md" ]] || { echo "unknown prompt base: $base (see: hfv prompt list)"; exit 1; }
        if [[ "$subcmd" == show ]]; then
          if [[ -n "$var" ]]; then
            f="$DIR/prompts/$base@$var.md"
          else
            cur="$(grep -oP "^${key}=\K[^#[:space:]]+" "$CONF" 2>/dev/null || true)"
            f="$DIR/prompts/$base.md"
            [[ -n "$cur" && -f "$DIR/prompts/$base@$cur.md" ]] && f="$DIR/prompts/$base@$cur.md"
          fi
          [[ -f "$f" ]] || { echo "no such prompt file: $f"; exit 1; }
          cat "$f"
        else
          if [[ -z "$var" ]]; then
            sed -i "/^${key}=/d" "$CONF"
            echo "$base -> base (默认版本)"
          else
            [[ -f "$DIR/prompts/$base@$var.md" ]] || { echo "no such variant: $base@$var (have: $(ls "$DIR/prompts/$base"@*.md 2>/dev/null | sed 's/.*@//;s/\.md$//' | paste -sd, -))"; exit 1; }
            if grep -q "^${key}=" "$CONF"; then
              sed -i "s|^${key}=.*|${key}=${var}|" "$CONF"
            else
              printf '%s=%s  # 提示词变体（hfv prompt use 写入）\n' "$key" "$var" >> "$CONF"
            fi
            echo "$base -> $var"
          fi
        fi
        ;;
      *)
        echo "usage: hfv prompt [list | show <base>[@v] | use <base>[@v]]" >&2; exit 1 ;;
    esac
    ;;
  help|-h|--help)
    # Paged by default (the full help is 100+ lines); -F drops out immediately
    # when it fits the screen, -X keeps the terminal scrollback, -R passes ANSI
    # through. Not a tty (pipe/redirect) → less behaves like cat.
    usage | less -RFX
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
