#!/usr/bin/env bash
# pre-clean-worktree.sh — reset the shared issue-line worktree (ragflow4) to
# a pristine origin/main BEFORE each main run.
#
# Why this exists:
#   * a previous run can leave a STAGED residue / dirty tree / stale fix
#     branch behind; plain `git checkout main` then refuses to overwrite it,
#     the `|| true` swallowed that silently, and the new run started on a
#     stale branch with foreign changes — delivery later exploded
#     ("local changes would be overwritten by checkout") or the residue rode
#     into the PR;
#   * `git pull` never resets the index either.
# Semantics here: snapshot everything recoverable, then hard-reset. Any
# leftover work is preserved in refs/backup/pre-clean-<ts> (newest 20 kept),
# same pattern as issue-deliver.sh's backup refs.
#
# Safety: skipped entirely while a run holds run.lock (an in-flight run owns
# the worktree — yanking it would destroy its fix). git clean is run WITHOUT
# -x, so ignored heavy dirs (.venv, web/node_modules, cpp build artifacts)
# survive.
set -u
HFV_DIR="$HOME/hands-free-vibe"
source "$HFV_DIR/config.sh"
WORKDIR="$RAGFLOW_MAIN"            # config.sh: the slot's own clone when HFV_SLOT is set
LOCK_FILE="$HFV_DIR/run${HFV_SUF}.lock"
LOG_DIR="$HFV_DIR/logs"
TS="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

exec 8>"$LOCK_FILE"
if ! flock -n 8; then
  echo "[$TS] pre-clean: a run is active, skipped" >> "$LOG_DIR/daemon.log"
  exit 0
fi

cd "$WORKDIR" || exit 0
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
dirty=0
[[ -n "$(git status --porcelain 2>/dev/null)" ]] && dirty=1

if [[ "$branch" == "main" && $dirty -eq 0 ]]; then
  git pull -q --ff-only 2>/dev/null || true
  exit 0
fi

# Snapshot the full leftover state (index + worktree + untracked) before
# destroying it, so a dead run's uncommitted fix stays recoverable.
git add -A
TREE=$(git write-tree)
if CMT=$(git commit-tree "$TREE" -p HEAD -m "backup: pre-clean snapshot $TS (branch=$branch dirty=$dirty)"); then
  git update-ref "refs/backup/pre-clean-$TS" "$CMT"
  git for-each-ref --format='%(refname)' 'refs/backup/pre-clean-*' | sort | head -n -20 \
    | while read -r ref; do git update-ref -d "$ref"; done
  log_backup="refs/backup/pre-clean-$TS"
else
  log_backup="(snapshot failed)"
fi

git fetch -q origin main 2>/dev/null || true
git checkout -qf main
git reset -q --hard origin/main
git clean -fdq
echo "[$TS] pre-clean: ragflow4 reset to origin/main (was branch=$branch dirty=$dirty backup=$log_backup)" >> "$LOG_DIR/daemon.log"
exit 0
