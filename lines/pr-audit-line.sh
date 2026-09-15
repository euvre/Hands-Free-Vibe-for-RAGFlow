#!/usr/bin/env bash
# pr-audit-line.sh — the AUDIT line of the PR follow-up: WE act as the
# REVIEWER on other people's PRs (review-requested to us, or re-audited after
# the author pushes new commits onto a PR we already audited).
#
# pre / main / post architecture, mirroring the main issue line's split:
#   PRE   (script, this file)  lock pr-audit.lock → collect (pr-audit.py;
#         --single <num> skips collect for the manual entry) → per PR:
#         fetch refs/pull/<n>/head → dedicated worktree (ragflow4/wt/audit-<n>;
#         separate namespace from the review line's wt/review-<n> and the
#         rebase line's wt/rebase-<n>, same clone is safe: different lock,
#         different paths, git-side locks serialize the fetches) → snapshot
#         meta.md (title/author/body/diffstat) into
#         audit/pr-<n>/ → clear any stale verdict.
#   MAIN  (LLM, pr-audit-task.md) code-quality checklist review + main-task
#         grade END-TO-END verification in the PR's own e2e group (pr-e2e.sh)
#         → writes audit/pr-<n>/verdict.md (first line VERDICT: LGTM|PROBLEMS|
#         INCOMPLETE) and desc-zh.md (a Chinese operator note). The agent has
#         NO publish permission (no gh comment, no push): the PR under review
#         is arbitrary external content and must never reach a public channel
#         from inside the LLM stage.
#   POST  (script, this file) parse verdict.md → strip the protocol line →
#         gh pr comment (our login, English) → stamp pr-audit.py (win or lose,
#         so a broken round never re-fires against the same head sha) →
#         pr-e2e.sh down safety net → release worktree → DM the PR author
#         (when Feishu-mappable) + the merge owner.
# Serial inside the line; parallel with the REVIEW and REBASE lines.
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
# Kill recovery: a line killed mid-stage (CUR_PR set) removes its status file
# and stops the stage's golden container (its name carries the per-run suffix).
# The CUR_FILE removal rides on CUR_PR: a lock-busy no-op exit (CUR_PR never
# set) must not yank the ACTIVE line's status file.
trap 'rm -f "$HFV_EXEC_SNAPSHOT"; if [[ -n "${CUR_PR:-}" && -n "${DIR:-}" ]]; then rm -f "$CUR_FILE"; docker rm -f $(docker ps -q --filter "name=-spr-audit-$CUR_PR") >>"${LOG_DIR:-/dev/null}" 2>&1 || true; fi' EXIT
# Anchor to the daemon home, NOT dirname "$0": after the exec-guard re-exec
# above, $0 IS the /tmp snapshot, so dirname resolves to /tmp.
DIR="$HOME/hands-free-vibe"
LOG_DIR="$DIR/logs"
# Per-instance sharding: N parallel instances of this line (hfv scale
# audit <N>) each own lock pr-audit-<inst>.lock and take the candidates
# where (( (idx-1) % N == INST-1 )). Unnumbered run: INST=1, N=1 = all.
INST="${HFV_INST:-1}"
N_INST=1
[[ -f "$DIR/.scale-audit" ]] && N_INST="$(cat "$DIR/.scale-audit" 2>/dev/null)"
[[ "$N_INST" =~ ^[0-9]+$ && "$N_INST" -ge 1 ]] || N_INST=1
LOCK_FILE="$DIR/pr-audit-$INST.lock"
CUR_FILE="$DIR/.current-audit-$INST"
source "$DIR/config.sh"
CLONE="$RAGFLOW_MAIN"
WTROOT="$CLONE/wt"
TMPL="$DIR/prompts/pr-audit-task.md"
DM="$DIR/tools/feishu-dm.py"
AUDIT_ROOT="$DIR/audit"

mkdir -p "$LOG_DIR" "$WTROOT" "$AUDIT_ROOT"
log() { echo "[$(date +%Y%m%d-%H%M%S)] pr-audit-line: $*" >> "$LOG_DIR/daemon.log"; }

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "lock busy, skipping this tick"
  exit 0
fi

