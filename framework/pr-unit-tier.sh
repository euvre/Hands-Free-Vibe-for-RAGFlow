#!/usr/bin/env bash
# pr-unit-tier.sh — pre-run the unit/static tier for a PR worktree BEFORE the
# LLM starts. The `build.sh --test` / `npm run type-check` / `ruff` results
# are deterministic, so the framework runs them once and injects them.
#
# usage: pr-unit-tier.sh <worktree> [base-ref]
# stdout: a markdown section for prompt injection ("### Unit tier ...").
# Exit 0 always — advisory only; a tier that cannot run says SKIP, never blocks.
#
# Tier mapping (narrow by design — full runs are CI's job):
#   **/*.go                 → bash build.sh --test ./<dir>/... per touched dir
#   web/**                  → npm run type-check (project-wide) + oxlint touched
#   **/*.py                 → uv run ruff check <touched>
#   anything else           → listed as unmapped (skipped)
set -u
DIR="$HOME/hands-free-vibe"
source "$DIR/config.sh"
WT="${1:-}"
BASE="${2:-origin/main}"

[[ -n "$WT" && -d "$WT" ]] || { echo "- unit-tier: worktree missing — skipped"; exit 0; }
mb="$(git -C "$WT" merge-base HEAD "$BASE" 2>/dev/null || true)"
[[ -n "$mb" ]] || { echo "- unit-tier: no merge-base with $BASE — skipped"; exit 0; }
mapfile -t files < <(git -C "$WT" diff --name-only "$mb" HEAD 2>/dev/null)
((${#files[@]})) || { echo "- unit-tier: empty diff vs $BASE — skipped"; exit 0; }

web_files=(); go_dirs=(); py_files=(); unmapped=()
declare -A seen_dir=()
for f in "${files[@]}"; do
  case "$f" in
    web/*) web_files+=("${f#web/}") ;;
    *.go)  d="$(dirname "$f")"; if [[ -z "${seen_dir[$d]:-}" ]]; then seen_dir[$d]=1; go_dirs+=("$d"); fi ;;
    *.py)  py_files+=("$f") ;;
    *)     unmapped+=("$f") ;;
  esac
done

echo "### Unit tier (pre-run by the framework — do NOT rerun green tiers; FAIL lines are your work)"
echo

run_tier() { # <label> <timeout-s> <workdir> <cmd...> — PASS/FAIL/TIMEOUT + tail
  local label="$1" tmo="$2" wd="$3"; shift 3
  local out rc
  out="$(cd "$wd" && timeout "$tmo" "$@" 2>&1)"; rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "- PASS \`$label\`"
  elif [[ $rc -eq 124 ]]; then
    echo "- TIMEOUT \`$label\` (${tmo}s) — inconclusive; rerun it yourself only if your findings depend on it"
  elif grep -qiE 'native lib.{0,40}(mismatch|missing)|cannot find -l|ld:.*not found' <<<"$out"; then
    # Environment, NOT the PR: a native-lib pin/ABI breakage reds every package
    # alike. Never let the agent chase it as a code regression; the env
    # pre-flight's office-oxide-version check carries the fix.
    echo "- ENV-FAIL \`$label\` — environment, not the PR: $(grep -ioE 'native lib[^.]*|cannot find -l[^ ]*' <<<"$out" | head -1 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n') — see the env pre-flight for the fix"
  else
    echo "- FAIL \`$label\` (rc=$rc) — last lines:"
    echo '  ```'
    tail -15 <<<"$out" | sed 's/^/  /'
    echo '  ```'
  fi
}

# Go tier — one build.sh --test per touched package dir (never bare go test).
if ((${#go_dirs[@]})); then
  if [[ ! -f "$WT/internal/binding/cpp/cmake-build-release/librag_tokenizer_c_api.a" ]]; then
    echo "- SKIP \`go test\` — tokenizer static lib missing in this worktree (the env pre-flight already WARNs); if you need this tier, \`bash build.sh --cpp\` first"
  else
    for d in "${go_dirs[@]}"; do
      run_tier "go test ./$d/..." 240 "$WT" bash build.sh --test "./$d/..."
    done
  fi
fi

# web tier — type-check is project-wide; oxlint only the touched files.
if ((${#web_files[@]})); then
  if [[ -e "$WT/web/node_modules/.bin/oxlint" ]]; then
    run_tier "npm run type-check" 300 "$WT/web" npm run type-check
    run_tier "oxlint (touched files)" 90 "$WT/web" ./node_modules/.bin/oxlint "${web_files[@]}"
  else
    echo "- SKIP web tier — web/node_modules unusable (env pre-flight WARNs)"
  fi
fi

# python tier — ruff on the touched files (project venv via uv).
if ((${#py_files[@]})); then
  run_tier "ruff check (touched files)" 90 "$WT" uv run ruff check "${py_files[@]}"
fi

if ((${#unmapped[@]})); then
  printf -- '- No tier mapping (skipped): `%s`\n' "$(printf '%s`, `' "${unmapped[@]}")" | sed 's/`, `$//'
fi
exit 0
