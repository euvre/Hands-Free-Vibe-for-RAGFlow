#!/usr/bin/env bash
# issue-gh-shots.sh — upload verification screenshots referenced in a markdown
# file as ](shots/<name>) to the fork repo's fixed `pr-assets` release, and
# rewrite those references to the permanent asset URLs so the images render
# INLINE in the PR body. Pure script, no LLM.
#
#   issue-gh-shots.sh <markdown-file> <shots-dir> <filename-prefix>
#
# The main task stages screenshots into __DELIVER_DIR__/shots/ during the
# verify step and references them from pr-body.md as ![alt](shots/<name>.png);
# the post group runs this right before issue-deliver.sh so the PR is created
# with real URLs. Upload names are <prefix>-<basename> (prefix = task id, so
# assets never collide across PRs; --clobber makes a retried run idempotent).
#
# Exit: 0 = every referenced shot uploaded and rewritten; 1 = at least one
# failure (that reference degrades to plain text — the body never ships a
# dead local path); 2 = usage.
set -u
DIR_HFV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR_HFV/config.sh"

MD="${1:-}"; SHOTS_DIR="${2:-}"; PREFIX="${3:-}"
if [[ ! -f "$MD" || ! -d "$SHOTS_DIR" || -z "$PREFIX" ]]; then
  echo "usage: issue-gh-shots.sh <markdown-file> <shots-dir> <filename-prefix>" >&2
  exit 2
fi
# Prefix becomes part of a public asset filename — keep it URL-safe.
PREFIX="$(tr -cd 'A-Za-z0-9._-' <<<"$PREFIX")"
[[ -n "$PREFIX" ]] || { echo "empty sanitized prefix" >&2; exit 2; }

GH_BIN="${GH_BIN:-gh}"
ASSET_REPO="$FORK_REMOTE/${GITHUB_REPO##*/}"
TAG="pr-assets"

# Referenced names: ](shots/<name>) with a safe basename, in first-seen order.
mapfile -t NAMES < <(grep -oE '\]\(shots/[A-Za-z0-9._-]+\)' "$MD" \
                     | sed 's|^](shots/||; s|)$||' | awk '!seen[$0]++')
if [[ ${#NAMES[@]} -eq 0 ]]; then
  echo "issue-gh-shots: no ](shots/…) reference in $MD — nothing to do"
  exit 0
fi

# Ensure the target release exists (tolerate the create race across slots).
if ! "$GH_BIN" release view "$TAG" --repo "$ASSET_REPO" >/dev/null 2>&1; then
  "$GH_BIN" release create "$TAG" --repo "$ASSET_REPO" --latest=false \
    --title "PR asset attachments" \
    --notes "Automated upload target for PR verification screenshots (issue-gh-shots.sh)." \
    >/dev/null 2>&1 || true
  "$GH_BIN" release view "$TAG" --repo "$ASSET_REPO" >/dev/null 2>&1 || {
    echo "issue-gh-shots: FATAL: cannot view-or-create release $TAG in $ASSET_REPO"
    # degrade every reference to plain text below (fail=1 path)
  }
fi

MAP="$(mktemp)"; TMPD="$(mktemp -d)"; trap 'rm -f "$MAP"; rm -rf "$TMPD"' EXIT
fail=0
for name in "${NAMES[@]}"; do
  f="$SHOTS_DIR/$name"
  asset="$PREFIX-$name"
  url="https://github.com/$ASSET_REPO/releases/download/$TAG/$asset"
  if [[ ! -s "$f" ]]; then
    echo "issue-gh-shots: MISSING file for reference: $f"
    fail=1; continue
  fi
  # Upload a copy already named <prefix>-<name>: the asset takes the uploaded
  # file's basename (the `path#name` rename form is not honored by every gh
  # version — a renamed copy keeps URL and asset name in lockstep).
  cp "$f" "$TMPD/$asset"
  if "$GH_BIN" release upload "$TAG" "$TMPD/$asset" --repo "$ASSET_REPO" \
       --clobber >/dev/null 2>&1; then
    printf '%s\t%s\n' "$name" "$url" >>"$MAP"
    echo "issue-gh-shots: uploaded $name -> $url"
  else
    echo "issue-gh-shots: UPLOAD FAILED for $name — reference will degrade to text"
    fail=1
  fi
done

# Rewrite the markdown in place (atomic): successful uploads become URLs,
# failures become plain-text notes (never a dead local path).
python3 - "$MD" "$MAP" <<'PYEOF'
import re, sys
md_path, map_path = sys.argv[1], sys.argv[2]
urls = {}
for line in open(map_path):
    line = line.rstrip("\n")
    if "\t" in line:
        k, v = line.split("\t", 1)
        urls[k] = v
text = open(md_path).read()

def repl(m):
    alt, name = m.group(1), m.group(2)
    if name in urls:
        return "![%s](%s)" % (alt, urls[name])
    return "**[screenshot upload failed: %s]**" % (alt or name)

out = re.sub(r'!\[([^\]]*)\]\(shots/([A-Za-z0-9._-]+)\)', repl, text)
tmp = md_path + ".tmp"
with open(tmp, "w") as f:
    f.write(out)
import os
os.replace(tmp, md_path)
print("issue-gh-shots: rewrote %d reference(s) in %s" % (len(urls), md_path))
PYEOF

exit $fail