# Manual entry (hfv pr audit <N>): exactly one PR, no collect. sha/url stay
# empty here — the PRE stage fills them from gh.
SINGLE_NUM=""
if [[ "${1:-}" == "--single" ]]; then
  SINGLE_NUM="${2:-}"
  [[ "$SINGLE_NUM" =~ ^[0-9]+$ ]] || { echo "usage: pr-audit-line.sh --single <pr-num>" >&2; exit 2; }
  CANDS="$(printf '%s\t\t\n' "$SINGLE_NUM")"
else
  [[ -x "$CLINE_BIN" && -s "$TMPL" ]] || { log "cline CLI or template missing, skipping"; exit 0; }
  CANDS="$(python3 "$DIR/lines/pr-audit.py" collect 2>>"$LOG_DIR/daemon.log")"
fi
[[ -z "$CANDS" ]] && exit 0
# Model selection (incl. multi-key quota rotation) is owned by pr-llm-run.sh.
source "$DIR/lines/pr-llm-run.sh"

# ---------------- PRE stage (script) ----------------

write_meta() { # <num> <wt> <sha> <branch> — PR snapshot for the LLM's first read
  local num="$1" wt="$2" sha="$3" branch="$4" ad="$AUDIT_ROOT/pr-$num"
  local full title author body base adds dels files base_sha nstat more
  # gh-recorder pre-scans every tracked PR into gh-store — a fresh snapshot
  # (< 15 min) makes this a local file read; gh is only the cold fallback.
  full="$(python3 - "$num" <<'EOF'
import json, os, sys, time
p = os.path.join(os.environ["HOME"], "hands-free-vibe/lines/gh-store/pr-%d.json" % int(sys.argv[1]))
try:
    d = json.load(open(p))
    fresh = (time.time() * 1000 - d.get("fetched_at", 0)) < 15 * 60 * 1000
except Exception:
    fresh = False
if fresh:
    print(json.dumps({
        "title": d.get("title") or "", "author": {"login": d.get("author") or "?"},
        "body": d.get("body") or "", "additions": d.get("additions"),
        "deletions": d.get("deletions"), "changedFiles": d.get("changed_files"),
        "baseRefName": d.get("base_ref") or ""}))
EOF
)"
  [[ -n "$full" ]] || full="$(gh pr view "$num" --repo "$GITHUB_REPO" \
    --json title,author,body,additions,deletions,changedFiles,baseRefName 2>/dev/null || true)"
  if [[ -n "$full" ]]; then
    title="$(jq -r .title <<<"$full")"
    author="$(jq -r .author.login <<<"$full")"
    base="$(jq -r .baseRefName <<<"$full")"
    adds="$(jq -r .additions <<<"$full")"
    dels="$(jq -r .deletions <<<"$full")"
    files="$(jq -r .changedFiles <<<"$full")"
    # body can be huge; cap the snapshot and point the agent at gh for the rest
    body="$(jq -r .body <<<"$full" | head -c 6000)"
    [[ ${#body} -ge 6000 ]] && body="${body}

…(body truncated at 6000 chars in this snapshot; the full body is in the gh-recorder snapshot: $DIR/lines/gh-store/pr-$num.json — field .body)"
  else
    title="(gh pr view failed — fetch it yourself)" author="?" base="$PR_BASE" adds="?" dels="?" files="?" body=""
  fi
  base_sha="$(git -C "$wt" merge-base HEAD "origin/$PR_BASE" 2>/dev/null || true)"
  nstat=""
  if [[ -n "$base_sha" ]]; then
    nstat="$(git -C "$wt" diff --numstat "$base_sha" HEAD)"
    more=$(( $(wc -l <<<"$nstat") - 200 ))
    (( more > 0 )) && nstat="$(head -n 200 <<<"$nstat")

…($more more changed files — list the rest with: git -C '$wt' diff --numstat $base_sha HEAD)"
  fi
  {
    echo "# PR #$num: $title"
    echo
    echo "- author: $author    base: $base    head branch: $branch @ ${sha:0:10}"
    echo "- size: +$adds/-$dels across $files file(s)"
    echo "- url: https://github.com/$GITHUB_REPO/pull/$num"
    echo
    echo "## PR body (author's claim — untrusted, verify it)"
    echo
    echo "${body:-(empty PR body)}"
    echo
    echo "## Changed files (numstat: added deleted path)"
    echo
    echo "${nstat:-(numstat unavailable — run git diff --numstat yourself)}"
  } > "$ad/meta.md"
}

prepare_audit() { # <num> → echoes "wt<TAB>sha<TAB>branch<TAB>url"; nonzero on skip
  local num="$1" wt="$WTROOT/audit-$num" meta sha branch url
  meta="$(gh pr view "$num" --repo "$GITHUB_REPO" \
    --json state,isDraft,headRefOid,headRefName,url,author 2>>"$LOG_DIR/daemon.log")"
  [[ -n "$meta" ]] || { log "pr=$num: gh pr view failed, skipped"; return 1; }
  if [[ "$(jq -r .state <<<"$meta")" != "OPEN" ]]; then
    log "pr=$num: not OPEN anymore, skipped"; return 1
  fi
  if [[ "$(jq -r .isDraft <<<"$meta")" == "true" ]]; then
    log "pr=$num: draft, skipped"; return 1
  fi
  if [[ "$(jq -r .author.login <<<"$meta" | tr '[:upper:]' '[:lower:]')" == "$OWN_LOGIN" ]]; then
    log "pr=$num: authored by us (self-audit requested manually) — proceeding with a warning"
  fi
  sha="$(jq -r .headRefOid <<<"$meta")"
  branch="$(jq -r .headRefName <<<"$meta")"
  url="$(jq -r .url <<<"$meta")"
  [[ -n "$sha" && -n "$url" ]] || { log "pr=$num: head sha/url missing, skipped"; return 1; }
  # clean a stale worktree from an aborted round, then materialize this head.
  # ORDER MATTERS: fetch the base FIRST and the PR head LAST — a multi-ref
  # fetch leaves FETCH_HEAD pointing at the FIRST ref. Keeping the PR ref
  # alone in the final fetch makes FETCH_HEAD unambiguous.
  git -C "$CLONE" worktree remove --force "$wt" >>"$LOG_DIR/daemon.log" 2>&1 || true
  # Self-heal: a half-removed worktree leaves an unregistered dir that makes
  # `worktree add` fail with "already exists" on every later tick.
  git -C "$CLONE" worktree prune >>"$LOG_DIR/daemon.log" 2>&1 || true
  [[ -d "$wt" ]] && rm -rf "$wt" >>"$LOG_DIR/daemon.log" 2>&1 || true
  git -C "$CLONE" fetch -q origin "$PR_BASE" >>"$LOG_DIR/daemon.log" 2>&1 || true
  git -C "$CLONE" fetch -q origin "refs/pull/$num/head" >>"$LOG_DIR/daemon.log" 2>&1 \
    || { log "pr=$num: fetch refs/pull/$num/head failed"; return 1; }
  git -C "$CLONE" worktree add --detach "$wt" FETCH_HEAD >>"$LOG_DIR/daemon.log" 2>&1 \
    || { log "pr=$num: worktree add failed"; return 1; }
  local d
  # NOTE: no .venv symlink — the e2e group builds the venv in-container
  # (glibc-matched; a host-built venv ImportErrors there).
  for d in web/node_modules; do
    [[ -e "$CLONE/$d" && ! -e "$wt/$d" ]] && ln -s "$CLONE/$d" "$wt/$d" 2>/dev/null || true
  done
  # Build the tokenizer static lib IN the worktree: upstream --run always
  # re-runs build_cpp, and a copied cmake-build-release carries the clone's
  # absolute paths in CMakeCache.txt (cmake refuses to reuse it), so the old
  # cp-prebuilt shortcut broke every e2e bring-up (PR#19221 audit rounds 2-3).
  # A fresh in-tree build also performs the ragtokre2_ rename itself.
  if [[ ! -f "$wt/internal/binding/cpp/cmake-build-release/librag_tokenizer_c_api.a" ]]; then
    ( cd "$wt" && bash build.sh --cpp ) >>"$LOG_DIR/daemon.log" 2>&1 \
      || { log "pr=$num: cpp build failed"; return 1; }
  fi
  # deepdoc models are gitignored runtime assets: the Go server's in-process
  # DeepDoc backend fails fast without them — symlink the clone's copy.
  if [[ ! -e "$wt/rag/res/deepdoc/layout.onnx" && -e "$CLONE/rag/res/deepdoc/layout.onnx" ]]; then
    rm -rf "$wt/rag/res/deepdoc"
    ln -s "$CLONE/rag/res/deepdoc" "$wt/rag/res/deepdoc"
  fi
  # fresh round: drop any stale verdict, snapshot the PR for the LLM
  mkdir -p "$AUDIT_ROOT/pr-$num"
  rm -f "$AUDIT_ROOT/pr-$num/verdict.md"
  write_meta "$num" "$wt" "$sha" "$branch"
  printf '%s\t%s\t%s\t%s\n' "$wt" "$sha" "$branch" "$url"
}

# ---------------- POST stage (script) ----------------

DESC_DIR="$AUDIT_ROOT/descriptions"
collect_desc() { # <num> — hand the Chinese operator note to the descriptions folder
  local num="$1" src="$AUDIT_ROOT/pr-$num/desc-zh.md"
  [[ -s "$src" ]] || return 0
  mkdir -p "$DESC_DIR"
  mv "$src" "$DESC_DIR/pr-$num.md" \
    && log "pr=$num: operator note -> $DESC_DIR/pr-$num.md"
}

dm_notify() { # <num> <verdict> — DM the PR author (if Feishu-mappable) + the merge owner
  local num="$1" verdict="$2" author url text
  author="$(gh pr view "$num" --repo "$GITHUB_REPO" --json author --jq .author.login 2>/dev/null || true)"
  url="https://github.com/$GITHUB_REPO/pull/$num"
  case "$verdict" in
    LGTM)       text="已完成对 PR #$num 的评审：LGTM，已回复。$url" ;;
    PROBLEMS)   text="已完成对 PR #$num 的评审，已回复发现的问题。$url" ;;
    INCOMPLETE) text="已完成对 PR #$num 的评审（部分验证受限），已回复。$url" ;;
    *)          text="PR #$num 的自动评审未产出结论/未发布，请人工跟进。$url" ;;
  esac
  if [[ -n "$author" && "$author" != "$MERGE_OWNER_LOGIN" ]]; then
    python3 "$DM" dm "$author" "$text" >>"$LOG_DIR/daemon.log" 2>&1 || true
  fi
  python3 "$DM" dm-owner "$text" >>"$LOG_DIR/daemon.log" 2>&1 || true
}

