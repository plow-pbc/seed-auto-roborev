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
    systemctl --user enable --now roborev-daemon.service
    log "systemd --user roborev-daemon.service enabled + started"
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
    launchctl bootout "gui/$(id -u)/co.plow.roborev-daemon" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    log "launchd co.plow.roborev-daemon loaded"
    ;;
  *) fail "unsupported OS: $(uname -s) — Linux + macOS only" ;;
esac

# --- 3. global post-commit hook (every repo, every commit) -------------------
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
