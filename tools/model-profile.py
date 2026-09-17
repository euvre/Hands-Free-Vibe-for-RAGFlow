#!/usr/bin/env python3
"""model-profile.py — view/switch the LLM profile used by all cline daemon runs.

Profiles:
  kimi  Kimi k3 only — native image input, the agent views screenshots itself.
  glm   GLM glm-5.3 main agent (text-only: the GLM coding endpoint rejects
        image content) + Kimi vision transcription of screenshots in the
        pre-pass (issues/issue-vision.py, gated on the profile marker).

Scope: daemon-side ONLY. The cline CLI runners (run-task.sh, run-feat.sh,
summarize-run.sh) pass explicit `-P -m -k` words derived from the marker file
(`args` subcommand), so daemon runs never depend on ~/.cline settings. The
global providers.json / models.json belong to the interactive VS Code
extension — `apply` deliberately never touches them (rewriting them used to
fight with the extension's own writes).

Files touched:
  ~/hands-free-vibe/.model-profile          marker read by runners / pre-task.sh
"""
import os
import sys

HOME = os.path.expanduser("~")
MARKER = os.path.join(HOME, "hands-free-vibe", ".model-profile")

# NOTE kimi profile: native image input (agent views screenshots itself).
# NOTE kimi in containers: cline has no base-url flag, so the openai-compatible
#   provider's baseUrl must live in the golden image's baked
#   ~/.cline/data/settings/providers.json (copy the host's block — without it
#   the run hits api.openai.com and the kimi key is rejected there). Verified
#   2026-09-17 after a golden rebuild dropped it.
# NOTE glm profile: text-only — the GLM coding endpoint rejects image content
# ("messages.content.type 参数非法"); screenshots are transcribed to text by
# issue-vision.py in the pre-pass instead.
# NOTE provider ids: glm uses cline's NATIVE "zhipuai-coding-plan" provider —
# passing the GLM key through "-P openai-compatible -k" is rejected client-side
# by key-format validation (id.secret vs sk-...). kimi stays on
# openai-compatible (its sk- key passes -k fine).
# NOTE keys: api keys live OUTSIDE this file in model-keys.json (gitignored).
# Format: {"kimi": ["sk-...", ...], "glm": ["id.secret", ...]} — a LIST
# per profile (keys are not unique per provider): quota exhaustion rotates to
# the next key immediately instead of waiting out the billing cycle. The
# legacy single-string form ({"kimi": "sk-..."}) is auto-migrated on read.
PROFILES = {
    "kimi": {
        "provider": "openai-compatible",
        "model": "k3",
        "baseUrl": "https://api.kimi.com/coding/v1",
    },
    "glm": {
        "provider": "zhipuai-coding-plan",
        "model": "glm-5.3",
        "baseUrl": "https://open.bigmodel.cn/api/coding/paas/v4",
    },
}

KEYS_FILE = os.path.join(HOME, "hands-free-vibe", "model-keys.json")


def _load_keys():
    """{profile: [key, ...]} — the legacy single-string form is migrated on
    read; every read path (args / keylist / key show) goes through here."""
    import json
    try:
        raw = json.load(open(KEYS_FILE))
    except Exception:
        return {}
    out = {}
    for name, v in raw.items():
        if isinstance(v, str):
            v = [v]
        out[name] = [k.strip() for k in (v or []) if isinstance(k, str) and k.strip()]
    return out


def _save_keys(d):
    import json
    tmp = KEYS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=1)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, KEYS_FILE)


def _api_keys(name):
    keys = _load_keys().get(name) or []
    if not keys:
        sys.stderr.write(
            "model-profile: no api key for profile %r in %s (add one: hfv key add %s <key>)\n"
            % (name, KEYS_FILE, name))
        sys.exit(1)
    return keys


def _api_key(name):
    # first key = the default; runners that rotate use `keylist` instead
    return _api_keys(name)[0]


def apply(name):
    # marker-only: the CLI runners derive explicit -P/-m/-k from the marker;
    # providers.json / models.json belong to the VS Code extension and are
    # deliberately left alone (daemon and extension no longer fight over them)
    p = PROFILES[name]
    with open(MARKER, "w") as f:
        f.write(name + "\n")
    vision = ("kimi transcribes screenshots in pre-pass" if name == "glm"
              else "off (agent views images natively)")
    print(f"profile={name} model={p['model']} baseUrl={p['baseUrl']}")
    print(f"vision={vision}")
    print("note: daemon runs use the marker directly; the VS Code extension's "
          "~/.cline settings are untouched")


