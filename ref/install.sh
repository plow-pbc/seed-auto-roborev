#!/usr/bin/env bash
# Deterministic implementation of SEED.md ## Dependencies for seed-roborev (v2).
# Idempotent + fail-loud. Wires always-on roborev on this machine. roborev owns
# `post-rewrite` (seeded by `roborev install-hook --force`); this SEED then
# OVERWRITES `post-commit` + writes `pre-commit` with its own wrappers that add
# the always-on confirmation lines roborev's stock silent hooks lack (the
# wrappers still call `roborev post-commit` / `roborev list`, so no
# double-enqueue). It also sets up the bits roborev doesn't itself: the review
# agent (claude-code), the daemon as a managed user-level service, the global
# core.hooksPath value, and the Claude Code PreToolUse[Bash] context bridge.
set -euo pipefail

HOOKS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/roborev/git-hooks"
SEED_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log()  { printf '==> %s\n' "$*"; }
fail() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# --- 1a. claude code CLI — auto-install via Anthropic's canonical user-scope
# installer if missing. (User-scope into $HOME/.local/share/claude, no sudo, no
# package manager — fits the SEED convention's "no auto system-wide installs".)
if ! command -v claude >/dev/null && [ ! -x "$HOME/.local/bin/claude" ]; then
  log "claude CLI missing — installing via https://claude.ai/install.sh"
  curl -fsSL https://claude.ai/install.sh | bash || fail "claude install failed"
fi
[ -x "$HOME/.local/bin/claude" ] || command -v claude >/dev/null || fail "claude CLI still missing post-install"

# --- 1b. roborev binary — auto-fetch from this SEED's GitHub release ---------
# Truly one-shot: install.sh downloads the platform-tagged binary from
#   https://github.com/plow-pbc/seed-roborev/releases/latest/download/roborev-<os>-<arch>
# To support a new platform: build roborev for it and upload the binary with
# that asset name (see README "Adding a platform").
ROBOREV="$(command -v roborev || true)"
[ -z "$ROBOREV" ] && [ -x "$HOME/.local/bin/roborev" ] && ROBOREV="$HOME/.local/bin/roborev"
if [ -z "$ROBOREV" ]; then
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)   asset="roborev-linux-x86_64" ;;
    Linux-aarch64)  asset="roborev-linux-aarch64" ;;
    Darwin-arm64)   asset="roborev-darwin-arm64" ;;
    Darwin-x86_64)  asset="roborev-darwin-x86_64" ;;
    *) fail "unsupported OS/arch for auto-install: $(uname -s)-$(uname -m)" ;;
  esac
  url="https://github.com/plow-pbc/seed-roborev/releases/latest/download/$asset"
  mkdir -p "$HOME/.local/bin"
  log "fetching $asset from $url"
  if curl -fsSL "$url" -o "$HOME/.local/bin/roborev.tmp"; then
    chmod +x "$HOME/.local/bin/roborev.tmp"
    mv "$HOME/.local/bin/roborev.tmp" "$HOME/.local/bin/roborev"
    ROBOREV="$HOME/.local/bin/roborev"
  else
    rm -f "$HOME/.local/bin/roborev.tmp"
    fail "could not fetch $asset (no binary published for $(uname -s)-$(uname -m) yet). To enable: build roborev for this platform and 'gh release upload v0.1 <path>#$asset -R plow-pbc/seed-roborev', then re-run."
  fi
fi
log "roborev: $ROBOREV"

# --- 2. review agent — claude-code (the working one; codex's OAuth was broken)
# default_agent is a GLOBAL key in roborev's config — must pass --global.
"$ROBOREV" config set --global default_agent claude-code
log "default_agent=claude-code"

# --- 3. daemon as a managed user-level service (idempotent on already-running)
case "$(uname -s)" in
  Linux)
    unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$unit_dir"
    cat > "$unit_dir/roborev-daemon.service" <<UNIT
[Unit]
Description=roborev review daemon
After=default.target

