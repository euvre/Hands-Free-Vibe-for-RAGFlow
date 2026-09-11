#!/usr/bin/env bash
# env-preflight.sh — deterministic checks for the KNOWN environment failure
# modes (playbook.md is their graveyard):
#
#   api-proxy-scheme   vite launched with API_PROXY_SCHEME=go → EVERY /api
#                      call 500s through the web proxy while the backend is
#                      alive; ragflow-up.sh exports python by default
#   chrome-singleton   Singleton* locks left by a crashed chrome → the next
#                      browser launch exits in ~150ms and the MCP looks wedged
#   tokenizer-lib      missing librag_tokenizer_c_api.a → Go tests fail to
#                      link (fix: bash build.sh --cpp)
#   node-modules       web/node_modules symlink broken → type-check unusable
#   python-imports     import api/rag / test.benchmark with the WRONG cwd or
#                      PYTHONPATH → ModuleNotFoundError
#   ports/ready-status stale /tmp/ragflow-ready.status claiming READY while
#                      no app port listens
#
# usage:
#   env-preflight.sh local [worktree]        # run the checks in THIS namespace
#   env-preflight.sh e2e <num|audit> [wt]    # the same checks INSIDE the group
#
# Output, one line per check:
#   PREFLIGHT <OK|FIXED|WARN|FAIL|SKIP> <check> — <detail>
# then a final  PREFLIGHT_SUMMARY ok=<n> fixed=<n> warn=<n> fail=<n>  line.
# Exit code: 1 when any FAIL, else 0 — WARN/FIXED/SKIP never fail the caller;
# this script advises, the task prompt decides.
set -u
DIR="$HOME/hands-free-vibe"
source "$DIR/config.sh"

MODE="${1:-local}"

if [[ "$MODE" == "e2e" ]]; then
  SUFFIX="${2:-}"
  EWT="${3:-$RAGFLOW_MAIN}"
  [[ -n "$SUFFIX" ]] || { echo "usage: env-preflight.sh e2e <num|audit> [worktree]" >&2; exit 2; }
  # Self-delegate: $DIR is bind-mounted at the same path inside the group and
  # exec presets cwd/RAGFLOW_MAIN to the worktree (HFV_SLOT cleared), so the
  # local mode below runs with container-local semantics throughout.
  exec bash "$DIR/framework/pr-e2e.sh" exec "$SUFFIX" -- bash "$DIR/framework/env-preflight.sh" local "$EWT"
fi

[[ "$MODE" == "local" ]] || { echo "usage: env-preflight.sh local [worktree] | e2e <num|audit> [worktree]" >&2; exit 2; }
WT="${2:-$RAGFLOW_MAIN}"

ok=0; fixed=0; warn=0; fail=0; skip=0
report() { # report <LEVEL> <check> <detail>
  case "$1" in
    OK)    ok=$((ok + 1));;
    FIXED) fixed=$((fixed + 1));;
    WARN)  warn=$((warn + 1));;
    FAIL)  fail=$((fail + 1));;
    SKIP)  skip=$((skip + 1));;
  esac
  printf 'PREFLIGHT %s %s — %s\n' "$1" "$2" "$3"
}

