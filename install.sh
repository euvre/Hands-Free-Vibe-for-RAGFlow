#!/usr/bin/env bash
# install.sh — one-shot installer for hands-free-vibe.
#
# Covers: system prerequisites (docker / node / chrome), the cline CLI, the
# MCP toolbelt (downloaded from the official npm registry, then wrapped),
# site configs from the shipped templates, the hfv-task docker image, and the
# systemd user units.
#
# Idempotent: safe to re-run; each step skips what is already in place.
#   bash install.sh            # everything
#   bash install.sh --check    # verify only, change nothing
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

ok=0; warn=0; fail=0
say()  { printf '%s\n' "$*"; }
pass() { ok=$((ok+1));   say "  OK    $*"; }
note() { warn=$((warn+1)); say "  WARN  $*"; }
bad()  { fail=$((fail+1)); say "  FAIL  $*"; }
step() { say; say "== $*"; }

# ---------------------------------------------------------------- system ----
step "system prerequisites"
for cmd in docker git python3 node npm systemctl; do
  if command -v "$cmd" >/dev/null 2>&1; then pass "$cmd"; else bad "$cmd missing — install it with your distro's package manager"; fi
done
if command -v uv >/dev/null 2>&1; then pass "uv"; else note "uv missing — the ragflow worktree venv needs it: https://docs.astral.sh/uv/"; fi
if command -v google-chrome >/dev/null 2>&1; then pass "google-chrome"; else note "google-chrome missing — chrome-devtools-mcp needs it (lark-mcp's token store also wants a desktop session)"; fi
if docker info >/dev/null 2>&1; then pass "docker daemon reachable"; else bad "docker daemon unreachable (permission? add yourself to the docker group)"; fi

# ------------------------------------------------------------- node + cli ---
step "cline CLI (npm-global prefix)"
NPMG="$HOME/.npm-global"
if [[ $CHECK_ONLY -eq 0 ]]; then
  if [[ "$(npm config get prefix 2>/dev/null)" != "$NPMG" ]]; then
    mkdir -p "$NPMG"
    npm config set prefix "$NPMG" && say "  npm prefix -> $NPMG"
  fi
  case ":$PATH:" in *":$NPMG/bin:"*) ;; *) note "add $NPMG/bin to PATH (e.g. in ~/.bashrc)";; esac
fi
if command -v cline >/dev/null 2>&1 || [[ -x "$NPMG/bin/cline" ]]; then
  pass "cline $(cline --version 2>/dev/null | head -1)"
elif [[ $CHECK_ONLY -eq 0 ]]; then
  npm install -g cline && pass "cline installed" || bad "npm install -g cline failed"
else
  bad "cline not installed"
fi

# ------------------------------------------------------------- MCP servers --
step "MCP toolbelt (official npm registry, then wrapped)"
MCP_PKGS="@larksuiteoapi/lark-mcp chrome-devtools-mcp"
for pkg in $MCP_PKGS; do
  if [[ -d "$NPMG/lib/node_modules/$pkg" ]]; then
    pass "$pkg present"
  elif [[ $CHECK_ONLY -eq 0 ]]; then
    npm install -g "$pkg" && pass "$pkg installed" || bad "npm install -g $pkg failed"
  else
    bad "$pkg not installed"
  fi
done
# the filesystem server runs fine via npx — just warm the cache
if [[ $CHECK_ONLY -eq 0 ]]; then
  npx -y @modelcontextprotocol/server-filesystem --help >/dev/null 2>&1 \
    && pass "@modelcontextprotocol/server-filesystem (npx cache warm)" \
    || note "filesystem server npx warm-up failed (it will retry on first use)"
fi

# wrappers: generated for THIS machine (the templates carry no host paths)
step "MCP wrappers -> ~/bin"
mkdir -p "$HOME/bin"
for w in lark-mcp-wrapper.sh chrome-devtools-mcp-wrapper.sh; do
  src="$DIR/mcp/wrappers/$w"
  dst="$HOME/bin/$w"
  if [[ ! -f "$src" ]]; then note "template $src missing"; continue; fi
  if [[ $CHECK_ONLY -eq 0 ]]; then
    sed "s|/home/inf|$HOME|g" "$src" > "$dst" && chmod +x "$dst" && pass "$dst"
  else
    [[ -x "$dst" ]] && pass "$dst" || note "$dst not installed"
  fi
done
note "point cline_mcp_settings.json at the ~/bin wrappers (see mcp/README.md)"

