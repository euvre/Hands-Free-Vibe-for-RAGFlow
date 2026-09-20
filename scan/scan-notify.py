#!/usr/bin/env python3
"""scan-notify.py — post a message to the Feishu group (new message, or a
reply into an existing thread).

Used by the scan line's post group: a reproduced bug found by the repo scan
has no originating thread, so the report lands in the group as a fresh
message — and follow-ups (the PR-link notification) reply INTO that report's
thread instead of spamming the group with a second standalone message.
Bot channel only (tenant_access_token from issues/config).

  scan-notify.py [text ...]              new group message; prints message_id
  scan-notify.py --file <path>           new message with the file's content
  scan-notify.py --reply-to <mid> [text] reply into <mid>'s thread

Prints the created message_id on success. Exit 0 sent, 1 usage/config,
2 API failure. Text is truncated to 3000 chars (group messages should be
readable; the full report lives in the task archive anyway).
"""
import json
import os
import sys
import urllib.error
import urllib.request

ISSUES_CFG = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                          "issues", "config")
BASE = "https://open.feishu.cn/open-apis"
MAX_CHARS = 3000


def load_config():
    cfg = {}
    if not os.path.exists(ISSUES_CFG):
        return cfg
    for line in open(ISSUES_CFG):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"')
    return cfg


def save_chat_id(chat_id):
    """Persist the resolved CHAT_ID back into issues/config (same convention
    as the issue recorder: resolve by name once, cache afterwards)."""
    lines = open(ISSUES_CFG).read().splitlines()
    out, done = [], False
    for line in lines:
        if not done and line.startswith("CHAT_ID="):
            out.append("CHAT_ID=%s" % chat_id)
            done = True
        else:
            out.append(line)
    if not done:
        out.append("CHAT_ID=%s" % chat_id)
    with open(ISSUES_CFG, "w") as f:
        f.write("\n".join(out) + "\n")


def api(cfg, method, path, body=None, token=None):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("Content-Type", "application/json; charset=utf-8")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    data = json.dumps(body, ensure_ascii=False).encode() if body is not None else None
    with urllib.request.urlopen(req, data=data, timeout=15) as resp:
        return json.loads(resp.read())


def tenant_token(cfg):
    r = api(cfg, "POST", "/auth/v3/tenant_access_token/internal",
            {"app_id": cfg["APP_ID"], "app_secret": cfg["APP_SECRET"]})
    return r["tenant_access_token"]


def resolve_chat_id(cfg, token):
    if cfg.get("CHAT_ID"):
        return cfg["CHAT_ID"]
    name = cfg.get("CHAT_NAME")
    if not name:
        raise SystemExit("scan-notify: issues/config has neither CHAT_ID nor CHAT_NAME")
    r = api(cfg, "GET", "/im/v1/chats?page_size=50", token=token)
    for ch in r.get("data", {}).get("items", []):
        if ch.get("name") == name:
            save_chat_id(ch["chat_id"])
            return ch["chat_id"]
    raise SystemExit("scan-notify: group %r not found via bot API" % name)


def main():
    args = sys.argv[1:]
    reply_to = ""
    text = ""
    if args[:1] == ["--reply-to"] and len(args) >= 2:
        reply_to = args[1]
        args = args[2:]
    if args[:1] == ["--file"] and len(args) == 2:
        text = open(args[1]).read()
    elif args:
        text = " ".join(args)
    else:
        text = sys.stdin.read()
    text = text.strip()
    if not text:
        print("scan-notify: empty text", file=sys.stderr)
        return 1
    if len(text) > MAX_CHARS:
        text = text[:MAX_CHARS] + "\n…（全文见任务归档）"

    cfg = load_config()
    if not cfg.get("APP_ID") or not cfg.get("APP_SECRET"):
        print("scan-notify: issues/config missing APP_ID/APP_SECRET", file=sys.stderr)
        return 1
    try:
        token = tenant_token(cfg)
        if reply_to:
            r = api(cfg, "POST", "/im/v1/messages/%s/reply" % reply_to,
                    {"msg_type": "text",
                     "content": json.dumps({"text": text}, ensure_ascii=False)},
                    token=token)
        else:
            chat_id = resolve_chat_id(cfg, token)
            r = api(cfg, "POST", "/im/v1/messages?receive_id_type=chat_id",
                    {"receive_id": chat_id, "msg_type": "text",
                     "content": json.dumps({"text": text}, ensure_ascii=False)},
                    token=token)
    except urllib.error.HTTPError as e:
        print("scan-notify: HTTP %s: %s" % (e.code, e.read()[:300]), file=sys.stderr)
        return 2
    except Exception as e:
        print("scan-notify: %s" % e, file=sys.stderr)
        return 2
    if r.get("code") != 0:
        print("scan-notify: API code=%s msg=%s" % (r.get("code"), r.get("msg")),
              file=sys.stderr)
        return 2
    print(r["data"]["message_id"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
