#!/usr/bin/env bash
# cline-feishu summarize sweep: for each finished-but-unsummarized MAIN/FEAT
# run log (newest first, at most 2 per sweep), condense it mechanically, ask
# cline for ≤LESSONS_PER_TASK reusable rules, store them as a tree LEAF, then
# run summarize-tree.py — the tournament engine that stride-groups leaves,
# merges upward (hash-cached), maintains the hit-rate/affinity stats table,
# solidifies golden rules and fuses high-affinity pairs.
set -u

DAEMON_DIR="$HOME/hands-free-vibe"
LOG_DIR="$DAEMON_DIR/logs"
STAMP_DIR="$LOG_DIR/.summarized"
source "$DAEMON_DIR/config.sh"
LEAVES_DIR="$DAEMON_DIR/summarize/leaves"

# Explicit model override: the summarizer runs the SAME model profile as the
# main task (derived from .model-profile), immune to providers.json drift.
# Multi-key aware (same store as run-task.sh): summarize has no per-log retry
# machinery, so it simply uses the first key of the current profile.
MODEL_BASE="$(python3 "$DAEMON_DIR/tools/model-profile.py" args-base)" || exit 1
mapfile -t API_KEYS < <(python3 "$DAEMON_DIR/tools/model-profile.py" keylist) || exit 1
((${#API_KEYS[@]})) || exit 1

mkdir -p "$STAMP_DIR" "$LEAVES_DIR"

# one summarizer at a time
exec 8>"$LOG_DIR/.summarize.lock"
flock -n 8 || exit 0

# new summarize task: reclaim MCP servers leaked by finished runs
bash "$DAEMON_DIR/framework/mcp-cleanup.sh"

count=0
# newest first: recent runs carry the most relevant lessons
for LOG in $(ls -1t "$LOG_DIR"/run-2*.log 2>/dev/null); do
  name="$(basename "$LOG" .log)"
  [ -f "$STAMP_DIR/$name.done" ] && continue
  grep -q '=== run finished' "$LOG" || continue
  count=$((count + 1))
  [ $count -gt 2 ] && break

  digest="$(python3 "$DAEMON_DIR/lines/summarize-digest.py" "$LOG" 2>/dev/null)"
  if [ -z "$digest" ]; then
    : > "$STAMP_DIR/$name.done"
    continue
  fi

  SUM_LOG="$LOG_DIR/summarize-$name.log"
  timeout "$SUMMARIZE_SECONDS" "$CLINE_BIN" \
    --json \
    --cwd "$DAEMON_DIR" \
    -t "$SUMMARIZE_SECONDS" \
    --auto-approve true \
    $MODEL_BASE -k "${API_KEYS[0]}" \
    "$(printf '%s\n\n# digest\n%s' "$(cat "$DAEMON_DIR/prompts/summarize-task.md")" "$digest")" \
    > "$SUM_LOG" 2>&1
  rc=$?

  # extract final text (done event; fallback: concatenated text content)
  out="$(python3 - "$SUM_LOG" <<'PYEOF'
import json, sys
done = ""
texts = []
for line in open(sys.argv[1]):
    if not line.startswith("{"):
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    ev = d.get("event", {})
    if ev.get("type") == "done":
        done = ev.get("text") or ""
    elif ev.get("type") == "content_start" and ev.get("contentType") == "text":
        texts.append(ev.get("text", ""))
print(done or "".join(texts))
PYEOF
)"

  # keep plausible rule lines only, cap count and length → tree leaf file
  tid="$(grep -oE 'task #[0-9]+' "$LOG" | head -1 | grep -oE '[0-9]+' || true)"
  key="task-${tid:-$name}"
  printf '%s\n' "$out" | sed 's/\r//g' \
    | grep -viE '^\s*$|NONE' \
    | sed -E 's/^\s*[-*•]+\s*//; s/^[0-9]+[.)]\s*//' \
    | grep -vE '^(#|`|：|:)' \
    | head -n "$LESSONS_PER_TASK" \
    | cut -c1-120 > "$STAMP_DIR/.new-rules"

  if [ $rc -eq 0 ] && [ -s "$STAMP_DIR/.new-rules" ]; then
    python3 - "$LEAVES_DIR/$key.json" "$STAMP_DIR/.new-rules" <<'PYEOF'
import json, sys
rules = [l.strip() for l in open(sys.argv[2]) if l.strip()]
json.dump({"lessons": rules}, open(sys.argv[1], "w"), ensure_ascii=False)
print("leaf %s: %d lesson(s)" % (sys.argv[1], len(rules)))
PYEOF
  fi
  echo "[$(date +%Y%m%d-%H%M%S)] summarized $name rc=$rc rules=$(wc -l < "$STAMP_DIR/.new-rules")" >> "$LOG_DIR/summarize.log"
  # metrics: one summarize sweep is one cline run (kind inferred from the name)
  python3 "$DAEMON_DIR/tools/metrics.py" "$SUM_LOG" "$rc" >> "$LOG_DIR/metrics.log" 2>&1 || true
  # only stamp success; failures retry on a later sweep (call is tiny)
  [ $rc -eq 0 ] && : > "$STAMP_DIR/$name.done"
done

# tournament pass: stride-group → merge (hash-cached) → stats → golden/fusion
python3 "$DAEMON_DIR/lines/summarize-tree.py" >> "$LOG_DIR/summarize.log" 2>&1 || true
# effect pass: eight houses (iteration octiles), per-lesson iterations-saved,
# objective value V; owns the playbook rolling section from here on
python3 "$DAEMON_DIR/lines/playbook-effect.py" >> "$LOG_DIR/summarize.log" 2>&1 || true
exit 0
