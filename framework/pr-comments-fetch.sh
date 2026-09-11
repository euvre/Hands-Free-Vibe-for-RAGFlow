#!/usr/bin/env bash
# pr-comments-fetch.sh — exhaustive, truncation-free comment inventory for one PR.
#
# Turns "I saw every comment" from an LLM judgment call into a
# mechanical guarantee:
#   * all three channels fetched with --paginate (issue comments, reviews,
#     inline review comments);
#   * fetched counts reconciled against the PR's own totals (comments /
#     review_comments); a short or unverifiable channel aborts with rc=1;
#   * stdout carries a complete one-line-per-comment INDEX (never cut) plus
#     the FULL bodies of every human (non-bot, non-own) comment;
#   * bot/own bodies are never thrown away either — they live in the JSONL
#     snapshot file referenced on stdout (read selectively by id).
#
# Usage:  pr-comments-fetch.sh <owner/repo> <pr-number>
# Exit:   0 = complete reconciled snapshot; 1 = partial/failed fetch (treat
#         as fatal: never process comments from a partial view); 2 = usage.
set -u
DIR_HFV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"  # repo root (framework/)
source "$DIR_HFV/config.sh"

REPO_ARG="${1:-}"
NUM_ARG="${2:-}"
if [[ "$REPO_ARG" != */* || ! "$NUM_ARG" =~ ^[0-9]+$ ]]; then
  echo "usage: pr-comments-fetch.sh <owner/repo> <pr-number>" >&2
  exit 2
fi

SNAP="$DIR_HFV/tmp/pr-comments-$NUM_ARG-$(date +%Y%m%d-%H%M%S).jsonl"
ERRF="$DIR_HFV/logs/pr-comments-fetch-$NUM_ARG.err"
mkdir -p "$DIR_HFV/tmp" "$DIR_HFV/logs"
: > "$SNAP"
: > "$ERRF"

fetch_channel() { # <api-path> <jq-filter>: JSONL lines into $SNAP, count on stdout
  local path="$1" jqf="$2" line n=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '%s\n' "$line" >> "$SNAP"
    n=$((n + 1))
  done < <(gh api --paginate "repos/$REPO_ARG/$path" --jq "$jqf" 2>>"$ERRF")
  echo "$n"
}

N_ISSUE="$(fetch_channel "issues/$NUM_ARG/comments" \
  '.[] | {channel:"issue", id:.id, author:(.user.login // "?"), created_at:.created_at, body:(.body // "")}')"
N_REVIEW="$(fetch_channel "pulls/$NUM_ARG/reviews" \
  '.[] | {channel:"review", id:.id, author:(.user.login // "?"), state:(.state // ""), created_at:.submitted_at, body:(.body // "")}')"
N_INLINE="$(fetch_channel "pulls/$NUM_ARG/comments" \
  '.[] | {channel:"inline", id:.id, author:(.user.login // "?"), created_at:.created_at, path:(.path // ""), line:(.line // .original_line), body:(.body // "")}')"

TOTALS="$(gh api "repos/$REPO_ARG/pulls/$NUM_ARG" \
  --jq '{comments:.comments, review_comments:.review_comments}' 2>>"$ERRF")"
T_COMMENTS=-1; T_RC=-1
if [[ -n "$TOTALS" ]]; then
  T_COMMENTS="$(jq -r '.comments // -1' <<<"$TOTALS" 2>>"$ERRF")"
  T_RC="$(jq -r '.review_comments // -1' <<<"$TOTALS" 2>>"$ERRF")"
fi
[[ "$T_COMMENTS" =~ ^[0-9]+$ ]] || T_COMMENTS=-1
[[ "$T_RC" =~ ^[0-9]+$ ]] || T_RC=-1
echo "=== pr-comments-fetch repo=$REPO_ARG pr=$NUM_ARG $(date -Is) ==="
echo "fetched:  issue=$N_ISSUE review=$N_REVIEW inline=$N_INLINE"
echo "pr says:  comments=$T_COMMENTS review_comments=$T_RC"

fatal=0
if (( T_COMMENTS < 0 || T_RC < 0 )); then
  echo "FATAL: PR totals unavailable (gh/api failure) — cannot reconcile completeness"
  fatal=1
elif (( N_ISSUE < T_COMMENTS || N_INLINE < T_RC )); then
  echo "FATAL: partial fetch (issue=$N_ISSUE vs comments=$T_COMMENTS, inline=$N_INLINE vs review_comments=$T_RC) — comment data INCOMPLETE"
  fatal=1
fi
if (( fatal )); then
  tail -n 5 "$ERRF" | sed 's/^/  gh: /'
  echo "snapshot kept for debugging: $SNAP"
  exit 1
fi
if (( N_ISSUE > T_COMMENTS || N_INLINE > T_RC )); then
  echo "note: fetched exceeds totals (recent deletions / API skew) — continuing; fetched counts above are authoritative"
fi
echo "reconciliation: OK — comment channels complete (review objects have no PR-level total; --paginate guarantees that channel)"
echo "snapshot (full JSONL, untruncated): $SNAP"
echo "single-body lookup: jq -r 'select(.id==<id>) | .body' $SNAP"

JQ_INDEX='def isbot: ((.author // "") | ascii_downcase) as $a | ((["github-actions","codecov","renovate","dependabot","copilot-pull-request-reviewer","coderabbitai","claude"] | index($a)) != null) or ($a | endswith("bot")) or ($a | endswith("[bot]"));
(if isbot then "BOT" elif ((.author // "") | ascii_downcase) == ($own | ascii_downcase) then "OWN" else "HUMAN" end) as $kind
| "[\(.channel)] id=\(.id) author=\(.author) at=\(.created_at)"
  + (if .channel == "review" then " state=\(.state)" else "" end)
  + (if .channel == "inline" then " path=\(.path):L\(.line)" else "" end)
  + " kind=\($kind) len=\((.body // "") | length)"
  + " preview=\((.body // "") | gsub("\\s+"; " ") | if length > 160 then .[0:160] + "..." else . end)"'

JQ_HUMAN='def isbot: ((.author // "") | ascii_downcase) as $a | ((["github-actions","codecov","renovate","dependabot","copilot-pull-request-reviewer","coderabbitai","claude"] | index($a)) != null) or ($a | endswith("bot")) or ($a | endswith("[bot]"));
select((((.author // "") | ascii_downcase) != ($own | ascii_downcase)) and (isbot | not))
| "--- [\(.channel)] id=\(.id) author=\(.author) at=\(.created_at)"
  + (if .channel == "review" then " state=\(.state)" else "" end)
  + (if .channel == "inline" then " path=\(.path):L\(.line)" else "" end)
  + " ---\n\(.body // "")\n--- end id=\(.id) ---"'

echo
echo "=== INDEX — one line per comment, COMPLETE (never truncated) ==="
jq -r --arg own "$OWN_LOGIN" "$JQ_INDEX" "$SNAP"

echo
echo "=== HUMAN bodies (non-bot, non-own) — FULL text, never truncated ==="
jq -r --arg own "$OWN_LOGIN" "$JQ_HUMAN" "$SNAP"
echo "=== end (BOT/OWN bodies: read from the snapshot file above, by id) ==="

# housekeeping: keep only the newest 200 snapshots
ls -1t "$DIR_HFV/tmp"/pr-comments-*.jsonl 2>/dev/null | tail -n +201 | xargs -r rm -f
exit 0
