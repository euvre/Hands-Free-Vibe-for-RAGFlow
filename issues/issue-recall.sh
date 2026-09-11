#!/usr/bin/env bash
# issue-recall.sh — recall (撤回) a Feishu message by message_id.
# Best-effort: logs failures but never exits non-zero (callers use it as a
# side-effect during record/sync cleanup).
#   issue-recall.sh <message_id>
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$DIR/config"
LOG="/home/inf/hands-free-vibe/logs/issues.log"

MID="${1:-}"
if [[ -z "$MID" ]]; then
  echo "issue-recall: no message_id given" >&2
  exit 0
fi

mkdir -p "$(dirname "$LOG")"
python3 - "$CONFIG" "$MID" <<'PYEOF'
import json, os, sys, urllib.request, urllib.error

config_path, mid = sys.argv[1], sys.argv[2]
cfg = {}
for line in open(config_path):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        cfg[k.strip()] = v.strip().strip('"')
BASE = "https://open.feishu.cn/open-apis"

req = urllib.request.Request(
    f"{BASE}/auth/v3/tenant_access_token/internal", method="POST")
req.add_header("Content-Type", "application/json; charset=utf-8")
body = json.dumps({"app_id": cfg["APP_ID"], "app_secret": cfg["APP_SECRET"]}).encode()
with urllib.request.urlopen(req, data=body, timeout=15) as resp:
    token = json.loads(resp.read())["tenant_access_token"]

url = f"{BASE}/im/v1/messages/{mid}"
req = urllib.request.Request(url, method="DELETE")
req.add_header("Authorization", f"Bearer {token}")
try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        r = json.loads(resp.read())
    if r.get("code") != 0:
        print("issue-recall: %s failed: %s" % (mid, json.dumps(r, ensure_ascii=False)[:200]))
    else:
        print("issue-recall: %s recalled" % mid)
except urllib.error.HTTPError as e:
    print("issue-recall: %s HTTP %s %r" % (mid, e.code, e.read()[:200]))
except Exception as e:
    print("issue-recall: %s error: %s" % (mid, e))
PYEOF
exit 0
