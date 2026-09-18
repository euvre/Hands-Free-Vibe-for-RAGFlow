#!/usr/bin/env python3
"""gh-assets.py — publish report screenshots to the fork's hfv-report-assets
branch via the git-data API (blobs -> tree -> commit -> ref), then rewrite the
report's local image paths to raw.githubusercontent.com URLs in place.

Why: GitHub has no public "comment image upload" API, but raw URLs from a
branch render inline in markdown. The fork is ours, so a dedicated orphan-ish
assets branch is the clean host for them.

Usage: gh-assets.py publish --pr <num> --report <file>
Exit 0 even when nothing was referenced/uploaded (the report stands alone).
"""
import argparse
import base64
import json
import os
import re
import subprocess
import sys

DIR = os.path.expanduser("~/hands-free-vibe")
BRANCH = "hfv-report-assets"


def run(cmd, inp=None):
    p = subprocess.run(cmd, capture_output=True, text=True, input=inp, timeout=120)
    return p.returncode, p.stdout.strip()


def fork_repo():
    rc, out = run(["bash", "-c",
                   "source %s/config.sh && git -C \"$RAGFLOW_MAIN\" remote get-url \"$FORK_REMOTE\""
                   % DIR])
    if rc != 0 or not out:
        raise SystemExit("cannot resolve fork remote url")
    m = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$", out)
    if not m:
        raise SystemExit("not a github remote: " + out)
    return m.group(1)


def gh_api(method, endpoint, **fields):
    # JSON body via stdin: a base64 PNG blows past the per-argument kernel
    # limit (MAX_ARG_STRLEN 128KB) when passed as -f content=...
    cmd = ["gh", "api", "-X", method, endpoint]
    inp = None
    if fields:
        cmd += ["--input", "-"]
        inp = json.dumps(fields)
    rc, out = run(cmd, inp)
    if rc != 0:
        return None
    try:
        return json.loads(out)
    except Exception:
        return {}


def ensure_branch(repo):
    r = gh_api("GET", "repos/%s/git/ref/heads/%s" % (repo, BRANCH))
    if r:
        return r["object"]["sha"]
    base = gh_api("GET", "repos/%s" % repo)
    head = gh_api("GET", "repos/%s/git/ref/heads/%s" % (repo, base["default_branch"]))
    r = gh_api("POST", "repos/%s/git/refs" % repo,
               ref="refs/heads/" + BRANCH, sha=head["object"]["sha"])
    if not r:
        raise SystemExit("failed to create " + BRANCH)
    return r["object"]["sha"]


def publish(repo, pr, files):
    head_sha = ensure_branch(repo)
    commit = gh_api("GET", "repos/%s/git/commits/%s" % (repo, head_sha))
    entries = []
    mapping = {}
    for path in files:
        raw = base64.b64encode(open(path, "rb").read()).decode()
        blob = gh_api("POST", "repos/%s/git/blobs" % repo, content=raw, encoding="base64")
        if not blob:
            print("blob upload FAILED: %s" % path, file=sys.stderr)
            continue
        name = "pr-%s/%s" % (pr, os.path.basename(path))
        entries.append({"path": name, "mode": "100644", "type": "blob",
                        "sha": blob["sha"]})
        mapping[path] = ("https://raw.githubusercontent.com/%s/%s/%s"
                         % (repo, BRANCH, name))
    if not entries:
        return mapping
    tree = gh_api("POST", "repos/%s/git/trees" % repo,
                  base_tree=commit["tree"]["sha"], tree=entries)
    new_commit = gh_api("POST", "repos/%s/git/commits" % repo,
                        message="report assets for pr #%s" % pr,
                        tree=tree["sha"], parents=[head_sha])
    r = gh_api("PATCH", "repos/%s/git/refs/heads/%s" % (repo, BRANCH),
               sha=new_commit["sha"])
    if not r:
        raise SystemExit("ref update FAILED — commit %s orphaned" % new_commit["sha"])
    return mapping


IMG_RE = re.compile(r"(/[^\s)\]]+?/scratch/[^\s)\]]+?\.(?:png|jpe?g|gif|webp))")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["publish"])
    ap.add_argument("--pr", required=True)
    ap.add_argument("--report", required=True)
    a = ap.parse_args()

    body = open(a.report).read()
    paths = sorted({p for p in IMG_RE.findall(body) if os.path.exists(p)})
    if not paths:
        return
    mapping = publish(fork_repo(), a.pr, paths)
    for path, url in mapping.items():
        body = body.replace(path, url)
    open(a.report, "w").write(body)
    for path, url in mapping.items():
        print("%s -> %s" % (path, url))


if __name__ == "__main__":
    main()
