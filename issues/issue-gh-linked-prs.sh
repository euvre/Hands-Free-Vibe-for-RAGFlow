#!/usr/bin/env bash
# issue-gh-linked-prs.sh <issue-number> — merged-PR linkage check for one
# GitHub issue (source=github records, message_id gh-<number>).
#
# Why: an open bug issue may already have a MERGED PR linked to it — a GitHub
# closing reference ("Fixes #N"), a timeline cross-reference, or a comment
# claiming "already fixed in PR #X". The main task MUST know that BEFORE
# reproducing (see task-templates/github.md.tmpl):
#   * problem no longer reproduces → reply "already fixed by merged PR #X"
#     with evidence and stop (no new PR);
#   * problem STILL reproduces  → the reply states that first (the earlier
#     fix was insufficient), then the fix proceeds.
#
# Three collection channels (all read-only gh calls, host-side auth):
#   1. GraphQL closedByPullRequestsReferences — GitHub's authoritative
#      "closing" links (PRs whose merge would close this issue);
#   2. REST timeline cross-referenced events whose source is a PR in THIS
#      repo (filtered by html_url — a same-numbered PR in another repo is
#      not a link to here);
#   3. /pull/<n> URLs mentioned in the issue body or ANY comment — the
#      "someone claims a fix" channel (e.g. gh#18754's comment pointing at
#      merged PR #18560 never shows up in channels 1/2).
# Every candidate PR number is then resolved via gh pr view for its live
# state, so a closed-unmerged or still-open PR is never misread as merged.
#
# Output: one line per linked PR (state, channels, url, title), then a
# RESULT line. Any fetch failure prints FATAL and exits 1 — the caller
# reruns once; a partial view is never authoritative.
#
# Usage: issue-gh-linked-prs.sh <issue-number>
# Exit:  0 = complete inventory (RESULT line authoritative);
#        1 = partial/failed fetch; 2 = usage.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_BIN="${GH_BIN:-gh}"

N="${1:-}"
if [[ ! "$N" =~ ^[0-9]+$ ]]; then
  echo "usage: issue-gh-linked-prs.sh <issue-number>" >&2
  exit 2
fi

# Repo from the issue-source config (same file the recorder/reply read).
REPO=""
if [[ -f "$DIR/config" ]]; then
  REPO="$(grep -E '^GITHUB_ISSUE_REPO=' "$DIR/config" | head -1 | cut -d= -f2-)"
  REPO="${REPO%$'\r'}"; REPO="${REPO%\"}"; REPO="${REPO#\"}"
fi
REPO="${REPO:-infiniflow/ragflow}"
OWNER="${REPO%%/*}"
NAME="${REPO#*/}"

CAND="$(mktemp)"   # lines: <channel>\t<pr-number>
trap 'rm -f "$CAND"' EXIT
fatal=0
note_fail() { # <detail>: mark the inventory incomplete
  echo "FATAL: $1" | tr '\n' ' ' | cut -c1-300; echo
  fatal=1
}

# --- channel 1: GraphQL closing references ---------------------------------
GQL='query($owner:String!,$name:String!,$n:Int!){
  repository(owner:$owner,name:$name){
    issue(number:$n){
      closedByPullRequestsReferences(first:30, includeClosedPrs:true){
        nodes{ number }
      }
    }
  }
}'
ch1="$("$GH_BIN" api graphql -f owner="$OWNER" -f name="$NAME" -F n="$N" \
       -f query="$GQL" \
       --jq '.data.repository.issue.closedByPullRequestsReferences.nodes[].number' 2>&1)"
if [[ $? -ne 0 ]]; then
  note_fail "closing-refs(GraphQL) fetch failed: $ch1"
else
  while IFS= read -r pr; do
    [[ "$pr" =~ ^[0-9]+$ ]] && printf 'closing\t%s\n' "$pr" >>"$CAND"
  done <<<"$ch1"
fi