publish_verdict() { # <num> <sha>
  local num="$1" sha="$2" vf="$AUDIT_ROOT/pr-$num/verdict.md" verdict body_file
  # Dry-run (HFV_AUDIT_DRY_RUN=1, manual testing): the verdict and the operator
  # note still land in the audit dir, but nothing is published, labeled,
  # stamped or DM'd — the PR stays eligible for a real round.
  if [[ -n "${HFV_AUDIT_DRY_RUN:-}" ]]; then
    log "pr=$num: dry-run — nothing published (verdict line: $(head -n1 "$vf" 2>/dev/null || echo '<no verdict file>'))"
    return
  fi
  if [[ ! -s "$vf" ]]; then
    log "pr=$num: no verdict file — nothing published, stamped no-verdict"
    python3 "$DIR/lines/pr-audit.py" stamp "$num" "$sha" no-verdict >>"$LOG_DIR/daemon.log" 2>&1 || true
    dm_notify "$num" no-verdict
    return
  fi
  verdict="$(head -n1 "$vf" | sed -n 's/^VERDICT: \(LGTM\|PROBLEMS\|INCOMPLETE\)[[:space:]]*$/\1/p')"
  if [[ -z "$verdict" ]]; then
    log "pr=$num: verdict file has no protocol first line — nothing published, stamped no-verdict"
    python3 "$DIR/lines/pr-audit.py" stamp "$num" "$sha" no-verdict >>"$LOG_DIR/daemon.log" 2>&1 || true
    dm_notify "$num" no-verdict
    return
  fi
  body_file="$(mktemp)"
  tail -n +2 "$vf" | sed '/./,$!d' > "$body_file"   # strip protocol line + leading blanks
  if [[ ! -s "$body_file" ]]; then
    case "$verdict" in
      LGTM) echo "LGTM 🚀 — reviewed and verified end to end by the audit bot." > "$body_file" ;;
      *)    echo "(audit verdict: $verdict; detail body was empty)" > "$body_file" ;;
    esac
  fi
  # GitHub writes go to the outbox — gh-recorder (1-min timer) drains them.
  # Local enqueue is practically infallible, so the verdict stamps as published
  # immediately; the recorder retries with backoff until the comment lands.
  if python3 "$DIR/lines/gh-outbox.py" comment --pr "$num" --body-file "$body_file" >>"$LOG_DIR/daemon.log" 2>&1; then
    log "pr=$num: audit reply enqueued (verdict=$verdict)"
    # LGTM = the audit gate passed: label it like an issue-line delivery
    # (same label PR_LABEL).
    if [[ "$verdict" == "LGTM" ]]; then
      python3 "$DIR/lines/gh-outbox.py" label --pr "$num" --add "$PR_LABEL" >>"$LOG_DIR/daemon.log" 2>&1 || true
    fi
    python3 "$DIR/lines/pr-audit.py" stamp "$num" "$sha" "$verdict" >>"$LOG_DIR/daemon.log" 2>&1 || true
    dm_notify "$num" "$verdict"
  else
    # enqueue failed (local fs): stamp unpublished so the tick does not loop
    # on the same sha — a human follows up via the DM.
    log "pr=$num: outbox enqueue FAILED (verdict=$verdict) — stamped unpublished"
    python3 "$DIR/lines/pr-audit.py" stamp "$num" "$sha" "unpublished-$verdict" >>"$LOG_DIR/daemon.log" 2>&1 || true
    dm_notify "$num" unpublished
  fi
  rm -f "$body_file"
}