[Service]
# The daemon spawns agent CLIs (claude, codex, …). systemd --user starts the
# unit with a minimal PATH (no ~/.local/bin), so without this override the
# daemon would 503 with "no review agent available" even when `claude` IS
# installed user-scope. Mirror the macOS plist below.
Environment=PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$ROBOREV daemon run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable roborev-daemon.service   # durable across reboots
    # Always (re)start through our service so the daemon picks up the agent
    # we just set + any other config changes. A previously-running bare
    # `roborev daemon run` (or a stale daemon from a prior binary version)
    # would otherwise enqueue with stale defaults — restart is the robust fix.
    systemctl --user stop roborev-daemon.service 2>/dev/null || true
    pkill -f "roborev daemon run" 2>/dev/null || true
    sleep 1
    systemctl --user start roborev-daemon.service
    log "(re)started roborev-daemon.service with current config"
    # enable-linger needs polkit/root — surfaced, not auto-sudo'd.
    if ! loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes'; then
      log "NOTE (run yourself on a headless box so the daemon survives logout): sudo loginctl enable-linger $USER"
    fi
    ;;
  Darwin)
    plist="$HOME/Library/LaunchAgents/co.plow.roborev-daemon.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>co.plow.roborev-daemon</string>
  <key>ProgramArguments</key><array><string>$ROBOREV</string><string>daemon</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <!-- launchd LaunchAgents start with a minimal PATH (no ~/.local/bin),
       so without this the daemon 503s with "no review agent available" even
       when \`claude\` IS installed. Mirror the Linux systemd unit above. -->
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
PLIST
    # Always reload through launchd + kill any stale bare/prior-version daemon
    # so the (re)load picks up the agent we just set. Same rationale as Linux.
    launchctl bootout "gui/$(id -u)/co.plow.roborev-daemon" 2>/dev/null || true
    pkill -f "roborev daemon run" 2>/dev/null || true
    sleep 1
    launchctl bootstrap "gui/$(id -u)" "$plist"
    log "launchd co.plow.roborev-daemon (re)loaded with current config"
    ;;
  *) fail "unsupported OS: $(uname -s) — Linux + macOS only" ;;
esac

# --- 4. global core.hooksPath ------------------------------------------------
mkdir -p "$HOOKS_DIR"
current="$(git config --global core.hooksPath || true)"
if [ -z "$current" ]; then
  git config --global core.hooksPath "$HOOKS_DIR"
  log "set global core.hooksPath=$HOOKS_DIR"
elif [ "$current" = "$HOOKS_DIR" ]; then
  log "global core.hooksPath already=$HOOKS_DIR (idempotent)"
else
  fail "global core.hooksPath is already set to '$current' (not ours) — refusing to clobber. Either move roborev's hooks into '$current', or unset core.hooksPath and re-run."
fi

# --- 5. install hooks ---------------------------------------------------------
# Order matters: call roborev's install-hook first to seed post-rewrite (which
# roborev owns), then OVERWRITE post-commit + pre-commit with our versions that
# *always print a one-line confirmation* (Option A + Option B). Reason: silent
# success defeats observability — without the always-on lines, the operator
# can't tell "roborev is running" from "roborev is broken" until something fails.
( cd "$SEED_REPO" && "$ROBOREV" install-hook --force >/dev/null )

# Option A — post-commit: enqueue + print a confirmation line every commit, then
# chain to any repo-local post-commit. Replaces roborev's silent stock hook.
cat > "$HOOKS_DIR/post-commit" <<'HOOK'
#!/usr/bin/env bash
roborev="$(command -v roborev || echo "$HOME/.local/bin/roborev")"
if [ -x "$roborev" ]; then
  sha=$(git rev-parse --short HEAD 2>/dev/null || echo "?")
  if "$roborev" post-commit >/dev/null 2>&1; then
    agent=$("$roborev" config get default_agent 2>/dev/null | head -1)
    echo "roborev: enqueued review for $sha (${agent:-?})" >&2
  else
    echo "roborev: post-commit FAILED — review NOT enqueued for $sha" >&2
  fi
fi
git_dir="$(git rev-parse --git-dir 2>/dev/null || true)"
repo_hook="${git_dir:+$git_dir/hooks/post-commit}"
if [ -n "$repo_hook" ] && [ -x "$repo_hook" ] && ! [ "$repo_hook" -ef "${BASH_SOURCE[0]}" ]; then
  exec "$repo_hook" "$@"
fi
exit 0
HOOK
chmod +x "$HOOKS_DIR/post-commit"

# Option B — pre-commit: always print a one-line summary of open findings on
# THIS repo+branch (not just on findings>0), so the operator sees roborev is
# checking on every commit. Warn-only, never blocks. Chains to repo-local hook.
cat > "$HOOKS_DIR/pre-commit" <<'HOOK'
#!/usr/bin/env bash
roborev="$(command -v roborev || echo "$HOME/.local/bin/roborev")"
if [ -x "$roborev" ]; then
  n="$("$roborev" list --open --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
  if [ "${n:-0}" -gt 0 ]; then
    {
      echo "roborev: ${n} open review finding(s) on this branch — review before committing more:"
      "$roborev" list --open 2>/dev/null | head -20
      echo "(roborev show <id> for details; this is a non-blocking warning)"
    } >&2
  else
    echo "roborev: 0 open findings on this branch ✓" >&2
  fi
fi
git_dir="$(git rev-parse --git-dir 2>/dev/null || true)"
repo_hook="${git_dir:+$git_dir/hooks/pre-commit}"
if [ -n "$repo_hook" ] && [ -x "$repo_hook" ] && ! [ "$repo_hook" -ef "${BASH_SOURCE[0]}" ]; then
  exec "$repo_hook" "$@"
fi
exit 0
HOOK
chmod +x "$HOOKS_DIR/pre-commit"
log "wrote post-commit + pre-commit (always-on confirmation lines); post-rewrite owned by roborev"

# --- 6. Claude Code context bridge -------------------------------------------
# The git pre-commit hook (§5, Option B) prints findings to the TERMINAL for a
# human. This bridge injects open fail-verdict findings into a Claude Code
# agent's CONTEXT before it commits, AND hard-blocks the commit if roborev has
# gone missing. Installed to a seed-owned path (NOT ~/.claude/hooks, which is a
# symlink into the claude-config repo) + registered via ~/.claude/settings.json.
BRIDGE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/roborev/claude-hooks"
mkdir -p "$BRIDGE_DIR"
install -m 0755 "$SEED_REPO/ref/roborev-pre-commit-context.py" "$BRIDGE_DIR/roborev-pre-commit-context.py"
log "installed Claude bridge -> $BRIDGE_DIR/roborev-pre-commit-context.py"

SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
command -v jq >/dev/null || fail "jq required to merge the Claude bridge into $SETTINGS"
bridge_cmd="$BRIDGE_DIR/roborev-pre-commit-context.py"
tmp_settings="$(mktemp "${SETTINGS}.XXXXXX")"
# Idempotent append-and-dedupe — mirrors claude-config's justfile merge so other
# PreToolUse hooks (and all other settings) are preserved; re-running dedupes.
jq --arg cmd "$bridge_cmd" '
  def dedupe_keep_order: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
  .hooks = (.hooks // {})
  | .hooks.PreToolUse = (((.hooks.PreToolUse // []) + [
      {matcher:"Bash", hooks:[{type:"command", command:$cmd}]}
    ]) | dedupe_keep_order)
' "$SETTINGS" > "$tmp_settings"
mv "$tmp_settings" "$SETTINGS"
chmod 600 "$SETTINGS"
log "merged PreToolUse[Bash] roborev bridge into $SETTINGS"

log "seed-roborev install complete — run ref/verify.sh to confirm."