def infer_current():
    # the marker is the single source of truth for the daemon; the extension's
    # providers.json says nothing about which profile the CLI runs use
    try:
        return open(MARKER).read().strip() or None
    except Exception:
        return None


def cli_args():
    """Provider/model/key override words for `cline` invocations, derived from
    the CURRENT profile marker — runners pass these explicitly so main task,
    feat task and summarizer all use the same model regardless of what any
    external process wrote into the global providers.json."""
    name = infer_current()
    if name not in PROFILES:
        sys.stderr.write("model-profile: no profile selected; run `hfv model <kimi|glm>`\n")
        return 1
    p = PROFILES[name]
    print(f"-P {p['provider']} -m {p['model']} -k {_api_key(name)}")
    return 0


def show():
    name = infer_current()
    print(f"profile={name or 'unset'}")
    if name in PROFILES:
        p = PROFILES[name]
        print(f"model={p['model']} baseUrl={p['baseUrl']}")
        vision = ("kimi transcribes screenshots and videos in pre-pass" if name == "glm"
                  else "off (agent views images natively)")
        print(f"vision={vision}")
    print("scope: daemon (cline CLI) only; the VS Code extension's "
          "~/.cline settings are separate")


def show_keys():
    """Grouped table: provider on the first key's row, continuation keys
    indented to the key column, a divider between providers. Row order IS the
    quota-rotation order (top first)."""
    d = _load_keys()
    names = list(PROFILES)
    width = max(len(n) for n in names)
    first = True
    for name in names:
        keys = d.get(name) or []
        if not first:
            print("-" * 20)
        first = False
        if not keys:
            print(f"{name:<{width}}  (no keys — add: hfv key add {name} <key>)")
            continue
        for i, k in enumerate(keys):
            masked = f"{k[:6]}...{k[-4:]}" if len(k) > 12 else "***masked***"
            print(f"{name if i == 0 else '':<{width}}  {masked}")


def _shape_ok(name, key):
    if name == "kimi":
        return key.startswith("sk-")
    if name == "glm":
        return "." in key
    return True


def add_key(name, key, force=False):
    """Append one key to the profile's list (dedup). Atomic write, 0600 kept.
    Shape guardrails follow the providers' published key forms (cline validates
    them client-side); --force overrides."""
    key = (key or "").strip()
    if not key:
        sys.stderr.write("model-profile: empty key refused\n")
        return 1
    if not _shape_ok(name, key) and not force:
        hint = ("kimi keys start with 'sk-'" if name == "kimi"
                else "glm keys look like '<id>.<secret>'")
        sys.stderr.write(f"model-profile: {hint} — refusing; "
                         "append --force if the shape really changed\n")
        return 1
    d = _load_keys()
    keys = d.setdefault(name, [])
    if key in keys:
        print(f"{name}: key already present as #{keys.index(key) + 1} "
              f"({len(keys)} key(s) total) — nothing to do")
        return 0
    keys.append(key)
    _save_keys(d)
    print(f"{name}: key added as #{len(keys)} (quota rotation order = list order); "
          "running tasks keep the key they started with — the NEXT run picks it up")
    print("scope: daemon (model-keys.json) only; interactive cline / the VS Code "
          "extension use separate stores (~/.cline)")
    return 0


def remove_key(name, key):
    """Remove one key by exact value (masked forms never match on purpose)."""
    key = (key or "").strip()
    d = _load_keys()
    keys = d.get(name) or []
    if key not in keys:
        sys.stderr.write(f"model-profile: no such key under {name} "
                         "(pass the exact key value, or --stdin it)\n")
        return 1
    keys.remove(key)
    d[name] = keys
    _save_keys(d)
    print(f"{name}: key removed ({len(keys)} key(s) left)")
    if not keys:
        sys.stderr.write(f"model-profile: WARNING — {name} has NO keys left; "
                         f"runs on that profile will fail until you add one\n")
    return 0


