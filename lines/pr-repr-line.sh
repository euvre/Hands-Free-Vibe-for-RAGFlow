#!/usr/bin/env bash
# pr-repr-line.sh — manual RE-RUN of an existing PR's original task, with the
# full golden-container stack the original run often lacked (2026-09-18: PR
# 19554 shipped with "live end-to-end verification was not possible" in its
# description). The re-run re-verifies the requirement FOR REAL, fixes what
# fails, then the line owns the push + report comment, same as the review line.
#
# Manual only (hfv pr repr <pr>); no timer, no collect — the user names the
# PR. One PR per invocation, own lock (pr-repr.lock), own worktree namespace
# wt/repr-<n> on the shared clone. Serial with itself only; the per-PR guard
# refuses when another line is actively working the same PR.
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
trap 'rm -f "$HFV_EXEC_SNAPSHOT"; if [[ -n "${CUR_PR:-}" && -n "${DIR:-}" ]]; then rm -f "$CUR_FILE"; docker rm -f $(docker ps -q --filter "name=-spr-repr-$CUR_PR") >>"${LOG_DIR:-/dev/null}" 2>&1 || true; fi' EXIT
# Anchor to the daemon home, NOT dirname "$0" (see the exec-guard note above).
DIR="$HOME/hands-free-vibe"
LOG_DIR="$DIR/logs"
source "$DIR/config.sh"
CLONE="$RAGFLOW_MAIN"
WTROOT="$CLONE/wt"
LOCK_FILE="$DIR/pr-repr.lock"
CUR_FILE="$DIR/.current-repr"
TMPL="$(resolve_prompt pr-repr-task)"

mkdir -p "$LOG_DIR" "$WTROOT" "$DIR/scratch"
log() { echo "[$(date +%Y%m%d-%H%M%S)] pr-repr-line: $*" >> "$LOG_DIR/daemon.log"; }

[[ "${1:-}" == "--single" && "${2:-}" =~ ^[0-9]+$ ]] || {
  echo "usage: pr-repr-line.sh --single <pr-num>" >&2; exit 1; }
num="$2"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "lock busy, skipping"; echo "pr-repr line busy" >&2; exit 1
fi
[[ -x "$CLINE_BIN" && -s "$TMPL" ]] || { log "cline CLI or template missing"; exit 1; }
# Model selection (incl. multi-key quota rotation) is owned by pr-llm-run.sh.
source "$DIR/lines/pr-llm-run.sh"

# --- live PR state (never trust the local store for this) -------------------
ov="$(gh pr view "$num" --repo "$GITHUB_REPO" --json state,headRefName,url 2>/dev/null)" \
  || { log "pr=$num: gh pr view failed"; exit 1; }
state="$(printf '%s' "$ov" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')"
branch="$(printf '%s' "$ov" | python3 -c 'import json,sys; print(json.load(sys.stdin)["headRefName"])')"
url="$(printf '%s' "$ov" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')"
if [[ "$state" != "OPEN" ]]; then
  log "pr=$num: state=$state — re-run only makes sense on an OPEN PR"; exit 1
fi

# --- per-PR guard: another line actively on this PR? ------------------------
for f in "$DIR"/.current-review-* "$DIR"/.current-ci-* "$DIR"/.current-rebase-* "$DIR"/.current-audit-*; do
  [[ -e "$f" ]] || continue
  if [[ "$(cat "$f" 2>/dev/null)" == "$num" ]]; then
    log "pr=$num: $(basename "$f") holds this PR — refuse to run concurrently"
    echo "pr=$num is being worked by another line ($(basename "$f")) — retry when it finishes" >&2
    exit 1
  fi
done

# --- origin task material from the local issue list (issues/issues.jsonl) ---
origin="$DIR/scratch/pr-repr-$num-origin.md"
python3 - "$num" "$DIR" > "$origin" <<'PYEOF'
import ast, json, os, sys

num, base = sys.argv[1], sys.argv[2]
store = os.path.join(base, "issues", "issues.jsonl")
rec = None
for line in open(store):
    try:
        r = json.loads(line)
    except Exception:
        continue
    if str(r.get("pr") or "").rstrip("/").endswith("/pull/" + num):
        rec = r
print("# Origin task material for PR re-run\n")
if rec is None:
    print("(no local issue record found for this PR — reconstruct the "
          "requirement from the PR description)\n")
    sys.exit(0)
print("- source: Feishu message `%s`" % rec.get("message_id", "?"))
print("- filed: %s" % rec.get("text_full") or rec.get("text") or "")
imgs = rec.get("images") or "[]"
if isinstance(imgs, str):
    try:
        imgs = ast.literal_eval(imgs)
    except Exception:
        imgs = []
for p in imgs:
    print("- attachment: %s" % os.path.join(base, "issues", p))
PYEOF
mid="$(python3 - "$num" "$DIR" <<'PYMID'
import json, sys
num, base = sys.argv[1], sys.argv[2]
for line in open(base + "/issues/issues.jsonl"):
    try:
        r = json.loads(line)
    except Exception:
        continue
    if str(r.get("pr") or "").rstrip("/").endswith("/pull/" + num):
        print(r.get("message_id") or "")
        break
PYMID
)"

