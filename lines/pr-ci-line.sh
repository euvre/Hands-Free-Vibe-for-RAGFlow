#!/usr/bin/env bash
# pr-ci-line.sh — the CI-FIX line of the PR follow-up (own timer, own lock,
# the MAIN clone's worktree pool in its own wt/ci-<n> namespace — same
# sharing model as the review/rebase/audit lines: different lock, different
# paths, git-side locks serialize the fetches).
#
# Each tick:
#   1. collect (pr-ci-collect.py): our OPEN PRs with FAILING GitHub Actions
#      checks, excluding conflicting PRs (the rebase line's turf), pending
#      runs, and anything inside the per-sha/daily retry budget.
#   2. for every candidate, serially: prepare a dedicated worktree
#      (ragflow main clone's wt/ci-<pr>) → pull the failing job logs into the worktree →
#      run the CI-fix LLM task (pr-ci-task.md, English) → stamp the ledger
#      (win or lose) → clean the worktree.
# Serial inside the line (one LLM at a time protects quota and the shared
# clone); parallel with the REVIEW/REBASE/AUDIT lines (separate clone + lock).
set -u
# Re-exec from a private snapshot so editing this file mid-run cannot corrupt
# the interpreter's byte stream.
if [[ -z "${HFV_EXEC_SNAPSHOT:-}" ]]; then
  HFV_EXEC_SNAPSHOT="$(mktemp /tmp/hfv-exec-snap.XXXXXX.sh)" || exit 1
  cat -- "$0" > "$HFV_EXEC_SNAPSHOT" || exit 1
  export HFV_EXEC_SNAPSHOT
  exec bash "$HFV_EXEC_SNAPSHOT" "$@"
fi
CUR_PR=""
# Kill recovery: a line killed mid-stage (CUR_PR set) drops its status file and
# stops the stage's golden container (its name carries the per-run suffix).
trap 'rm -f "$HFV_EXEC_SNAPSHOT"; if [[ -n "${CUR_PR:-}" && -n "${DIR:-}" ]]; then rm -f "$CUR_FILE"; docker rm -f $(docker ps -q --filter "name=-spr-ci-$CUR_PR") >>"${LOG_DIR:-/dev/null}" 2>&1 || true; fi' EXIT
# Anchor to the daemon home, NOT dirname "$0": after the exec-guard re-exec
# above, $0 IS the /tmp snapshot, so dirname resolves to /tmp.
DIR="$HOME/hands-free-vibe"
LOG_DIR="$DIR/logs"
# Per-instance sharding: N parallel instances of this line (hfv scale
# ci <N>) each own lock pr-ci-<inst>.lock and take the candidates
# where (( (idx-1) % N == INST-1 )). Unnumbered run: INST=1, N=1 = all.
INST="${HFV_INST:-1}"
N_INST=1
[[ -f "$DIR/state/.scale-ci" ]] && N_INST="$(cat "$DIR/state/.scale-ci" 2>/dev/null)"
[[ "$N_INST" =~ ^[0-9]+$ && "$N_INST" -ge 1 ]] || N_INST=1
LOCK_FILE="$DIR/locks/pr-ci-$INST.lock"
CUR_FILE="$DIR/state/.current-ci-$INST"
source "$DIR/config.sh"
CLONE="$RAGFLOW_MAIN"
WTROOT="$CLONE/wt"
TMPL="$(resolve_prompt pr-ci-task)"

mkdir -p "$LOG_DIR"
log() { echo "[$(date +%Y%m%d-%H%M%S)] pr-ci-line: $*" >> "$LOG_DIR/daemon.log"; }

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "lock busy, skipping this tick"
  exit 0
fi

# Manual single-shot (hfv pr ci <N>): exactly one PR, no collect. The
# collector's resolve subcommand verifies the PR is OPEN, non-conflicting and
# has failing actions checks RIGHT NOW (cooldown/budget bypassed).
if [[ "${1:-}" == "--single" ]]; then
  [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "usage: pr-ci-line.sh --single <pr-num>" >&2; exit 2; }
  echo "resolving PR #$2 ..."
  CANDS="$(python3 "$DIR/lines/pr-ci-collect.py" resolve "$2")" \
    || { echo "pr-ci: cannot resolve PR #$2 (see above)"; exit 1; }
  [[ -z "$CANDS" ]] && { echo "pr-ci: PR #$2 has no fixable failing checks right now"; exit 0; }
