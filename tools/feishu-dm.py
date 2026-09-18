#!/usr/bin/env python3
"""feishu-dm.py — Feishu direct messages for the PR follow-up lines.

TWO channels, user first:
  1. USER (preferred, "以用户名义"): user_access_token obtained by refreshing
     the OAuth grant that lark-mcp stores encrypted in
     ~/.local/share/lark-mcp-nodejs/storage.json (AES key lives in the system
     keyring, service=lark-mcp/account=encryption-key). User-token DMs are not
     limited by the bot's availability scope.
     REQUIREMENT: the OAuth app must have the
     `im:message.send_as_user` scope granted AND the user must re-authorize
     once — until then the API answers 230027 and we fall through to (2).
  2. BOT (fallback): tenant_access_token from issues/config. Works only for
     users inside the bot's availability scope (currently nobody — every DM
     attempt logs HTTP 400 code 230013).

Subcommands:
  dm <github-login> <text>     DM the member mapped from the GitHub login
  dm-owner <text>             DM the merge owner (top-level "owner" field of team-map.json)
  whoami                       list the mapping (logins only)
  token                        diagnostics: which channel is usable right now

Exit codes: 0 sent, 1 unmapped login, 2 API failure on both channels.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # repo root (this file lives in tools/)
sys.path.insert(0, DIR)
from hfv_config import load as _load_hfv  # noqa: E402
_HFV = _load_hfv()
MAP = os.path.join(DIR, "team-map.json")
BASE = "https://open.feishu.cn/open-apis"
# Kill switch: drop this marker file to silence EVERY outbound DM
# (owner ready reports AND reviewer notifications). Group-thread replies
# (issue-reply.py, the main task's delivery channel) are NOT affected.
DM_DISABLE_FILE = os.path.join(DIR, ".dm-disabled")
STORAGE = os.path.expanduser("~/.local/share/lark-mcp-nodejs/storage.json")
UAT_CACHE = "/tmp/feishu-uat.cache"
# Our own rotated-token state: Feishu refresh tokens are ONE-TIME-USE — each
# successful refresh invalidates the old one and issues a new one. lark-mcp
# never learns about OUR refreshes, so its storage.json goes stale; we keep
# our own state file and prefer it over storage.json's (which still serves as
# the recovery path whenever the user re-authorizes lark-mcp).
UAT_STATE = os.path.join(DIR, "state", ".feishu-uat-state.json")


# ---------- user token channel ----------

def _decrypt_storage():
    """Return the decrypted lark-mcp token store (AES-256-CBC, key from the
    system keyring via libsecret over dbus)."""
    import dbus
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    bus = dbus.SessionBus()
    service = bus.get_object("org.freedesktop.secrets", "/org/freedesktop/secrets")
    out, session = service.OpenSession("plain", "", dbus_interface="org.freedesktop.Secret.Service")
    coll = bus.get_object("org.freedesktop.secrets", "/org/freedesktop/secrets/collection/login")
    key = None
    for ip in coll.Get("org.freedesktop.Secret.Collection", "Items",
                       dbus_interface="org.freedesktop.DBus.Properties"):
        it = bus.get_object("org.freedesktop.secrets", ip)
        label = str(it.Get("org.freedesktop.Secret.Item", "Label",
                           dbus_interface="org.freedesktop.DBus.Properties"))
        if "encryption-key" in label:
            unlocked, prompt = service.Unlock([ip], dbus_interface="org.freedesktop.Secret.Service")
            if str(prompt) != "/":
                po = bus.get_object("org.freedesktop.secrets", prompt)
                po.Prompt("", dbus_interface="org.freedesktop.Secret.Prompt")
                for _ in range(60):
                    time.sleep(0.2)
                    try:
                        if po.Get("org.freedesktop.Secret.Prompt", "Completed",
                                  dbus_interface="org.freedesktop.DBus.Properties"):
                            break
                    except Exception:
                        pass
            sec = it.GetSecret(dbus.ObjectPath(str(session)), dbus_interface="org.freedesktop.Secret.Item")
            key = bytes(sec[2]).decode()
            break
    if not key:
        return None
    iv_hex, enc_hex = open(STORAGE).read().strip().split(":")
    dec = Cipher(algorithms.AES(bytes.fromhex(key)), modes.CBC(bytes.fromhex(iv_hex))).decryptor()
    plain = dec.update(bytes.fromhex(enc_hex)) + dec.finalize()
    return json.loads(plain[: -plain[-1]].decode())


def _http_json(url, body, headers=None, timeout=15):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type", "application/json; charset=utf-8")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read()), 200
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read()), e.code
        except Exception:
            return {"code": -1, "msg": "unreadable error body"}, e.code


def _load_state():
    try:
        return json.load(open(UAT_STATE))
    except Exception:
        return {}


def _save_state(state):
    tmp = UAT_STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, UAT_STATE)


def fresh_user_token():
    """Fresh user_access_token, cached ~90 min. Refresh-token rotation is
    persisted to UAT_STATE (see comment there)."""
    try:
        st = _load_state()
        if st.get("access_token") and time.time() - st.get("obtained_at", 0) < 5400:
            return st["access_token"]
        rt = st.get("refresh_token") or ""
        app_id = st.get("app_id") or ""
        app_secret = st.get("app_secret") or ""
        if not (rt and app_id and app_secret):
            store = _decrypt_storage()
            if not store:
                return ""
            entry = list((store.get("tokens") or {}).values())[0]
            extra = entry.get("extra") or {}
            rt = rt or extra.get("refreshToken") or ""
            app_id = app_id or extra.get("appId") or ""
            app_secret = app_secret or extra.get("appSecret") or ""
        if not (rt and app_id and app_secret):
            return ""
        r, _ = _http_json(f"{BASE}/auth/v3/app_access_token/internal",
                          {"app_id": app_id, "app_secret": app_secret})
        aat = r.get("app_access_token")
        if not aat:
            return ""
        r, _ = _http_json(f"{BASE}/authen/v1/oidc/refresh_access_token",
                          {"grant_type": "refresh_token", "refresh_token": rt},
                          {"Authorization": "Bearer " + aat})
        data = r.get("data") or {}
        tok = data.get("access_token") or ""
        if not tok:
            print(f"uat: refresh failed code={r.get('code')} "
                  f"(refresh token stale? re-run lark-mcp oauth once)", file=sys.stderr)
            return ""
        # persist rotation: the NEW refresh token is the only valid one now
        _save_state({"access_token": tok,
                     "refresh_token": data.get("refresh_token") or rt,
                     "app_id": app_id, "app_secret": app_secret,
                     "obtained_at": time.time()})
        return tok
    except Exception as e:
        print(f"uat: user-token channel unavailable: {e}", file=sys.stderr)
        return ""


# ---------- bot channel ----------

def tenant_token():
    cfg = {}
    for line in open(os.path.join(DIR, "issues", "config")):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"')
    r, _ = _http_json(f"{BASE}/auth/v3/tenant_access_token/internal",
                      {"app_id": cfg["APP_ID"], "app_secret": cfg["APP_SECRET"]})
    return r.get("tenant_access_token", "")


# ---------- shared ----------

def load_map():
    if not os.path.exists(MAP):
        return {"members": [], "owner": ""}
    try:
        return json.load(open(MAP))
    except Exception:
        return {"members": [], "owner": ""}


def lookup_open_id(login):
    for it in load_map().get("members", []):
        if (it.get("github") or "").lower() == (login or "").lower():
            return it.get("feishu") or ""
    return ""


def _send(open_id, text, bearer):
    url = f"{BASE}/im/v1/messages?receive_id_type=open_id"
    body = {"receive_id": open_id, "msg_type": "text",
            "content": json.dumps({"text": text}, ensure_ascii=False)}
    return _http_json(url, body, {"Authorization": "Bearer " + bearer})


def send_dm(open_id, text):
    """User channel first, bot fallback. Returns (channel, code)."""
    if os.path.exists(DM_DISABLE_FILE):
        print("dm: silenced by %s (kill switch active)" % DM_DISABLE_FILE)
        return "disabled", 3
    uat = fresh_user_token()
    if uat:
        r, http = _send(open_id, text, uat)
        if r.get("code") == 0:
            mid = ((r.get("data") or {}).get("message_id")) or ""
            print(f"dm: sent as user, message_id={mid}")
            return "user", 0
        if r.get("code") == 230027:
            print("dm: user token lacks im:message.send_as_user scope "
                  "(grant it on the OAuth app + re-authorize lark-mcp once); "
                  "falling back to bot", file=sys.stderr)
        else:
            print(f"dm: user channel failed code={r.get('code')} http={http} "
                  f"{(r.get('msg') or '')[:80]}; falling back to bot", file=sys.stderr)
    tok = tenant_token()
    if not tok:
        return "bot", 2
    r, http = _send(open_id, text, tok)
    if r.get("code") == 0:
        return "bot", 0
    print(f"dm: bot channel failed code={r.get('code')} http={http} "
          f"{(r.get('msg') or '')[:100]} (bot availability scope covers nobody)", file=sys.stderr)
    return "bot", r.get("code") if isinstance(r.get("code"), int) else 2


def main():
    args = sys.argv[1:]
    if not args or args[0] == "whoami":
        for it in load_map().get("members", []):
            print("%s -> %s" % (it.get("github"), (it.get("name") or it.get("feishu", "")[:12])))
        print("owner mapped:", bool(load_map().get("owner")))
        return 0
    if args[0] == "token":
        uat = fresh_user_token()
        print("user channel:", "READY" if uat else "unavailable",
              "(needs im:message.send_as_user scope to actually send)" if uat else "")
        print("bot channel: availability-limited (no user in scope as of 2026-08-20)")
        return 0
    if args[0] == "dm" and len(args) >= 3:
        login, text = args[1], " ".join(args[2:])
        oid = lookup_open_id(login)
        if not oid:
            print(f"dm: github login {login!r} not in team-map.json (skipped)", file=sys.stderr)
            return 1
        ch, code = send_dm(oid, text)
        return 0 if code == 0 else 2
    if args[0] == "dm-owner" and len(args) >= 2:
        oid = load_map().get("owner") or lookup_open_id(_HFV["MERGE_OWNER_LOGIN"])
        if not oid:
            print("dm: owner open_id missing from team-map.json", file=sys.stderr)
            return 1
        ch, code = send_dm(oid, " ".join(args[1:]))
        return 0 if code == 0 else 2
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
