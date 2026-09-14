#!/usr/bin/env bash
# source.sh — the issue-source test, single home (bash side of hfv_source.py).
# A record's message_id is an opaque key everywhere; the ONLY source dispatch
# is this prefix test. GitHub-sourced records carry "gh-<issue-number>".
# usage: source framework/source.sh; is_gh "$mid" && ...

is_gh() { [[ "${1:-}" == gh-* ]]; }
