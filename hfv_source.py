#!/usr/bin/env python3
"""hfv_source.py — the issue-source test, single home.

A record's message_id is an opaque key everywhere; the ONLY source dispatch
is this prefix test. GitHub-sourced records carry "gh-<issue-number>".
"""


def is_gh(mid):
    return (mid or "").startswith("gh-")