# --- channel 2: timeline cross-references whose source is a PR here --------
ch2="$("$GH_BIN" api "repos/$REPO/issues/$N/timeline" --paginate \
       --jq '[.[] | select(.event=="cross-referenced")
              | select(.source.issue.pull_request != null)
              | select((.source.issue.html_url // "") | contains("/'"$REPO"'/pull/"))
              | .source.issue.number] | unique | .[]' 2>&1)"
if [[ $? -ne 0 ]]; then
  note_fail "timeline(REST) fetch failed: $ch2"
else
  while IFS= read -r pr; do
    [[ "$pr" =~ ^[0-9]+$ ]] && printf 'timeline\t%s\n' "$pr" >>"$CAND"
  done <<<"$ch2"
fi

# --- channel 3: /pull/<n> links in the issue body or any comment -----------
ch3="$("$GH_BIN" issue view "$N" --repo "$REPO" --json body,comments \
       --jq '([.body // ""] + [.comments[]?.body // ""]) | join("\n")' 2>&1)"
if [[ $? -ne 0 ]]; then
  note_fail "issue-view(body/comments) fetch failed: ${ch3:0:200}"
else
  while IFS= read -r pr; do
    [[ "$pr" =~ ^[0-9]+$ ]] && printf 'comment\t%s\n' "$pr" >>"$CAND"
  done < <(printf '%s' "$ch3" | grep -oE "github\.com/${REPO}/pull/[0-9]+" \
           | grep -oE '[0-9]+$' | sort -un)
fi

echo "=== issue-gh-linked-prs repo=$REPO issue=$N $(date -Is) ==="
n1="$(awk -F'\t' '$1=="closing"'  "$CAND" | sort -u | wc -l)"
n2="$(awk -F'\t' '$1=="timeline"' "$CAND" | sort -u | wc -l)"
n3="$(awk -F'\t' '$1=="comment"'  "$CAND" | sort -u | wc -l)"
echo "candidates by channel: closing=$n1 timeline=$n2 comment-links=$n3"

prs="$(awk -F'\t' '{print $2}' "$CAND" | sort -un)"
merged_list=""
if [[ -n "$prs" ]]; then
  echo "--- linked PRs (live state via gh pr view) ---"
  while IFS= read -r pr; do
    [[ -n "$pr" ]] || continue
    info="$("$GH_BIN" pr view "$pr" --repo "$REPO" \
            --json number,title,state,mergedAt,url \
            --jq '"\(.number)\t\(.state)\t\(.mergedAt // "-")\t\(.url)\t\(((.title // "") | gsub("\\s+"; " "))[0:100])"' 2>&1)"
    if [[ $? -ne 0 ]]; then
      note_fail "pr-view #$pr failed: ${info:0:160}"
      continue
    fi
    pnum="$(cut -f1 <<<"$info")"; pstate="$(cut -f2 <<<"$info")"
    pmerged="$(cut -f3 <<<"$info")"; purl="$(cut -f4 <<<"$info")"
    ptitle="$(cut -f5- <<<"$info")"
    chans="$(awk -F'\t' -v p="$pr" '$2==p{print $1}' "$CAND" | sort -u | paste -sd+ -)"
    if [[ "$pstate" == "MERGED" ]]; then
      echo "PR #$pnum [MERGED ${pmerged:0:10}] (via $chans) $purl — $ptitle"
      merged_list="${merged_list:+$merged_list, }#$pnum"
    else
      echo "PR #$pnum [$pstate] (via $chans) $purl — $ptitle"
    fi
  done <<<"$prs"
else
  echo "--- linked PRs: none found in any channel ---"
fi

if (( fatal )); then
  echo "RESULT: INCOMPLETE — a fetch failed; rerun once. Never decide from this partial view."
  exit 1
fi
if [[ -n "$merged_list" ]]; then
  echo "RESULT: merged_linked_prs=$merged_list"
else
  echo "RESULT: merged_linked_prs=none"
fi
echo "=== end ==="
exit 0
