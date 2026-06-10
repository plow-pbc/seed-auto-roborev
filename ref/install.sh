#!/usr/bin/env bash
# Deterministic implementation of SEED.md ## Dependencies for seed-auto-roborev (v3).
# Idempotent + fail-loud. Wires always-on roborev on this machine. roborev owns
# its own git hooks (`post-commit` enqueues a review every commit, `post-rewrite`
# remaps on rebase/amend) via `roborev install-hook --force` — the seed then wraps
# post-commit to skip pytest fixture repos (§5). This SEED sets up
# the bits roborev doesn't itself: the review agent (claude-code), the daemon as
# a managed user-level service, the global core.hooksPath value, and the three
# Claude Code PreToolUse[Bash] hooks (context bridge + pre-push gate + pre-checkout
# gate) — the surfaces that bring findings to the *agent*, where it can act on them.
set -euo pipefail

HOOKS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/roborev/git-hooks"
SEED_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log()  { printf '==> %s\n' "$*"; }
fail() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
# Portable sha256 of a file (Linux has sha256sum; macOS has shasum, not sha256sum).
sha256() {
  if command -v sha256sum >/dev/null;  then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null;    then shasum -a 256 "$1" | cut -d' ' -f1
  else fail "need sha256sum or shasum to verify the roborev binary"; fi
}

# --- 1a. claude code CLI — auto-install via Anthropic's canonical user-scope
# installer if missing. (User-scope into $HOME/.local/share/claude, no sudo, no
# package manager — fits the SEED convention's "no auto system-wide installs".)
if ! command -v claude >/dev/null && [ ! -x "$HOME/.local/bin/claude" ]; then
  log "claude CLI missing — installing via https://claude.ai/install.sh"
  curl -fsSL https://claude.ai/install.sh | bash || fail "claude install failed"
fi
[ -x "$HOME/.local/bin/claude" ] || command -v claude >/dev/null || fail "claude CLI still missing post-install"

# --- 1b. roborev binary — auto-fetch from this SEED's GitHub release ---------
# Truly one-shot: install.sh downloads a PINNED, checksum-verified binary from
#   https://github.com/plow-pbc/seed-auto-roborev/releases/download/$ROBOREV_TAG/roborev-<os>-<arch>
# The tag + per-asset sha256 are committed here (reviewed in git), so a tampered
# or silently-swapped release asset fails the checksum gate before it's ever run
# — not `latest`, which would pull whatever bytes are newest with no tripwire.
# To bump the version or add a platform: build/obtain the binary, upload it to a
# release, then update $ROBOREV_TAG / the sha256 below (see README "Adding a
# platform"). Get a checksum with: shasum -a 256 <file>  (or sha256sum).
ROBOREV_TAG="v0.1"
# Install-time resolution prefers PATH then the pinned path. NOTE: the post-commit
# wrapper (ref/post-commit) deliberately resolves pinned-FIRST, mirroring roborev's
# own generated stub — don't "align" the two; the hook's order is the stub contract.
ROBOREV="$(command -v roborev || true)"
[ -z "$ROBOREV" ] && [ -x "$HOME/.local/bin/roborev" ] && ROBOREV="$HOME/.local/bin/roborev"
if [ -z "$ROBOREV" ]; then
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)   asset="roborev-linux-x86_64";  sha="e4af0de02926cf0d3fc38176bfc096dbef90807418274655507440b3945f1184" ;;
    Linux-aarch64)  asset="roborev-linux-aarch64"; sha="fd04959e45a46c8caeafb0fa4954f0abb8c4b041e829c1c3d0163d4cbf28c48a" ;;
    Darwin-arm64)   asset="roborev-darwin-arm64";  sha="ebaba77e6a62670cd6bcc793fd484eda64b8ecebb1d2f9997e950363c37ab070" ;;
    *) fail "no pinned roborev binary for $(uname -s)-$(uname -m) at $ROBOREV_TAG. To add one: build roborev, 'gh release upload $ROBOREV_TAG <path>#roborev-<os>-<arch> -R plow-pbc/seed-auto-roborev', add its sha256 to ref/install.sh, then re-run." ;;
  esac
  url="https://github.com/plow-pbc/seed-auto-roborev/releases/download/$ROBOREV_TAG/$asset"
  mkdir -p "$HOME/.local/bin"
  log "fetching $asset ($ROBOREV_TAG) from $url"
  curl -fsSL "$url" -o "$HOME/.local/bin/roborev.tmp" \
    || { rm -f "$HOME/.local/bin/roborev.tmp"; fail "could not fetch $asset from $url (is it published at $ROBOREV_TAG?)."; }
  got="$(sha256 "$HOME/.local/bin/roborev.tmp")"
  if [ "$got" != "$sha" ]; then
    rm -f "$HOME/.local/bin/roborev.tmp"
    fail "checksum mismatch for $asset: expected $sha, got $got — refusing to install (tampered or stale release asset). Verify the release, then update the sha256 in ref/install.sh if the bump is intentional."
  fi
  chmod +x "$HOME/.local/bin/roborev.tmp"
  mv "$HOME/.local/bin/roborev.tmp" "$HOME/.local/bin/roborev"
  ROBOREV="$HOME/.local/bin/roborev"
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
# daemon would 503 with "no review agent available" even when \`claude\` IS
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

