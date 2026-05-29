#!/usr/bin/env bash
# Deterministic implementation of SEED.md ## Verify for seed-roborev.
# Read-only on installed state, EXCEPT an ephemeral throwaway git repo it
# creates + one test commit there to prove the global hook enqueues a review —
# both cleaned up before exit. Fail-loud: any miss -> nonzero exit.
set -euo pipefail

HOOKS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/roborev/git-hooks"
fails=0
ok()  { printf 'OK   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*" >&2; fails=$((fails+1)); }

ROBOREV="$(command -v roborev || true)"
[ -z "$ROBOREV" ] && [ -x "$HOME/.local/bin/roborev" ] && ROBOREV="$HOME/.local/bin/roborev"

# v-binary
[ -n "$ROBOREV" ] && ok "v-binary: roborev at $ROBOREV" || bad "v-binary: roborev not found on PATH or ~/.local/bin"

# v-daemon — daemon answers (roborev list round-trips through the daemon).
if [ -n "$ROBOREV" ] && "$ROBOREV" list >/dev/null 2>&1; then
  ok "v-daemon: roborev daemon reachable"
else
  bad "v-daemon: roborev daemon not reachable — is roborev-daemon (systemd --user) / co.plow.roborev-daemon (launchd) running?"
fi

# v-hookspath — global core.hooksPath is ours + post-commit is executable.
hp="$(git config --global core.hooksPath || true)"
[ "$hp" = "$HOOKS_DIR" ] && ok "v-hookspath: core.hooksPath=$HOOKS_DIR" || bad "v-hookspath: core.hooksPath='$hp' (expected $HOOKS_DIR)"
[ -x "$HOOKS_DIR/post-commit" ] && ok "v-hook-exec: post-commit executable" || bad "v-hook-exec: $HOOKS_DIR/post-commit missing or not executable"
[ -x "$HOOKS_DIR/pre-commit" ]  && ok "v-precommit: pre-commit executable"  || bad "v-precommit: $HOOKS_DIR/pre-commit missing or not executable"

# v-enqueue — an ephemeral repo + commit actually enqueues a roborev job
# (proves the global post-commit fires for an arbitrary repo). Cleaned up.
if [ -n "$ROBOREV" ] && [ "$hp" = "$HOOKS_DIR" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  (
    cd "$tmp"
    git init -q
    git config user.email seed-verify@local
    git config user.name  seed-verify
    echo seed-verify > probe.txt
    git add probe.txt
    git commit -q -m "seed-roborev verify probe"
  )
  sleep 1  # let the daemon ingest the enqueue
  n="$(cd "$tmp" && "$ROBOREV" list --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
  if [ "${n:-0}" -gt 0 ]; then
    ok "v-enqueue: commit enqueued a roborev job (post-commit fired)"
  else
    bad "v-enqueue: commit did NOT enqueue a roborev job — the global post-commit isn't firing"
  fi
else
  bad "v-enqueue: skipped — binary or core.hooksPath precondition failed above"
fi

[ "$fails" -eq 0 ] || { printf '\n%d check(s) FAILED\n' "$fails" >&2; exit 1; }
printf '\nseed-roborev: all checks passed\n'