else
  [[ -x "$CLINE_BIN" && -s "$TMPL" ]] || { log "cline CLI or template missing, skipping"; exit 0; }
  [[ -d "$CLONE/.git" ]] || { log "main clone $CLONE missing, skipping"; exit 0; }
  CANDS="$(python3 "$DIR/lines/pr-ci-collect.py" collect 2>>"$LOG_DIR/daemon.log")"
fi
[[ -z "$CANDS" ]] && exit 0
# Model selection (incl. multi-key quota rotation) is owned by pr-llm-run.sh.
source "$DIR/lines/pr-llm-run.sh"
mkdir -p "$WTROOT"


prepare_worktree() { # <pr-num> <branch> → echoes worktree dir
  local num="$1" branch="$2" wt="$WTROOT/ci-$num"
  # fetch the PR branch first: worktree add from $FORK_REMOTE/<branch> needs the
  # ref present locally (the clone may not have seen this branch yet).
  git -C "$CLONE" fetch -q "$FORK_REMOTE" "$branch" >>"$LOG_DIR/daemon.log" 2>&1 || \
    git -C "$CLONE" fetch -q "$FORK_REMOTE" >>"$LOG_DIR/daemon.log" 2>&1 || true
  if ! git -C "$CLONE" worktree list --porcelain | grep -q "^worktree $wt$"; then
    # Self-heal: an unregistered leftover dir makes `worktree add` fail with
    # "already exists" on every later tick (half-removed worktree residue).
    git -C "$CLONE" worktree prune >>"$LOG_DIR/daemon.log" 2>&1 || true
    [[ -d "$wt" ]] && rm -rf "$wt" >>"$LOG_DIR/daemon.log" 2>&1 || true
    git -C "$CLONE" worktree add --detach "$wt" "$FORK_REMOTE/$branch" >>"$LOG_DIR/daemon.log" 2>&1 \
      || { log "worktree add failed for pr-$num"; return 1; }
    local d
    for d in web/node_modules; do
      [[ -e "$CLONE/$d" && ! -e "$wt/$d" ]] && ln -s "$CLONE/$d" "$wt/$d" 2>/dev/null || true
    done
  fi
  # Tokenizer static lib, in-tree (same rationale as the rebase line: a copied
  # cmake cache is path-pinned; the in-tree build also does the re2 rename).
  if [[ ! -f "$wt/internal/binding/cpp/cmake-build-release/librag_tokenizer_c_api.a" ]]; then
    ( cd "$wt" && bash build.sh --cpp ) >>"$LOG_DIR/daemon.log" 2>&1 \
      || { log "cpp build failed for pr-$num"; return 1; }
  fi
  # deepdoc models are gitignored runtime assets — symlink the clone's copy.
  if [[ ! -e "$wt/rag/res/deepdoc/layout.onnx" && -e "$CLONE/rag/res/deepdoc/layout.onnx" ]]; then
    rm -rf "$wt/rag/res/deepdoc"
    ln -s "$CLONE/rag/res/deepdoc" "$wt/rag/res/deepdoc"
  fi
  echo "$wt"
}

release_worktree() { # <pr-num>
  local wt="$WTROOT/ci-$1"
  git -C "$CLONE" worktree remove --force "$wt" >>"$LOG_DIR/daemon.log" 2>&1 || true
  git -C "$CLONE" worktree prune >>"$LOG_DIR/daemon.log" 2>&1 || true
  [[ -d "$wt" ]] && rm -rf "$wt" >>"$LOG_DIR/daemon.log" 2>&1 || true
}


fetch_failure_logs() { # <pr-num> <worktree> — pull each failing job's log tail
  local num="$1" wt="$2" checks
  mkdir -p "$wt/hfv-ci-failures"
  checks="$(gh pr checks "$num" --repo "$GITHUB_REPO" --json bucket,name,link 2>/dev/null)" || return 0
  printf '%s' "$checks" | python3 -c '
import json, re, sys
try:
    checks = json.load(sys.stdin)
except Exception:
    sys.exit(0)
seen = set()
for c in checks:
    if c.get("bucket") != "fail":
        continue
    m = re.search(r"/job/(\d+)", c.get("link") or "")
    if not m or m.group(1) in seen:
        continue
    seen.add(m.group(1))
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "-", c.get("name") or "check")[:60]
    print(slug + "\t" + m.group(1))
