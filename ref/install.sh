#!/usr/bin/env bash
# Deterministic implementation of SEED.md ## Dependencies for seed-roborev (v2).
# Idempotent + fail-loud. Wires always-on roborev on this machine in the DRY-est
# way the design admits — *roborev owns its own git hooks* (post-commit +
# post-rewrite) in core.hooksPath, so this SEED does NOT duplicate them. It
# only adds the missing pre-commit results-check, plus the bits roborev doesn't
# set up by itself: the review agent (claude-code), the daemon as a managed
# user-level service, and the global core.hooksPath value.
set -euo pipefail

HOOKS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/roborev/git-hooks"
SEED_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log()  { printf '==> %s\n' "$*"; }
fail() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# --- 1. roborev binary (external dep; surfaced, never auto-installed) --------
ROBOREV="$(command -v roborev || true)"
[ -z "$ROBOREV" ] && [ -x "$HOME/.local/bin/roborev" ] && ROBOREV="$HOME/.local/bin/roborev"
[ -n "$ROBOREV" ] || fail "roborev binary not found on PATH or ~/.local/bin — install roborev first (https://github.com/plow-pbc/roborev), then re-run."
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
ExecStart=$ROBOREV daemon run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable roborev-daemon.service   # durable across reboots
    # If a roborev daemon is already serving (e.g. a bare `roborev daemon run`),
    # don't start a second instance that would collide on the server port.
    if systemctl --user is-active --quiet roborev-daemon.service; then
      log "roborev-daemon.service already active"
    elif "$ROBOREV" list >/dev/null 2>&1; then
      log "a roborev daemon is already running (not via this service) — leaving it; the enabled unit manages it after next reboot. To switch now: pkill -f 'roborev daemon run' && systemctl --user start roborev-daemon.service"
    else
      systemctl --user start roborev-daemon.service
      log "started roborev-daemon.service"
    fi
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
</dict>
</plist>
PLIST
    if "$ROBOREV" list >/dev/null 2>&1; then
      log "a roborev daemon is already running — LaunchAgent written for boot durability, not force-(re)loaded"
    else
      launchctl bootout "gui/$(id -u)/co.plow.roborev-daemon" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$plist"
      log "launchd co.plow.roborev-daemon loaded"
    fi
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

# --- 5. delegate post-commit + post-rewrite to roborev (DRY: one source) -----
# roborev's install-hook is core.hooksPath-aware when run inside any git repo:
# with core.hooksPath set globally above, it writes the hooks to that dir, not
# to .git/hooks/. --force makes the upgrade-from-v1 case clean (overwrites any
# prior content, no merging). Run it from the SEED clone — any git repo works.
( cd "$SEED_REPO" && "$ROBOREV" install-hook --force >/dev/null )
log "roborev install-hook: post-commit + post-rewrite owned by roborev"

# --- 6. pre-commit results-check (the only hook roborev doesn't provide) -----
# Warn-only (never blocks); chains to any repo-local pre-commit. Agent-agnostic
# (codex has no Claude-style pre-tool hook, so a git-level hook is the only
# check that reaches it too) — stderr lands in the `git commit` tool output
# whichever agent (claude/codex/human) ran the commit sees.
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
log "wrote pre-commit (results-check; roborev provides no pre-commit of its own)"

log "seed-roborev install complete — run ref/verify.sh to confirm."