# --- 1) chrome-singleton -----------------------------------------------------
# The browser MCP's profile dirs: the LLM's container bind-mounts its profile
# at ~/.cache/chrome-devtools-mcp; the second glob only matches when this
# script is run on the host for manual debugging (all real runs are in
# containers — PID namespaces isolate them, so a same-namespace pgrep is the
# correct "is chrome running" test).
# A lock is stale ONLY when no chrome runs in this namespace — PID namespaces
# isolate e2e/slot containers from each other, so a same-namespace pgrep is
# the correct test. The MCP-launched chrome always carries
# --remote-debugging-port.
chr_locks=()
for d in "$HOME"/.cache/chrome-devtools-mcp/profile* "$HOME"/hfv-slots/*/chrome-profile/profile*; do
  [[ -d "$d" ]] || continue
  for f in "$d"/Singleton*; do [[ -e "$f" ]] && chr_locks+=("$f"); done
done
if ((${#chr_locks[@]} == 0)); then
  report SKIP chrome-singleton "no chrome profile dirs in this namespace"
elif pgrep -f -- '--remote-debugging-port' >/dev/null 2>&1; then
  report OK chrome-singleton "${#chr_locks[@]} Singleton* lock(s) present but a chrome IS running here — left alone"
else
  rm -f "${chr_locks[@]}" 2>/dev/null || true
  report FIXED chrome-singleton "removed ${#chr_locks[@]} stale Singleton* lock(s) (no chrome running) — a crashed browser would otherwise make the next launch exit instantly and look like a wedged MCP"
fi

# --- 2) api-proxy-scheme ------------------------------------------------------
# What matters is the RUNNING vite's effective scheme (process env wins over
# web/.env.development under vite's loadEnv). A go-scheme running vite is the
# classic stale launch: every /api call 500s through the web proxy.
file_scheme="$(sed -n 's/^API_PROXY_SCHEME=//p' "$WT/web/.env.development" 2>/dev/null | tr -d "\"'" | head -1)"
run_scheme=""
for p in $(pgrep -f 'npm run dev|node.*vite' 2>/dev/null); do
  s="$(tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | sed -n 's/^API_PROXY_SCHEME=//p' | head -1)"
  if [[ -n "$s" ]]; then run_scheme="$s"; break; fi
done
if [[ -n "$run_scheme" ]]; then
  if [[ "$run_scheme" == "go" ]]; then
    report WARN api-proxy-scheme "vite RUNNING with API_PROXY_SCHEME=go (stale launch): every /api call 500s through the web proxy — relaunch via ragflow-up.sh (exports python by default); never debug the Python API for this"
  else
    report OK api-proxy-scheme "running vite uses API_PROXY_SCHEME=$run_scheme"
  fi
elif [[ "$file_scheme" == "go" ]]; then
  report OK api-proxy-scheme "no vite running; web/.env.development pins go but ragflow-up.sh >=2026-09-09 exports python over it (process env wins)"
else
  report SKIP api-proxy-scheme "no vite running and no .env.development pin found"
fi

# --- 3) tokenizer-lib ---------------------------------------------------------
tok_lib="$WT/internal/binding/cpp/cmake-build-release/librag_tokenizer_c_api.a"
if [[ -s "$tok_lib" ]]; then
  report OK tokenizer-lib "present"
else
  report WARN tokenizer-lib "missing $tok_lib — Go builds/tests fail to link; fix: cd $WT && bash build.sh --cpp"
fi

# --- 3b) office-oxide-version ---------------------------------------------------
# build.sh hard-pins OFFICE_OXIDE_VERSION and fails EVERY Go build/test on a
# mismatch (a stale lib silently loses PPT97 content). Caught live once by the
# unit tier: required 0.1.8 vs installed 0.1.9, four packages red.
oo_ver="$(sed -n 's/^OFFICE_OXIDE_VERSION="\(.*\)"/\1/p' "$WT/build.sh" 2>/dev/null | head -1)"
oo_lib=""
for f in "$HOME"/ragflow-native-libs/office_oxide/lib/liboffice_oxide.* /opt/ragflow-native-libs/office_oxide/lib/liboffice_oxide.*; do
  [[ -f "$f" ]] && { oo_lib="$f"; break; }
done
if [[ -z "$oo_ver" || -z "$oo_lib" ]]; then
  report SKIP office-oxide-version "pin or lib unreadable (build.sh:$oo_ver lib:$oo_lib)"
elif strings "$oo_lib" 2>/dev/null | grep -Fxq "$oo_ver"; then
  report OK office-oxide-version "office_oxide v$oo_ver matches the build.sh pin"
else
  oo_found="$(strings "$oo_lib" 2>/dev/null | grep -E '^0\.[0-9]+\.[0-9]+$' | head -1)"
  report FAIL office-oxide-version "version mismatch: required $oo_ver, found ${oo_found:-unknown} — EVERY Go build/test fails; fix: rm -rf ~/ragflow-native-libs/office_oxide ragflow_deps/office_oxide-linux-x86_64.tar.gz && uv run python3 ragflow_deps/download_go_deps.py"
fi

# --- 4) node-modules ----------------------------------------------------------
nm="$WT/web/node_modules"
if [[ -e "$nm/.bin/oxlint" ]]; then
  report OK node-modules "web/node_modules resolves (oxlint present)"
elif [[ -L "$nm" ]]; then
  report WARN node-modules "web/node_modules is a BROKEN symlink -> $(readlink "$nm") — type-check/lint unusable until relinked"
elif [[ -d "$nm" ]]; then
  report OK node-modules "web/node_modules is a real directory (oxlint not probed)"
else
  report WARN node-modules "web/node_modules missing under $WT — frontend type-check unavailable"
fi

# --- 5) python-imports ----------------------------------------------------------
# The worktree's .venv symlinks into the parent clone, so $WT/.venv/bin/python
# is valid whenever the clone is intact. PYTHONPATH=<worktree> is what makes
# `import api/rag/test.benchmark` resolve to THIS worktree's code (audit
# pr#19498's ModuleNotFoundError was exactly a missing PYTHONPATH).
PYBIN="$WT/.venv/bin/python"
[[ -x "$PYBIN" ]] || PYBIN="$(command -v python3 || true)"
if [[ -z "$PYBIN" || ! -d "$WT/api" ]]; then
  report SKIP python-imports "no interpreter or no api/ under $WT"
else
  if (cd "$WT" && PYTHONPATH="$WT" "$PYBIN" -c 'import api, rag' >/dev/null 2>&1); then
    report OK python-imports "\`import api, rag\` works with: cd <worktree> && PYTHONPATH=<worktree> .venv/bin/python"
  else
    report FAIL python-imports "\`import api, rag\` FAILED under $WT (PYTHONPATH=$WT) — the venv/deps are broken, NOT a repo bug; do not debug repo code for this"
  fi
  if [[ -d "$WT/test/benchmark" ]]; then
    if (cd "$WT" && PYTHONPATH="$WT" "$PYBIN" -c 'import test.benchmark' >/dev/null 2>&1); then
      report OK benchmark-import "\`import test.benchmark\` works with PYTHONPATH=<worktree> (test/ is a package); CLI: PYTHONPATH=<worktree> .venv/bin/python -m test.benchmark"
    elif (cd "$WT" && PYTHONPATH="$WT/test" "$PYBIN" -c 'import benchmark' >/dev/null 2>&1); then
      report OK benchmark-import "use PYTHONPATH=<worktree>/test + \`import benchmark\` (this branch's test/ is not a package)"
    else
      report WARN benchmark-import "test/benchmark present under $WT but not importable either way"
    fi
  else
    report SKIP benchmark-import "no test/benchmark under $WT"
  fi
fi

# --- 6) ports + ready-status cross-check ----------------------------------------
lst="$(ss -tln 2>/dev/null | grep -oE ':(9380|9383|9384|9222)\b' | tr -d ':' | sort -un | paste -sd, -)"
if [[ -n "$lst" ]]; then
  report OK ports "listening in this namespace: $lst"
else
  report WARN ports "none of 9380/9383/9384/9222 listening in this namespace"
fi
SF="${RAGFLOW_STATUS_FILE:-/tmp/ragflow-ready.status}"
if [[ -f "$SF" ]]; then
  st="$(cat "$SF" 2>/dev/null || true)"
  if grep -q 'all=READY' <<<"$st"; then
    if [[ -n "$lst" ]]; then
      report OK ready-status "status file READY and ports live"
    else
      report WARN ready-status "status file claims READY but NO app ports listen — STALE status, do not trust it"
    fi
  elif grep -q 'all=TIMEOUT' <<<"$st"; then
    report WARN ready-status "last launch reported TIMEOUT: $(tr '\n' ' ' <<<"$st" | head -c 160)"
  else
    report WARN ready-status "status file partial/in-progress: $(tr '\n' ' ' <<<"$st" | head -c 160)"
  fi
else
  report SKIP ready-status "no $SF yet"
fi

# --- 7) site-config completeness ----------------------------------------------
missing=""
for k in RAGFLOW_MAIN GITHUB_REPO FORK_REMOTE OWN_LOGIN MERGE_OWNER_LOGIN; do
  [[ -n "${!k}" ]] || missing="$missing $k"
done
if [[ -z "$missing" ]]; then
  report OK site-config "all required keys set (hfv.conf)"
else
  report FAIL site-config "missing required keys:$missing — fill them in hfv.conf (see hfv.conf.example)"
fi

printf 'PREFLIGHT_SUMMARY ok=%d fixed=%d warn=%d fail=%d skip=%d\n' "$ok" "$fixed" "$warn" "$fail" "$skip"
(( fail > 0 )) && exit 1 || exit 0