prepare_worktree() { # → echoes worktree dir
  local wt="$WTROOT/repr-$num"
  git -C "$CLONE" fetch -q "$FORK_REMOTE" "$branch" >>"$LOG_DIR/daemon.log" 2>&1 || \
    git -C "$CLONE" fetch -q "$FORK_REMOTE" >>"$LOG_DIR/daemon.log" 2>&1 || true
  if ! git -C "$CLONE" worktree list --porcelain | grep -q "^worktree $wt$"; then
    git -C "$CLONE" worktree prune >>"$LOG_DIR/daemon.log" 2>&1 || true
    [[ -d "$wt" ]] && rm -rf "$wt" >>"$LOG_DIR/daemon.log" 2>&1 || true
    git -C "$CLONE" worktree add --detach "$wt" "$FORK_REMOTE/$branch" >>"$LOG_DIR/daemon.log" 2>&1 \
      || { log "worktree add failed for pr-$num"; return 1; }
    # NOTE: no .venv symlink — the e2e group builds the venv in-container
    # (glibc-matched; a host-built venv ImportErrors there).
    [[ -e "$CLONE/web/node_modules" && ! -e "$wt/web/node_modules" ]] && \
      ln -s "$CLONE/web/node_modules" "$wt/web/node_modules" 2>/dev/null || true
  fi
  # Pre-step (host, once): the in-container Go server needs the tokenizer .a;
  # re-runs build_cpp, and a copied cmake-build-release carries the clone's
  # absolute paths in CMakeCache.txt (cmake refuses to reuse it), so the old
  # cp-prebuilt shortcut broke every e2e bring-up (PR#19221 audit rounds 2-3).
  if [[ ! -f "$wt/internal/binding/cpp/cmake-build-release/librag_tokenizer_c_api.a" ]]; then
    ( cd "$wt" && bash build.sh --cpp ) >>"$LOG_DIR/daemon.log" 2>&1 \
      || { log "cpp build failed for pr-$num"; return 1; }
  fi
  # deepdoc models are gitignored runtime assets: the Go server's in-process
  # DeepDoc backend fails fast without them — symlink the clone's copy.
  if [[ ! -e "$wt/rag/res/deepdoc/layout.onnx" && -e "$CLONE/rag/res/deepdoc/layout.onnx" ]]; then
    rm -rf "$wt/rag/res/deepdoc"
    ln -s "$CLONE/rag/res/deepdoc" "$wt/rag/res/deepdoc"
  fi
  echo "$wt"
}

release_worktree() {
  local wt="$WTROOT/repr-$num"
  git -C "$CLONE" worktree remove --force "$wt" >>"$LOG_DIR/daemon.log" 2>&1 || true
  git -C "$CLONE" worktree prune >>"$LOG_DIR/daemon.log" 2>&1 || true
  [[ -d "$wt" ]] && rm -rf "$wt" >>"$LOG_DIR/daemon.log" 2>&1 || true
}

# --- run --------------------------------------------------------------------
log "pr=$num branch=$branch re-run started (origin: $origin)"
CUR_PR="$num"; echo "$num" > "$CUR_FILE"
wt="$(prepare_worktree)" || { CUR_PR=""; rm -f "$CUR_FILE"; exit 1; }
rm -f "$DIR/scratch/pr-repr-$num-report.md"   # no stale report from a crashed round
# The LLM stage runs in one throwaway golden container off the frozen base —
# with env-up pre-flight ON (the whole point: the original run lacked the
# stack). --creds: read access to GitHub (PR/issue lookup); pushes/comments
# are owned by this line below.
LLM_WAIT_FLAG="$DIR/logs/llm-wait/$(basename "$LOCK_FILE" .lock)" \
HFV_SLOT="pr-repr-$num" PR_TMPL="$TMPL" PR_TAG="repr" PR_NUM="$num" PR_BRANCH="$branch" PR_URL="$url" PR_MID="${mid:-}" \
PR_TIMEOUT=5400 \
GH_TOKEN="$(gh auth token 2>/dev/null || true)" \
  bash "$DIR/lines/run-container.sh" --wt "$wt" --creds run-pr-main.sh
rc=$?
log "pr=$num re-run stage exit=$rc log=$(ls -t "$LOG_DIR"/run-pr-repr-*.log 2>/dev/null | head -1)"

# --- post-stage: the line owns the push + the report comment ----------------
pid=""; prc=2
if [[ $rc -eq 0 || $rc -eq 124 ]]; then
  pid="$(line_push_record "$wt" "$branch")"; prc=$?
  if [[ $prc -eq 0 ]]; then
    wait_outbox_record "$pid" && log "pr=$num: fixes pushed to $FORK_REMOTE/$branch" || log "pr=$num: push $pid failed — see gh-recorder.log"
  elif [[ $prc -eq 2 ]]; then
    log "pr=$num: no pushable state — branch unchanged (verification-only round)"
  fi
else
  log "pr=$num: stage failed (rc=$rc) — nothing pushed, report still posted if written"
fi
report="$DIR/scratch/pr-repr-$num-report.md"
if [[ -s "$report" ]]; then
  if [[ $prc -eq 0 && -n "$pid" ]]; then
    python3 "$DIR/lines/gh-outbox.py" comment --pr "$num" --body-file "$report" --after "$pid" >>"$LOG_DIR/daemon.log" 2>&1 \
      && log "pr=$num: re-run report enqueued (after push $pid)" || log "pr=$num: report enqueue FAILED"
  else
    python3 "$DIR/lines/gh-outbox.py" comment --pr "$num" --body-file "$report" >>"$LOG_DIR/daemon.log" 2>&1 \
      && log "pr=$num: re-run report enqueued (no push this round)" || log "pr=$num: report enqueue FAILED"
  fi
  rm -f "$report"
else
  log "pr=$num: no report file — nothing to post"
fi
rm -f "$origin"
CUR_PR=""; rm -f "$CUR_FILE"
release_worktree