# --- 5. install git hooks + seed post-commit wrapper --------------------------
# With core.hooksPath already set (§4), `roborev install-hook` writes BOTH
# post-commit (enqueue a review every commit — point 1 of the seed's purpose)
# and post-rewrite (remap on rebase/amend) into $HOOKS_DIR; verified to honor
# core.hooksPath rather than writing to .git/hooks/. roborev owns post-rewrite;
# the seed then wraps post-commit (below) with a pytest-fixture guard so a global
# core.hooksPath doesn't enqueue throwaway reviews from test-suite temp repos.
# (post-rewrite stays unguarded: its job is to remap existing reviews on rebase/
# amend, a no-op in a pytest repo where post-commit enqueued nothing.)
# The agent-facing "this commit isn't being reviewed" signal lives in the Claude
# context bridge (§6, fires into the agent's context on a missing binary);
# `verify.sh` is the everyone-covered on-demand check.
# Remove orphaned wrappers from a prior seed version: the old installer wrote a
# SEED-owned `pre-commit` + `roborev-hooklib.sh` the current seed no longer
# manages. `install-hook --force` overwrites post-commit/post-rewrite but would
# leave these two behind — where the stale `pre-commit` keeps firing on every
# commit (sourcing the equally-stale lib). Clean them so an upgrade converges.
rm -f "$HOOKS_DIR/pre-commit" "$HOOKS_DIR/roborev-hooklib.sh"
( cd "$SEED_REPO" && "$ROBOREV" install-hook --force >/dev/null )
log "installed roborev git hooks (post-commit + post-rewrite) -> $HOOKS_DIR"

# `install-hook` (above) wrote an unguarded post-commit stub. Overwrite it with
# the seed's wrapper (ref/post-commit) so commits inside pytest fixture repos
# (paths under <tmp>/pytest-of-<user>/, created + committed by test suites the
# global core.hooksPath also covers) don't enqueue throwaway reviews. Re-applied
# after every `install-hook --force`, so re-installs converge on the guarded hook.
install -m 0755 "$SEED_REPO/ref/post-commit" "$HOOKS_DIR/post-commit"
log "applied pytest-fixture guard to post-commit hook -> $HOOKS_DIR/post-commit"

