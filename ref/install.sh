#!/usr/bin/env bash
# Deterministic implementation of SEED.md ## Dependencies for seed-roborev.
# Idempotent + fail-loud. Wires always-on roborev on this machine:
#   1. assert the roborev binary is present (external dep — never auto-installed)
#   2. install + start the roborev daemon as a USER-level service
#      (systemd --user on Linux / launchd LaunchAgent on macOS — no sudo)
#   3. set a global git post-commit hook (core.hooksPath) that enqueues a
#      roborev review after every commit, chaining to any repo-local
#      post-commit so a repo's own hook isn't silently dropped.
set -euo pipefail

HOOKS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/roborev/git-hooks"
log()  { printf '==> %s\n' "$*"; }
fail() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# --- 1. roborev binary (external dependency; surfaced, never auto-installed) --
ROBOREV="$(command -v roborev || true)"
[ -z "$ROBOREV" ] && [ -x "$HOME/.local/bin/roborev" ] && ROBOREV="$HOME/.local/bin/roborev"
[ -n "$ROBOREV" ] || fail "roborev binary not found on PATH or ~/.local/bin — install roborev first (https://github.com/plow-pbc/roborev), then re-run."
log "roborev: $ROBOREV"

# --- 2. daemon as a managed user-level service -------------------------------
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
    # Idempotent on already-running: if a roborev daemon is already serving
    # (e.g. a bare `roborev daemon run`), don't start a second instance that
    # would collide on the server port — just move on. The enabled unit takes
    # over on the next reboot/restart.
    if systemctl --user is-active --quiet roborev-daemon.service; then
      log "roborev-daemon.service already active"
    elif "$ROBOREV" list >/dev/null 2>&1; then
      log "a roborev daemon is already running (not via this service) — leaving it; the enabled unit manages it after next reboot. To switch now: pkill -f 'roborev daemon run' && systemctl --user start roborev-daemon.service"
    else
      systemctl --user start roborev-daemon.service
      log "started roborev-daemon.service"
    fi
    # Linger lets the user service survive logout (matters on headless/SSH
    # boxes). enable-linger needs polkit/root — SURFACE it, don't auto-sudo.
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
    # Idempotent on already-running: if a roborev daemon is already serving,
    # don't bootstrap a colliding LaunchAgent — leave the running one. Otherwise
    # (re)load the agent so it starts now and on every login.
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

# --- 3. global post-commit + pre-commit hooks (every repo, every commit) -----
mkdir -p "$HOOKS_DIR"
cat > "$HOOKS_DIR/post-commit" <<'HOOK'
#!/usr/bin/env bash
# Global post-commit (git core.hooksPath): enqueue a roborev review after every
# commit, then chain to the repo's own post-commit if it has one — core.hooksPath
# replaces .git/hooks wholesale, so a repo-local hook must be called explicitly.
roborev="$(command -v roborev || echo "$HOME/.local/bin/roborev")"
[ -x "$roborev" ] && "$roborev" post-commit >/dev/null 2>&1 || true
# Find the repo-LOCAL hook via --git-dir (literal .git/hooks), NOT
# `--git-path hooks/...` — the latter resolves through core.hooksPath and would
# just return this global hook, so the chain would never fire.
git_dir="$(git rev-parse --git-dir 2>/dev/null || true)"
repo_hook="${git_dir:+$git_dir/hooks/post-commit}"
if [ -n "$repo_hook" ] && [ -x "$repo_hook" ] && ! [ "$repo_hook" -ef "${BASH_SOURCE[0]}" ]; then
  exec "$repo_hook" "$@"
fi
HOOK
chmod +x "$HOOKS_DIR/post-commit"

# pre-commit: surface OPEN roborev findings before the next commit, so whichever
# agent (claude/codex) or human is about to commit sees them first. Warn-only
# (never blocks) — the hook's stderr lands in the `git commit` tool output the
# agent reads. Agent-agnostic on purpose: codex has no Claude-style PreToolUse
# hook, so a git-level pre-commit is the only check that covers it too. Chains
# to any repo-local pre-commit.
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

current="$(git config --global core.hooksPath || true)"
if [ -z "$current" ]; then
  git config --global core.hooksPath "$HOOKS_DIR"
  log "set global core.hooksPath=$HOOKS_DIR"
elif [ "$current" = "$HOOKS_DIR" ]; then
  log "global core.hooksPath already=$HOOKS_DIR (idempotent)"
else
  fail "global core.hooksPath is already set to '$current' (not ours) — refusing to clobber. Either move roborev's post-commit ($HOOKS_DIR/post-commit) into '$current', or unset core.hooksPath and re-run."
fi

log "seed-roborev install complete — run ref/verify.sh to confirm."
