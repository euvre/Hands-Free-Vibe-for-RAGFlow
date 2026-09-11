#!/usr/bin/env bash
# pr-ci-autofix.sh — zero-LLM mechanical CI fixes, run by pr-ci-line.sh after
# classify_failures says "substantive" and BEFORE spending an LLM session.
#
# Fires ONLY when EVERY failing-check log is a known-mechanical class; anything
# else exits 1 untouched and the LLM path starts from a clean state.
#
# Mechanical classes (the fix IS re-running the same tool without --check):
#   * oxfmt — "Format issues found" / web-oxfmt / ragflow_preflight(oxfmt)
#   * pre-commit whitespace hooks: trailing-whitespace-fixer, end-of-file-fixer,
#     mixed-line-ending
#
# File scope: the PR's own diff (merge-base..HEAD) — NEVER repo-wide (the task
# file's minimal-diff rule applies to robots too). Verify with the same
# commands CI runs, one conventional style: commit, plain push; a push race
# gets ONE fetch+rebase+re-verify+push retry, then it's the LLM's problem.
#
# usage: pr-ci-autofix.sh <pr-num> <branch> <worktree>
# exit 0 = fixed + pushed (caller skips the LLM); 1 = hand over untouched state
set -u
DIR="$HOME/hands-free-vibe"
source "$DIR/config.sh"
NUM="${1:-}"; BRANCH="${2:-}"; WT="${3:-}"
LOGD="$WT/hfv-ci-failures"

[[ -d "$LOGD" && -d "$WT" ]] || exit 1
shopt -s nullglob
logs=("$LOGD"/*.log)
((${#logs[@]})) || exit 1

# Evidence of a REAL failure in any log → not mechanical, hand over.
HARD_FAIL='error TS[0-9]+|--- FAIL|\bFAIL:|AssertionError|panic:|SyntaxError|compilation error|undefined:|ModuleNotFoundError|ImportError'
# Mechanical-class markers; every log must show at least one.
MECH='oxfmt|Format issues found|Trim Trailing Whitespace|trailing.whitespace|Fix End of Files|end.of.files|[Mm]ixed line ending'

for f in "${logs[@]}"; do
  [[ -s "$f" ]] || exit 1                    # empty log = unknown → LLM
  grep -qiE "$HARD_FAIL" "$f" && exit 1
  grep -qiE "$MECH" "$f" || exit 1
done
# pre-commit logs: every FAILED hook id must be whitelisted (check-yaml etc.
# are NOT mechanical — a broken yaml needs a human/LLM eye).
for f in "${logs[@]}"; do
  grep -qi 'hook id' "$f" || continue
  while read -r h; do
    [[ -n "$h" ]] || continue
    case "$h" in
      trailing-whitespace-fixer|trailing-whitespace|end-of-file-fixer|mixed-line-ending) ;;
      *) exit 1 ;;
    esac
  done < <(grep -B1 -A2 'Failed' "$f" 2>/dev/null | sed -n 's/^.*- hook id: //p' | sort -u)
done

mb="$(git -C "$WT" merge-base HEAD origin/main 2>/dev/null || true)"
[[ -n "$mb" ]] || exit 1
mapfile -t touched < <(git -C "$WT" diff --name-only "$mb" HEAD 2>/dev/null)
((${#touched[@]})) || exit 1

fixed=()

# --- oxfmt class -------------------------------------------------------------
web_touched=()
for f in "${touched[@]}"; do [[ "$f" == web/* && -f "$WT/$f" ]] && web_touched+=("${f#web/}"); done
if grep -qiE 'oxfmt|Format issues found' "${logs[@]}"; then
  ((${#web_touched[@]})) || exit 1     # oxfmt failure but no touched web files — odd, LLM
  ( cd "$WT/web" && ./node_modules/.bin/oxfmt "${web_touched[@]}" ) >/dev/null 2>&1 || exit 1
  ( cd "$WT/web" && ./node_modules/.bin/oxfmt --check "${web_touched[@]}" ) >/dev/null 2>&1 || exit 1
  fixed+=("oxfmt(${#web_touched[@]})")
fi

# --- whitespace/eof class ------------------------------------------------------
if grep -qiE 'Trim Trailing Whitespace|trailing.whitespace|Fix End of Files|end.of.files|[Mm]ixed line ending' "${logs[@]}"; then
  for f in "${touched[@]}"; do
    [[ -f "$WT/$f" ]] || continue
    grep -Iq . "$WT/$f" 2>/dev/null || continue   # skip binaries
    sed -i 's/[ \t]*$//' "$WT/$f"
    python3 - "$WT/$f" <<'PY'
import sys
p = sys.argv[1]
b = open(p, 'rb').read()
if not b: sys.exit(0)
b2 = b.rstrip(b'\n') + b'\n'
if b2 != b: open(p, 'wb').write(b2)
PY
  done
  # verify: no touched text file carries trailing whitespace any more
  for f in "${touched[@]}"; do
    [[ -f "$WT/$f" ]] || continue
    grep -Iq . "$WT/$f" 2>/dev/null || continue
    grep -qE '[ \t]+$' "$WT/$f" && exit 1
  done
  fixed+=("whitespace-eof")
fi

((${#fixed[@]})) || exit 1
git -C "$WT" diff --quiet && exit 1   # the tools changed nothing — the real problem is elsewhere

msg="style: auto-fix CI formatting ($(IFS=+; echo "${fixed[*]}"))"
git -C "$WT" add -A >/dev/null 2>&1 || exit 1
git -C "$WT" commit -q -m "$msg" >/dev/null 2>&1 || exit 1

push_fix() { git -C "$WT" push "$FORK_REMOTE" "HEAD:$BRANCH" >/dev/null 2>&1; }
if ! push_fix; then
  # push race: someone moved the fork branch — one rebase + quick re-verify + retry
  git -C "$WT" fetch "$FORK_REMOTE" "$BRANCH" >/dev/null 2>&1 || exit 1
  git -C "$WT" rebase "$FORK_REMOTE/$BRANCH" >/dev/null 2>&1 || exit 1
  if ((${#web_touched[@]})); then
    ( cd "$WT/web" && ./node_modules/.bin/oxfmt --check "${web_touched[@]}" ) >/dev/null 2>&1 || exit 1
  fi
  push_fix || exit 1
fi
echo "pr#$NUM: mechanical CI failure auto-fixed and pushed ($msg) — LLM skipped"
exit 0