def rotate_key(name, count=1):
    """Left-rotate the profile's key list by `count` (first → last; negative
    rotates right — Python's % already lands the cut point correctly). The NEXT
    run starts from the new head. Running tasks are unaffected (they read the
    list into memory at start)."""
    d = _load_keys()
    keys = d.get(name) or []
    if len(keys) < 2:
        print(f"{name}: {len(keys)} key(s) — nothing to rotate")
        return 0
    count = count % len(keys)
    if count == 0:
        print(f"{name}: rotation by a multiple of {len(keys)} is a no-op")
        return 0
    d[name] = keys[count:] + keys[:count]
    _save_keys(d)
    print(f"{name}: rotated left by {count} (net); the next run starts from what was key #{count + 1}. New order:")
    for i, k in enumerate(d[name], 1):
        masked = f"{k[:6]}...{k[-4:]}" if len(k) > 12 else "***masked***"
        print(f"  {i}. {masked}")
    return 0


def key_cmd(argv):
    """key [show] | key add <kimi|glm> <key|--stdin> [--force]
             | key remove <kimi|glm> <key|--stdin>
             | key rotate <kimi|glm> [n]
    Backward compatible: key <kimi|glm> <key> [--force] == key add ..."""
    sub = argv[0] if argv else ""
    if sub in ("", "show", "list"):
        show_keys()
        return 0
    if sub == "add" and len(argv) >= 3 and argv[1] in PROFILES:
        key = argv[2]
        if key == "--stdin":  # keeps the key out of the shell history
            key = sys.stdin.readline()
        return add_key(argv[1], key, "--force" in argv[3:])
    if sub == "remove" and len(argv) >= 3 and argv[1] in PROFILES:
        key = argv[2]
        if key == "--stdin":
            key = sys.stdin.readline()
        return remove_key(argv[1], key)
    if sub == "rotate" and len(argv) >= 2 and argv[1] in PROFILES:
        n = 1
        if len(argv) >= 3:
            try:
                n = int(argv[2])
            except ValueError:
                sys.stderr.write("model-profile: rotate count must be a number\n")
                return 1
            # ±int32 only; the modulo in rotate_key does the real math, so a
            # huge number would be pointless anyway. Negative n rotates right.
            if not (-(2 ** 31) <= n <= 2 ** 31 - 1):
                print("You twisted the steering wheel until it broke.")
                return 1
        return rotate_key(argv[1], n)
    if sub in PROFILES and len(argv) >= 2:  # legacy: key <profile> <key> == add
        key = argv[1]
        if key == "--stdin":
            key = sys.stdin.readline()
        return add_key(sub, key, "--force" in argv[2:])
    sys.stderr.write("usage: model-profile.py key [show]\n"
                     "       model-profile.py key add <kimi|glm> <new-key|--stdin> [--force]\n"
                     "       model-profile.py key remove <kimi|glm> <key|--stdin>\n"
                     "       model-profile.py key rotate <kimi|glm> [n]\n")
    return 1


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "show"
    if mode == "show":
        show()
    elif mode == "current":
        print(infer_current() or "")
    elif mode == "args":
        return cli_args()
    elif mode == "apply" and len(sys.argv) == 3 and sys.argv[2] in PROFILES:
        apply(sys.argv[2])
    elif mode == "key":
        return key_cmd(sys.argv[2:])
    elif mode == "keylist":
        # One plaintext key per line for the CURRENT profile — runner-side quota
        # rotation consumes this. Runners must never echo it into logs.
        name = infer_current()
        if name not in PROFILES:
            sys.stderr.write("model-profile: no profile selected; run `hfv model <kimi|glm>`\n")
            return 1
        for k in _api_keys(name):
            print(k)
    elif mode == "args-base":
        # -P/-m WITHOUT -k: runners rotate the key themselves (keylist)
        name = infer_current()
        if name not in PROFILES:
            sys.stderr.write("model-profile: no profile selected; run `hfv model <kimi|glm>`\n")
            return 1
        p = PROFILES[name]
        print(f"-P {p['provider']} -m {p['model']}")
    else:
        sys.stderr.write("usage: model-profile.py show | current | args | apply <kimi|glm> | key [show] | key <kimi|glm> <new-key|--stdin> [--force]\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