' | while IFS=$'\t' read -r slug jobid; do
    gh api "repos/$GITHUB_REPO/actions/jobs/$jobid/logs" 2>/dev/null \
      | sed -e 's/\x1b\[[0-9;]*m//g' | tail -n 300 \
      > "$wt/hfv-ci-failures/$slug.log" || true
  done
  ls "$wt/hfv-ci-failures/" 2>/dev/null | while read -r f; do
    log "pr=$num: failure log $f ($(wc -l < "$wt/hfv-ci-failures/$f") lines)"
  done
}

# --- rerun-vs-LLM arbitration ---------------------------------------------
# Some CI failures need NO code fix: the runner was cancelled, lost, OOMed,
# or a download/network step flaked. Those need a CI RESTART, not an LLM.
# We hold no actions:write on the upstream repo, so the rerun button is the
# label gate: the CI suite is triggered by the `ci` label, and removing +
# re-adding it retrips the whole workflow (same mechanism deliver uses).
# Conservative bias: anything ambiguous goes to the LLM, not to a rerun.
TRANSIENT_CI_PATTERN='The operation was canceled|action has timed out|lost communication with|self-hosted runner.{0,40}(offline|lost)|exit code 14[37]\b|ECONNRESET|ETIMEDOUT|EAI_AGAIN|socket hang up|TLS handshake timeout|connection reset by peer|error pulling|toomanyrequests|Unable to download|Artifact.{0,40}failed|rate limit exceeded|Bad Gateway|Service Unavailable|Internal Server Error'
SUBSTANTIVE_CI_PATTERN='Format issues found|--- FAIL|\bFAIL:|AssertionError|error TS[0-9]+|compilation error|undefined:|SyntaxError|TypeError|ReferenceError|panic:|exit status [1-9]'
# env-persistent: capacity failures on the self-hosted runners. A rerun MIGHT
# land on a healthier runner, but an LLM can never fix a full disk — so this
# class retries the restart (never the LLM) until the per-sha budget runs out.
ENV_PERSIST_PATTERN='no space left on device|\bENOSPC\b|disk quota exceeded'

