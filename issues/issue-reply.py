#!/usr/bin/env python3
# issue-reply.py — post a text reply into the Feishu thread of an issue.
# Accepts an LLM reply (or any text) via args or stdin:
#   issue-reply.py <message_id> [text ...]
#   echo "回复内容" | issue-reply.py <message_id>
# Prints the created reply's message_id on success.
import json
import os
import sys
import urllib.request
import urllib.error

DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(DIR, "config")
BASE = "https://open.feishu.cn/open-apis"


def load_config():
    cfg = {}
    for line in open(CONFIG):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"')
    return cfg


def tenant_token(cfg):
    req = urllib.request.Request(
        f"{BASE}/auth/v3/tenant_access_token/internal", method="POST")
    req.add_header("Content-Type", "application/json; charset=utf-8")
    body = json.dumps({"app_id": cfg["APP_ID"], "app_secret": cfg["APP_SECRET"]}).encode()
    with urllib.request.urlopen(req, data=body, timeout=15) as resp:
        return json.loads(resp.read())["tenant_access_token"]


def main():
    args = sys.argv[1:]
    if not args:
        print("usage: issue-reply.py <message_id> [text ...]  (text via stdin when omitted)",
              file=sys.stderr)
        return 1
    mid, text = args[0], " ".join(args[1:]).strip()
    if not text:
        text = sys.stdin.read().strip()
    if not text:
        print("empty reply text", file=sys.stderr)
        return 1

    # Source dispatch: a "gh-<number>" id identifies a GitHub issue record
    # (source=github) — the reply goes out as a comment on that issue via the
    # gh CLI (host-side auth) instead of the Feishu thread API.
    if mid.startswith("gh-"):
        import os
        import subprocess
        cfg = load_config()
        repo = cfg.get("GITHUB_ISSUE_REPO", "infiniflow/ragflow")
        gh_bin = os.environ.get("GH_BIN", "gh")
        try:
            out = subprocess.run(
                [gh_bin, "issue", "comment", mid[3:], "--repo", repo,
                 "--body-file", "-"],
                input=text.encode(), capture_output=True, timeout=30)
        except Exception as e:
            print("gh comment failed: %s" % e, file=sys.stderr)
            return 2
        if out.returncode != 0:
            print("gh comment failed: %s" % out.stderr.decode(errors="replace")[:300],
                  file=sys.stderr)
            return 2
        print(out.stdout.decode(errors="replace").strip())
        return 0

    cfg = load_config()
    token = tenant_token(cfg)
    body = {
        "msg_type": "text",
        "content": json.dumps({"text": text}, ensure_ascii=False),
    }
    req = urllib.request.Request(f"{BASE}/im/v1/messages/{mid}/reply", method="POST")
    req.add_header("Content-Type", "application/json; charset=utf-8")
    req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, data=json.dumps(body).encode(), timeout=15) as resp:
            r = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"reply failed: HTTP {e.code} {e.read()[:300]!r}", file=sys.stderr)
        return 2
    if r.get("code") != 0:
        print(f"reply failed: {json.dumps(r, ensure_ascii=False)[:300]}", file=sys.stderr)
        return 2
    print(r["data"]["message_id"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