# ---------------- main loop: PRE → MAIN → POST, per PR ----------------

cand=0
while IFS=$'\t' read -r num sha url; do
  cand=$((cand+1)); (( (cand - 1) % N_INST == INST - 1 )) || continue
  [[ "$num" =~ ^[0-9]+$ ]] || continue
  log "audit target pr=$num"
  CUR_PR="$num"; echo "$num" > "$CUR_FILE"
  pre="$(prepare_audit "$num")" || { CUR_PR=""; rm -f "$CUR_FILE"; continue; }
  IFS=$'\t' read -r wt rsha branch rurl <<<"$pre"
  [[ -n "$sha" ]] || sha="$rsha"     # auto mode already knows the sha; manual learns it here
  [[ -n "$url" ]] || url="$rurl"
  # The LLM stage runs in one throwaway golden container (frozen base: model
  # providers baked in, services in-container; nothing flows back). --creds
  # gives read access to GitHub (comment inventory); the publish prohibition
  # stays a prompt-level rule exactly as it was on the host. The container does
  # its own pre-flight (env-up local) + unit-tier pre-run and injects the
  # status section itself. HFV_SLOT namespaces its per-run files.
  HFV_SLOT="pr-audit-$num" PR_TMPL="pr-audit-task.md" PR_TAG="audit" PR_NUM="$num" PR_BRANCH="$branch" PR_URL="$url" \
  GH_TOKEN="$(gh auth token 2>/dev/null || true)" \
    bash "$DIR/lines/run-container.sh" --wt "$wt" --creds run-pr-main.sh
  publish_verdict "$num" "$sha"
  collect_desc "$num"
  CUR_PR=""; rm -f "$CUR_FILE"
  git -C "$CLONE" worktree remove --force "$wt" >>"$LOG_DIR/daemon.log" 2>&1 || true
  git -C "$CLONE" worktree prune >>"$LOG_DIR/daemon.log" 2>&1 || true
  [[ -d "$wt" ]] && rm -rf "$wt" >>"$LOG_DIR/daemon.log" 2>&1 || true
  n=$((n + 1))
done <<<"$CANDS"
log "audit line done: $n PR(s) this tick"
exit 0
