#!/usr/bin/env bash
# run-pr-main.sh — the PR lines' LLM stage inside one throwaway golden
# container, invoked via run-container.sh --wt <line worktree> (the worktree is
# line-managed, mounted at its host path, and RAGFLOW_MAIN points at it).
#
# Env (passed through by run-container.sh):
#   PR_TMPL     prompt file under prompts/ (e.g. pr-audit-task.md)
#   PR_TAG      stage tag (audit / review / rebase / ci) — log naming
#   PR_NUM      PR number
#   PR_BRANCH   PR head branch on the fork     PR_URL   PR url
#   PR_MID      issue/message id when the stage is tied to one (usually empty)
#   PR_TIMEOUT  hard cap seconds (default 3600)
#   PR_PREFLIGHT  0 skips env-up + unit tier (rebase/ci: the agent may still
#                 launch services itself inside its own container)
#   PR_PRE_SECTION  caller-rendered markdown prepended to the injected status
#                 section (e.g. the rebase line's auto-attempt handover)
#
# The app services run INSIDE this container (the golden stack + env-up local
# mode), same as the issue line: no per-PR compose group is involved. The
# golden image's tenant carries the model providers — key-based verification
# works here and nowhere else.
set -u
DIR="$HOME/hands-free-vibe"
source "$DIR/config.sh"
LOG_DIR="$DIR/logs"
: "${PR_TMPL:?missing PR_TMPL}" "${PR_TAG:?missing PR_TAG}" "${PR_NUM:?missing PR_NUM}"
case "$PR_TMPL" in /*) TMPL="$PR_TMPL" ;; *) TMPL="$DIR/prompts/$PR_TMPL" ;; esac

ENV_STATUS_SECTION="${PR_PRE_SECTION:-}"
if [[ "${PR_PREFLIGHT:-1}" == 1 ]]; then
  # Framework pre-flight inside this container: service stack + app to READY
  # (or an honest NOT-READY section), then the unit/static tier pre-run. The
  # caller's HFV_SLOT=pr-<tag>-<num> namespaces the status file per run.
  bash "$DIR/framework/env-up.sh" local "$RAGFLOW_MAIN" >"$LOG_DIR/env-up-pr-$PR_TAG$PR_NUM.log" 2>&1 || true
  pre="$(cat "$LOG_DIR/env-status$HFV_SUF.md" 2>/dev/null || true)"
  tier="$(bash "$DIR/framework/pr-unit-tier.sh" "$RAGFLOW_MAIN" "origin/$PR_BASE" 2>/dev/null || true)"
  [[ -n "$pre" ]] && ENV_STATUS_SECTION="$ENV_STATUS_SECTION

$pre"
  [[ -n "$tier" ]] && ENV_STATUS_SECTION="$ENV_STATUS_SECTION

$tier"
fi
export ENV_STATUS_SECTION

source "$DIR/lines/pr-llm-run.sh"
run_llm "$TMPL" "${PR_TIMEOUT:-3600}" "$PR_TAG" "$RAGFLOW_MAIN" "$PR_NUM" "${PR_BRANCH:-}" "${PR_URL:-}" "${PR_MID:-}" < /dev/null
