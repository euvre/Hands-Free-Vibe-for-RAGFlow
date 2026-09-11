#!/usr/bin/env bash
# pr-rebase-auto.sh — the mechanical half of the rebase line, run BEFORE the
# LLM: leftover cleanup → fetches → checkout -B → `git rebase origin/main`
# attempt. A FULLY CLEAN rebase replayed zero conflicts, i.e. the PR's
# semantics were untouched: gate on the unit tier and push --force-with-lease
# right away — no LLM at all. Conflicts stay LLM work (semantic merge): the
# rebase is left IN PROGRESS and the conflict map is handed over below.
#
# usage: pr-rebase-auto.sh <pr-num> <branch> <worktree>
# stdout: markdown handover section (the caller injects it into the LLM prompt
#         whenever the exit code is nonzero).
# exit 0 = clean rebase verified + pushed — LLM skipped entirely
#      1 = hand over to the LLM (conflicts in progress, or clean-but-unpushed)
#      2 = infra failure — worktree untouched; LLM runs the full legacy flow
set -u
DIR="$HOME/hands-free-vibe"
source "$DIR/config.sh"
NUM="${1:-}"; BRANCH="${2:-}"; WT="${3:-}"

hdr() { echo "## Framework pre-flight — rebase auto-attempt (mechanical half already done)"; echo; }

if [[ -z "$NUM" || -z "$BRANCH" || ! -d "$WT" ]]; then
  hdr; echo "- auto attempt failed: bad args/worktree — run the full §2 flow yourself."
  exit 2
fi

git -C "$WT" rebase --abort >/dev/null 2>&1 || true
git -C "$WT" merge  --abort >/dev/null 2>&1 || true
if ! git -C "$WT" fetch origin main >/dev/null 2>&1 \
|| ! git -C "$WT" fetch "$FORK_REMOTE" "$BRANCH" >/dev/null 2>&1; then
  hdr; echo "- auto attempt failed at fetch (infra) — run the full §2 flow yourself."
  exit 2
fi
if ! git -C "$WT" checkout -q -B "$BRANCH" "$FORK_REMOTE/$BRANCH" 2>/dev/null; then
  hdr; echo "- auto attempt failed at checkout — run the full §2 flow yourself."
  exit 2
fi

if git -C "$WT" rebase origin/main >/dev/null 2>&1; then
  # CLEAN replay. Zero conflicts = semantics untouched → unit tier is the
  # sufficient gate (e2e was the PR's own merge-time concern, not rebase's).
  tier="$(bash "$DIR/framework/pr-unit-tier.sh" "$WT" origin/main 2>/dev/null || true)"
  if grep -q '^- FAIL' <<<"$tier"; then
    hdr
    echo "- **State: rebase COMPLETED but NOT pushed** — the replay was clean (zero conflicts), yet the pre-run unit tier has FAILURES (likely pre-existing on the PR; judging that is your step-6 call):"
    echo
    sed 's/^/  /' <<<"$tier"
    echo
    echo "- Continue from step 6 (verify → judge pre-existing vs yours → push \`--force-with-lease\`). Do NOT redo steps 1-4."
    exit 1
  fi
  if git -C "$WT" push --force-with-lease "$FORK_REMOTE" "HEAD:$BRANCH" >/dev/null 2>&1; then
    # no LLM this round; the caller stamps + reports exactly like an LLM success
    hdr
    echo "- clean rebase auto-pushed (unit tier green) — this section should never reach an LLM."
    exit 0
  fi
  hdr
  echo "- **State: rebase COMPLETED, push REFUSED** — \`--force-with-lease\` says $FORK_REMOTE/$BRANCH moved meanwhile (someone else pushed). Per §3: NEVER force twice; describe the situation in the summary and end."
  exit 2
fi

# Conflicts — leave the rebase in progress and hand over the map.
hdr
echo "- **State: rebase IN PROGRESS** — sync/fetch/checkout/rebase-attempt already done by the framework. Start DIRECTLY at step 5 (resolve); do NOT abort and restart, this state IS your starting point."
echo
echo "  Conflicted paths:"
git -C "$WT" status --short 2>/dev/null | grep -E '^(UU|AA|DD|AU|UA|DU|UD)' | sed 's/^/  - /' || true
echo
echo "  Replaying commit: \`$(git -C "$WT" log -1 --format=%s REBASE_HEAD 2>/dev/null || echo '?')\`"
exit 1