classify_failures() { # <worktree> → echoes env | flaky | substantive | unknown
  # env wins outright: a full disk explains ANY other weird failure in the
  # same run, so check it before the substantive patterns.
  local dir="$1/hfv-ci-failures" f any=0
  [[ -d "$dir" ]] || { echo unknown; return; }
  for f in "$dir"/*.log; do
    [[ -e "$f" ]] || { echo unknown; return; }
    [[ -s "$f" ]] || { echo unknown; return; }
    any=1
    grep -qiE "$ENV_PERSIST_PATTERN" "$f" && { echo env; return; }
  done
  [[ "$any" == 1 ]] || { echo unknown; return; }
  for f in "$dir"/*.log; do
    grep -qiE "$SUBSTANTIVE_CI_PATTERN" "$f" && { echo substantive; return; }
    grep -qiE "$TRANSIENT_CI_PATTERN" "$f" || { echo substantive; return; }
  done
  echo flaky
}

rerun_ci() { # <pr-num> — retrip the label-gated CI suite. The remove+add pair
  # is ONE outbox record (gh-outbox label --remove X --add X), so the recorder
  # drains them in order within the same pass — the PR is never left unlabeled.
  local num="$1"
  python3 "$DIR/lines/gh-outbox.py" label --pr "$num" \
    --remove "$PR_LABEL" --add "$PR_LABEL" >>"$LOG_DIR/daemon.log" 2>&1 || return 1
  log "pr=$num: ci label retrip enqueued (recorder drains within a minute)"
}

ledger_entry() { # <pr-num> → "sha<TAB>action" of the last attempt (or empty)
  python3 - "$1" <<'PY'
import json, os, sys
p = os.path.join(os.path.expanduser("~/hands-free-vibe"), "issues", "pr-ci.json")
try:
    ent = json.load(open(p)).get(sys.argv[1]) or {}
except Exception:
    ent = {}
print((ent.get("sha") or "") + "\t" + (ent.get("action") or ""))
PY
}

cand=0
while IFS=$'\t' read -r num branch url mid fails scope; do
  cand=$((cand+1)); (( (cand - 1) % N_INST == INST - 1 )) || continue
  [[ "$num" =~ ^[0-9]+$ ]] || continue
  [[ -n "$fails" ]] || fails="(unknown — run gh pr checks $num)"
  log "ci-fix target pr=$num branch=$branch fails=$fails"
  CUR_PR="$num"; echo "$num" > "$CUR_FILE"
  if [[ "$scope" == external ]]; then
    # External PR (not ours): we cannot push a fix (no push rights), but the
    # ci-label retrip works on any PR via our triage permission — so the
    # arbitration mirrors the own path: env/flaky get a rerun first, and only
    # a substantive failure earns the author a comment (once per head sha).
    ext_dir="$(mktemp -d /tmp/ci-ext-XXXXXX)"
    fetch_failure_logs "$num" "$ext_dir"
    class="$(classify_failures "$ext_dir")"
    rm -rf "$ext_dir"
    head_sha="$(gh pr view "$num" --repo "$GITHUB_REPO" --json headRefOid --jq .headRefOid 2>/dev/null || true)"
    if [[ "$class" == env || "$class" == flaky ]]; then
      # same rerun arbitration as the own path: a rerun that did not help
      # promotes flaky to a comment (env keeps retrying within budget).
      prev="$(ledger_entry "$num")"; prev_sha="${prev%%$'\t'*}"; prev_action="${prev##*$'\t'}"
      if [[ -n "$head_sha" && "$prev_sha" == "$head_sha" && "$prev_action" == rerun && "$class" == flaky ]]; then
        class=substantive
      fi
      if [[ "$class" != substantive ]]; then
        if rerun_ci "$num"; then
          log "pr=$num: external, classified $class — CI retripped via the $PR_LABEL label"
          [[ -n "$head_sha" ]] && python3 "$DIR/lines/pr-ci-collect.py" stamp "$num" "$head_sha" rerun >>"$LOG_DIR/daemon.log" 2>&1 || true
        else
          log "pr=$num: external label retrip failed"
        fi
        CUR_PR=""; rm -f "$CUR_FILE"
        n=$((n + 1))
        continue
      fi
    fi
    if [[ "$class" == substantive ]]; then
      body="$(mktemp)"
      { echo "Hi! Our CI watcher noticed the latest checks on this PR are failing:"
        echo
        printf -- '- `%s`\n' ${fails//,/ }
        echo
        echo "The failure logs do not look like a runner flake, so a plain re-run may not help. Could you take a look? (automated notice — sorry if this was already fixed by a newer push)"
      } > "$body"
      # the comment goes to the outbox (drained within a minute); stamp on
      # enqueue — the recorder owns retries now, re-stamping on gh failure
      # would duplicate the comment across ticks.
      if python3 "$DIR/lines/gh-outbox.py" comment --pr "$num" --body-file "$body" >>"$LOG_DIR/daemon.log" 2>&1; then
        log "pr=$num: external CI failure comment enqueued"
        [[ -n "$head_sha" ]] && python3 "$DIR/lines/pr-ci-collect.py" stamp "$num" "$head_sha" notify >>"$LOG_DIR/daemon.log" 2>&1 || true
      else
        log "pr=$num: external CI failure comment enqueue FAILED — left unstamped (retry next tick)"
      fi
      rm -f "$body"
    else
      log "pr=$num: external CI failure classified as $class — nothing safe to do, skipped"
    fi
    CUR_PR=""; rm -f "$CUR_FILE"
    n=$((n + 1))
    continue
  fi
  wt="$(prepare_worktree "$num" "$branch")" || continue
  fetch_failure_logs "$num" "$wt"
  head_sha="$(git -C "$CLONE" rev-parse "$FORK_REMOTE/$branch" 2>/dev/null || echo "")"
  # --- arbitration: env/flaky failures get a CI restart, not an LLM ---
  prev="$(ledger_entry "$num")"; prev_sha="${prev%%$'\t'*}"; prev_action="${prev##*$'\t'}"
  class="$(classify_failures "$wt")"
  if [[ -n "$head_sha" && "$prev_sha" == "$head_sha" && "$prev_action" == "rerun" ]]; then
    case "$class" in
      env)
        log "pr=$num: env-capacity failure persists after the last rerun — rerunning again (LLM cannot fix runner disks; per-sha budget caps the loop)" ;;
      flaky)
        log "pr=$num: looked flaky but the rerun did not help — promoting to the LLM path"
        class="substantive" ;;
    esac
  fi
  if [[ "$class" == env || "$class" == flaky ]]; then
    log "pr=$num: failing checks ($fails) classified as $class — restarting CI via the $PR_LABEL label, no LLM"
    if rerun_ci "$num"; then
      log "pr=$num: ci label retripped — suite rerunning"
    else
      log "pr=$num: label retrip failed — branch left untouched this round"
    fi
    [[ -n "$head_sha" ]] && python3 "$DIR/lines/pr-ci-collect.py" stamp "$num" "$head_sha" rerun >>"$LOG_DIR/daemon.log" 2>&1 || true
    CUR_PR=""; rm -f "$CUR_FILE"
    release_worktree "$num"
    n=$((n + 1))
    continue
  fi
  log "pr=$num: failing checks ($fails) classified as $class -> LLM fix path"
  # --- zero-LLM mechanical autofix: fires only when EVERY failing check is a
  # known format-only class (oxfmt / whitespace-eof hooks); fix = re-run the
  # same tool without --check on the PR's own diff, verify, push. Anything
  # ambiguous exits 1 untouched and the LLM starts from a clean state.
  if bash "$DIR/framework/pr-ci-autofix.sh" "$num" "$branch" "$wt" >>"$LOG_DIR/daemon.log" 2>&1; then
    log "pr=$num: mechanical failure auto-fixed and pushed — LLM skipped"
    [[ -n "$head_sha" ]] && python3 "$DIR/lines/pr-ci-collect.py" stamp "$num" "$head_sha" autofix >>"$LOG_DIR/daemon.log" 2>&1 || true
    CUR_PR=""; rm -f "$CUR_FILE"
    release_worktree "$num"
    n=$((n + 1))
    continue
  fi
  # __CI_FAILS__ is this line's own placeholder (unknown to run_llm's sed
  # list) — pre-substitute into a per-run copy under tmp/ (the HFV_DIR mount
  # makes it visible inside the container; /tmp is not shared).
  TMPL_CI="$DIR/tmp/pr-ci-task-$num-$(date +%s).md"
  sed -e "s|__CI_FAILS__|$fails|g" "$TMPL" > "$TMPL_CI"
  # The LLM stage runs in one throwaway golden container. --creds: read access
  # to GitHub (check runs / logs) — the push is owned by this line (below).
  LLM_WAIT_FLAG="$DIR/logs/llm-wait/$(basename "$LOCK_FILE" .lock)" \
  HFV_UNLOCK_FLAG="$DIR/state/pr-unlock-ci-$INST.flag" \
  HFV_SLOT="pr-ci-$num" PR_TMPL="$TMPL_CI" PR_TAG="ci" PR_NUM="$num" PR_BRANCH="$branch" PR_URL="$url" PR_MID="$mid" \
  PR_TIMEOUT=1800 PR_PREFLIGHT=0 \
  GH_TOKEN="$(gh auth token 2>/dev/null || true)" \
    bash "$DIR/lines/run-container.sh" --wt "$wt" --creds run-pr-main.sh
  rc=$?
  rm -f "$TMPL_CI"
  # stamps regardless of outcome: cooldown/budget hold even on failure
  [[ -n "$head_sha" ]] && python3 "$DIR/lines/pr-ci-collect.py" stamp "$num" "$head_sha" llm >>"$LOG_DIR/daemon.log" 2>&1 || true
  # The agent only COMMITS (the container carries no credentials); the push is
  # the line's job, enqueued here and drained through the outbox while the
  # worktree is provably alive — an agent-side enqueue seconds before stage
  # end used to lose the race to release_worktree every single time.
  pid="$(line_push_record "$wt" "$branch")"; prc=$?
  case $prc in
    0) wait_outbox_record "$pid" && log "pr=$num: fix pushed to $FORK_REMOTE/$branch" || log "pr=$num: push $pid failed — see gh-recorder.log" ;;
    2) log "pr=$num: no pushable state (no new commits or mid-rebase) — branch unchanged" ;;
    *) : ;;  # enqueue failure already logged by line_push_record
  esac
  CUR_PR=""; rm -f "$CUR_FILE"
  release_worktree "$num"
  n=$((n + 1))
done <<<"$CANDS"
log "ci line done: $n PR(s) this tick"
exit 0