# ------------------------------------------------------------- site config --
step "site configuration (gitignored, never committed)"
for pair in "hfv.conf.example hfv.conf" "issues/config.example issues/config"; do
  tmpl="${pair%% *}"; tgt="${pair##* }"
  if [[ -f "$DIR/$tgt" ]]; then
    pass "$tgt exists"
  elif [[ $CHECK_ONLY -eq 0 ]]; then
    cp "$DIR/$tmpl" "$DIR/$tgt" && note "$tgt created from template — EDIT it now (real values required)"
  else
    bad "$tgt missing"
  fi
done
if [[ ! -f "$DIR/model-keys.json" ]]; then
  note "model-keys.json missing — add your LLM keys: {\"<profile>\": [\"<key>\", ...]} (see tools/model-profile.py)"
fi

# ------------------------------------------------------------- docker -------
step "docker images"
if docker images -q hfv-task:latest >/dev/null 2>&1 && [[ -n "$(docker images -q hfv-task:latest)" ]]; then
  pass "hfv-task:latest (golden) present"
elif [[ $CHECK_ONLY -eq 0 ]]; then
  say "  building hfv-task:base from docker/Dockerfile.task (a few minutes)..."
  if docker build -f "$DIR/docker/Dockerfile.task" -t hfv-task:base "$DIR/docker/"; then
    pass "hfv-task:base built"
    # The build cache is the one unbounded docker growth on this host — prune
    # layers older than 72h right after every build (fresh layers stay, so a
    # re-run keeps its cache hits). The weekly docker-prune timer backstops
    # ad-hoc builds.
    bash "$DIR/framework/docker-prune.sh"
    note "golden bootstrap still needed: run one throwaway container, ragflow-up + log in once, then 'docker commit <ctr> hfv-task:latest' (see README)"
  else
    bad "hfv-task:base build failed"
  fi
else
  bad "hfv-task:latest missing"
fi

# ------------------------------------------------------------- systemd ------
step "systemd user units"
if [[ $CHECK_ONLY -eq 0 ]]; then
  mkdir -p "$HOME/.config/systemd/user"
  cp "$DIR"/deploy/systemd/cline-feishu-* "$HOME/.config/systemd/user/" \
    && systemctl --user daemon-reload \
    && pass "units installed ($(ls "$DIR"/deploy/systemd/ | wc -l) files), daemon reloaded" \
    || bad "unit install failed"
  note "enable what you want: hfv on (all lines at 1 instance) / hfv scale <line> <n>"
else
  [[ -f "$HOME/.config/systemd/user/cline-feishu-triage@.service" ]] && pass "units installed" || bad "units missing"
fi

# ------------------------------------------------------ git exclude ---------
step "git exclude (runtime symlink never staged)"
# The framework symlinks ragflow_deps/nltk_data (an absolute host path) into
# task worktrees to provide runtime assets; the repo's `nltk_data/` gitignore
# covers only real directories, so `git add -A` sweeps the symlink into
# commits. One entry in the clone's shared info/exclude covers every worktree.
RAGFLOW_MAIN_VAL="$(source "$DIR/config.sh" >/dev/null 2>&1; printf '%s' "$RAGFLOW_MAIN")"
if [[ -n "$RAGFLOW_MAIN_VAL" && -d "$RAGFLOW_MAIN_VAL/.git" ]]; then
  EX="$RAGFLOW_MAIN_VAL/.git/info/exclude"
  if grep -q '^/ragflow_deps/nltk_data$' "$EX" 2>/dev/null; then
    pass "info/exclude covers /ragflow_deps/nltk_data"
  elif [[ $CHECK_ONLY -eq 0 ]]; then
    printf '\n# hfv: framework-created runtime symlink; never stage it\n/ragflow_deps/nltk_data\n' >> "$EX" \
      && pass "added /ragflow_deps/nltk_data to $EX" || note "could not write $EX"
  else
    note "$EX missing the /ragflow_deps/nltk_data entry"
  fi
else
  note "RAGFLOW_MAIN unset or not a clone yet — add /ragflow_deps/nltk_data to <clone>/.git/info/exclude later"
fi

# ------------------------------------------------------------- summary ------
say
say "== summary: ok=$ok warn=$warn fail=$fail"
if [[ $fail -gt 0 ]]; then
  say "fix the FAIL items above, then re-run: bash install.sh"
  exit 1
fi
say "next: edit hfv.conf + issues/config + model-keys.json, then 'hfv on' and 'hfv scale issue 1'."
