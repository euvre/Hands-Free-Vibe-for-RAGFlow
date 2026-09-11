#!/usr/bin/env python3
"""One-shot: insert the HFV_EXEC_SNAPSHOT re-exec guard into run-task.sh.
Idempotent (no-op when the guard is already present). Invoked by
apply-exec-guard.sh only while run.lock is held, i.e. no run-task.sh live."""
import sys

P = "/home/inf/hands-free-vibe/lines/run-task.sh"
GUARD = '''
# Re-exec from a private snapshot so editing this file mid-run cannot corrupt
# the interpreter's byte stream.
if [[ -z "${HFV_EXEC_SNAPSHOT:-}" ]]; then
  HFV_EXEC_SNAPSHOT="$(mktemp /tmp/hfv-exec-snap.XXXXXX.sh)" || exit 1
  cat -- "$0" > "$HFV_EXEC_SNAPSHOT" || exit 1
  export HFV_EXEC_SNAPSHOT
  exec bash "$HFV_EXEC_SNAPSHOT" "$@"
fi
trap 'rm -f "$HFV_EXEC_SNAPSHOT"' EXIT
'''

src = open(P).read()
if "HFV_EXEC_SNAPSHOT" in src:
    print("guard already present, no-op")
    sys.exit(0)
anchor = "set -u\n"
assert src.count(anchor) == 1, "unexpected set -u count in run-task.sh"
src = src.replace(anchor, anchor + GUARD, 1)
tmp = P + ".guardtmp"
with open(tmp, "w") as f:
    f.write(src)
import os
os.replace(tmp, P)
print("guard inserted after 'set -u'")
