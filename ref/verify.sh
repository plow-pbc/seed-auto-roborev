#!/usr/bin/env bash
# Deterministic implementation of SEED.md ## Verify for seed-roborev (v2).
# Read-only on installed state, EXCEPT one ephemeral throwaway git repo it
# creates + a single commit there to prove the global hook enqueues AND the
# review actually completes via the configured agent (claude-code). Cleaned up
# before exit. Fail-loud: any miss → nonzero.
set -euo pipefail

HOOKS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/roborev/git-hooks"
fails=0
ok()  { printf 'OK   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*" >&2; fails=$((fails+1)); }

ROBOREV="$(command -v roborev || true)"
[ -z "$ROBOREV" ] && [ -x "$HOME/.local/bin/roborev" ] && ROBOREV="$HOME/.local/bin/roborev"

# ^v-binary
[ -n "$ROBOREV" ] && ok "^v-binary: roborev at $ROBOREV" || bad "^v-binary: roborev not found on PATH or ~/.local/bin"

# ^v-daemon — daemon round-trips through `roborev list`.
if [ -n "$ROBOREV" ] && "$ROBOREV" list >/dev/null 2>&1; then
  ok "^v-daemon: roborev daemon reachable"
else
  bad "^v-daemon: roborev daemon not reachable — is roborev-daemon (systemd --user) / co.plow.roborev-daemon (launchd) running?"
fi

# ^v-agent — the working agent (codex's OAuth was broken; claude-code is OK).
agent="$([ -n "$ROBOREV" ] && "$ROBOREV" config get default_agent 2>/dev/null || echo '?')"
[ "$agent" = "claude-code" ] && ok "^v-agent: default_agent=$agent" || bad "^v-agent: default_agent='$agent' (expected claude-code)"

# ^v-hookspath — core.hooksPath is ours + both hooks executable.
hp="$(git config --global core.hooksPath || true)"
[ "$hp" = "$HOOKS_DIR" ] && ok "^v-hookspath: core.hooksPath=$HOOKS_DIR" || bad "^v-hookspath: core.hooksPath='$hp' (expected $HOOKS_DIR)"
[ -x "$HOOKS_DIR/post-commit" ] && ok "^v-postcommit: post-commit executable (owned by roborev)" || bad "^v-postcommit: $HOOKS_DIR/post-commit missing or not executable"
[ -x "$HOOKS_DIR/pre-commit" ]  && ok "^v-precommit:  pre-commit executable"  || bad "^v-precommit: $HOOKS_DIR/pre-commit missing or not executable"

# ^v-review — ephemeral repo + commit must enqueue a claude-code job that
# actually completes (status terminal: done/passed/failed); end-to-end proof
# of "review after every commit" via the configured agent.
if [ -n "$ROBOREV" ] && [ "$hp" = "$HOOKS_DIR" ] && [ "$agent" = "claude-code" ]; then
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
  sleep 2
  # find the probe's job (filtered by --repo for clarity).
  jobs_json="$("$ROBOREV" list --repo "$tmp" --json 2>/dev/null || echo '[]')"
  n=$(printf '%s' "$jobs_json" | jq 'length' 2>/dev/null || echo 0)
  if [ "${n:-0}" -lt 1 ]; then
    bad "^v-review: commit did NOT enqueue a roborev job (post-commit not firing for an arbitrary repo)"
  else
    ok "^v-review[enqueue]: probe commit enqueued $n job(s)"
    job_id=$(printf '%s' "$jobs_json" | jq '.[0].id' 2>/dev/null || echo)
    job_agent=$(printf '%s' "$jobs_json" | jq -r '.[0].agent' 2>/dev/null || echo '?')
    [ "$job_agent" = "claude-code" ] \
      && ok "^v-review[agent]: job agent=$job_agent" \
      || bad "^v-review[agent]: job agent='$job_agent' (expected claude-code)"
    # poll up to 240s for terminal status (claude reviews can take 30–120s).
    deadline=$(($(date +%s) + 240))
    status=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
      status=$("$ROBOREV" list --repo "$tmp" --json 2>/dev/null | jq -r '.[0].status' 2>/dev/null || echo)
      case "$status" in done|passed|failed) break ;; esac
      sleep 5
    done
    case "$status" in
      done|passed)
        ok "^v-review[complete]: claude-code review completed (status=$status)"
        ;;
      failed)
        bad "^v-review[complete]: claude-code review FAILED (status=$status) — check 'roborev log $job_id'"
        ;;
      *)
        bad "^v-review[complete]: did not complete within 240s (status=$status; job_id=$job_id) — check 'roborev log $job_id'"
        ;;
    esac
  fi
else
  bad "^v-review: skipped — binary/hooksPath/agent precondition failed above"
fi

[ "$fails" -eq 0 ] || { printf '\n%d check(s) FAILED\n' "$fails" >&2; exit 1; }
printf '\nseed-roborev: all checks passed\n'