# --- 6. Claude Code hooks: context bridge + pre-push gate + pre-checkout gate --
# The post-commit hook (§5) reviews every commit but its findings have
# no native path into an agent's context. These three Claude Code PreToolUse[Bash]
# hooks bring those findings to the AGENT, at the surfaces where it can act:
#   - the bridge WARNS before `git commit` (injects open fail-verdict findings
#     into context, or a broken-install warning) — context-only, never denies;
#   - the push gate DENIES a `git push` while the CURRENT branch has open fail-
#     verdict reviews (after waiting for in-flight ones) — stops findings leaving
#     the machine unseen;
#   - the checkout gate DENIES a `git checkout`/`git switch` to ANOTHER branch
#     while the branch being LEFT has open fail-verdict reviews — stops findings
#     getting stranded on a branch you switch away from (the enforcement half of
#     "drain before switching"; file restores are NOT gated).
# All import the shared `_roborev_hooklib.py` (one parser + one definition of an
# outstanding finding). Installed to a seed-owned path (NOT ~/.claude/hooks,
# which is a symlink into the claude-config repo) + registered in settings.json.
BRIDGE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/roborev/claude-hooks"
mkdir -p "$BRIDGE_DIR"
install -m 0644 "$SEED_REPO/ref/_roborev_hooklib.py"           "$BRIDGE_DIR/_roborev_hooklib.py"
install -m 0755 "$SEED_REPO/ref/roborev-pre-commit-context.py" "$BRIDGE_DIR/roborev-pre-commit-context.py"
install -m 0755 "$SEED_REPO/ref/roborev-pre-push-gate.py"      "$BRIDGE_DIR/roborev-pre-push-gate.py"
install -m 0755 "$SEED_REPO/ref/roborev-pre-checkout-gate.py"  "$BRIDGE_DIR/roborev-pre-checkout-gate.py"
# `roborev list --all` seed helper — the machine-wide open-FAIL backlog view the
# upstream CLI lacks. Installed alongside the hooks (it imports the same shared
# `_roborev_hooklib` for the open-finding definition) so the agent can run the
# cross-branch sweep by hand: `python3 $BRIDGE_DIR/roborev-list-all.py`.
install -m 0755 "$SEED_REPO/ref/roborev-list-all.py"          "$BRIDGE_DIR/roborev-list-all.py"
log "installed Claude hooks (commit bridge + pre-push gate + pre-checkout gate + backlog helper + shared lib) -> $BRIDGE_DIR"

SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
command -v jq >/dev/null || fail "jq required to merge the Claude hooks into $SETTINGS"
bridge_cmd="$BRIDGE_DIR/roborev-pre-commit-context.py"
gate_cmd="$BRIDGE_DIR/roborev-pre-push-gate.py"
checkout_cmd="$BRIDGE_DIR/roborev-pre-checkout-gate.py"
tmp_settings="$(mktemp "${SETTINGS}.XXXXXX")"
# Idempotent append-and-dedupe — mirrors claude-config's justfile merge so other
# PreToolUse hooks (and all other settings) are preserved; re-running dedupes.
# The push gate carries timeout:660 — 60s over its 600s in-flight wait — so its
# deny JSON still emits before Claude Code's default 60s timeout would kill it.
# The checkout gate does NOT wait (no in-flight stall), so it takes the default
# timeout — keeping its registration a bare command entry.
jq --arg bridge "$bridge_cmd" --arg gate "$gate_cmd" --arg checkout "$checkout_cmd" '
  def dedupe_keep_order: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
  .hooks = (.hooks // {})
  | .hooks.PreToolUse = (((.hooks.PreToolUse // []) + [
      {matcher:"Bash", hooks:[{type:"command", command:$bridge}]},
      {matcher:"Bash", hooks:[{type:"command", command:$gate, timeout:660}]},
      {matcher:"Bash", hooks:[{type:"command", command:$checkout}]}
    ]) | dedupe_keep_order)
' "$SETTINGS" > "$tmp_settings"
# Write THROUGH a possibly-symlinked settings.json — the `>` redirect follows
# the symlink and updates its target, so a dotfiles-managed link isn't severed
# (which an `mv` would do). Portable: no GNU-only `readlink -f` (BSD/macOS lacks it).
cat "$tmp_settings" > "$SETTINGS"
rm -f "$tmp_settings"
chmod 600 "$SETTINGS"
log "merged PreToolUse[Bash] roborev bridge + pre-push gate + pre-checkout gate into $SETTINGS"

# --- 7. Claude Code skill: roborev usage + the review-loop contract ----------
# The §6 hooks bring findings TO the agent; this skill teaches the agent how to
# USE roborev and the workflow contract it serves (let reviews finish before
# push/switch, fix or `roborev close` fail-verdict findings, never push over or
# switch away from an unread verdict=F). A skill is Claude Code's native home for "how to use tool X + its
# loop" and auto-activates on commit/push/checkout/switch triggers. Installed to ~/.claude/skills
# as a real dir: claude-config's `just install` only prunes ITS OWN repo-owned
# skill symlinks and preserves user-owned entries, so this coexists collision-free.
SKILL_DIR="$HOME/.claude/skills/roborev"
mkdir -p "$SKILL_DIR"
install -m 0644 "$SEED_REPO/skills/roborev/SKILL.md" "$SKILL_DIR/SKILL.md"
log "installed roborev usage skill -> $SKILL_DIR/SKILL.md"

log "seed-auto-roborev install complete — run ref/verify.sh to confirm."
