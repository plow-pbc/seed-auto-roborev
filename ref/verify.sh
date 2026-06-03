#!/usr/bin/env bash
# Deterministic implementation of SEED.md ## Verify for seed-roborev (v5).
# Read-only on installed state, EXCEPT one ephemeral throwaway git repo it
# creates + two commits in it: a deliberately-broken hello-world (which a
# claude-code reviewer must flag), then a second commit that proves the
# resulting open-findings warning surfaces via Option B's always-on pre-commit
# line. Cleaned up before exit. Fail-loud: any miss → nonzero.
set -uo pipefail

HOOKS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/roborev/git-hooks"
fails=0
ok()  { printf 'OK   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*" >&2; fails=$((fails+1)); }

ROBOREV="$(command -v roborev || true)"
[ -z "$ROBOREV" ] && [ -x "$HOME/.local/bin/roborev" ] && ROBOREV="$HOME/.local/bin/roborev"

# --- static checks -----------------------------------------------------------
[ -n "$ROBOREV" ] && ok "^v-binary: roborev at $ROBOREV" || bad "^v-binary: roborev not found"
if [ -n "$ROBOREV" ] && "$ROBOREV" list >/dev/null 2>&1; then
  ok "^v-daemon: roborev daemon reachable"
else
  bad "^v-daemon: roborev daemon not reachable"
fi
agent="$([ -n "$ROBOREV" ] && "$ROBOREV" config get default_agent 2>/dev/null | head -1 || echo '?')"
[ "$agent" = "claude-code" ] && ok "^v-agent: default_agent=$agent" || bad "^v-agent: default_agent='$agent' (expected claude-code)"
hp="$(git config --global core.hooksPath || true)"
[ "$hp" = "$HOOKS_DIR" ] && ok "^v-hookspath: core.hooksPath=$HOOKS_DIR" || bad "^v-hookspath: core.hooksPath='$hp' (expected $HOOKS_DIR)"
[ -x "$HOOKS_DIR/post-commit" ] && ok "^v-postcommit: post-commit executable" || bad "^v-postcommit: $HOOKS_DIR/post-commit missing or not executable"
[ -x "$HOOKS_DIR/pre-commit" ]  && ok "^v-precommit:  pre-commit executable"  || bad "^v-precommit: $HOOKS_DIR/pre-commit missing or not executable"

# --- ^v-bridge — Claude Code context bridge (seed-owned PreToolUse[Bash]) -----
BRIDGE="${XDG_CONFIG_HOME:-$HOME/.config}/roborev/claude-hooks/roborev-pre-commit-context.py"
[ -x "$BRIDGE" ] && ok "^v-bridge[file]: installed at $BRIDGE" || bad "^v-bridge[file]: missing/not-exec at $BRIDGE"
if [ -f "$HOME/.claude/settings.json" ] && \
   jq -e --arg b "$BRIDGE" 'any(.hooks.PreToolUse[]?; .hooks[]?.command == $b)' "$HOME/.claude/settings.json" >/dev/null 2>&1; then
  ok "^v-bridge[settings]: PreToolUse[Bash] entry present in ~/.claude/settings.json"
else
  bad "^v-bridge[settings]: PreToolUse[Bash] roborev entry NOT found in ~/.claude/settings.json"
fi
hb_repo="$(mktemp -d)"; ( cd "$hb_repo" && git init -q )
hb_out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"cwd":"%s"}' "$hb_repo" \
  | HOME="$(mktemp -d)" PATH="/usr/bin:/bin" "$BRIDGE" 2>/dev/null)
printf '%s' "$hb_out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 \
  && ok "^v-bridge[hardblock]: denies a commit when roborev binary is missing" \
  || bad "^v-bridge[hardblock]: did NOT deny on missing roborev binary"
rm -rf "$hb_repo"

# --- ^v-loop — end-to-end loop test ------------------------------------------
# Drives the full feedback loop: ephemeral repo → broken hello-world commit →
# wait for review → second commit → confirm the open-findings warning surfaced.
# Requires all static checks above to have passed.
if [ "$fails" -ne 0 ] || [ -z "$ROBOREV" ]; then
  bad "^v-loop: skipped — preconditions failed above"
  printf '\n%d check(s) FAILED\n' "$fails" >&2; exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
git init -q
git config user.email seed-verify@local
git config user.name  seed-verify

# A "broken hello world" the claude-code reviewer is virtually guaranteed to
# flag: hardcoded credential, OS-command injection via input(), AND a type
# error that crashes on the happy path. Three independent issues — any one of
# them surfacing as an open finding satisfies the loop test.
cat > app.py <<'PY'
"""Hello world with three obvious bugs (intentional for seed-roborev verify):
- hardcoded API-key-shaped credential in source
- OS command injection via input() into os.system
- TypeError on the happy path (str + int)
"""
import os
API_KEY = "sk-anthropic-fake-1234567890abcdef1234567890ab"   # XXX hardcoded
name = input("Name: ")                                      # untrusted input
os.system(f"echo Hello, {name}, key={API_KEY}")             # injection
print("Hello, " + 42)                                       # crashes
PY
git add app.py

c1err="$tmp/commit1.stderr"
git commit -q -m "seed-verify broken hello world" 2>"$c1err"
sha1=$(git rev-parse --short HEAD)

# ^v-loop[option-b-clean]: pre-commit ran BEFORE this commit on the empty
# branch (no findings yet) and should have printed the "0 open findings ✓" line.
grep -q "0 open findings" "$c1err" && ok "^v-loop[option-b-clean]: pre-commit announced clean (0 findings) on first commit" \
  || bad "^v-loop[option-b-clean]: pre-commit did NOT print 'roborev: 0 open findings' before first commit (Option B)"

# ^v-loop[option-a]: post-commit ran AFTER this commit and should have printed
# the "enqueued review for $sha (claude-code)" line.
grep -qE "enqueued review for $sha1 .*claude-code" "$c1err" && ok "^v-loop[option-a]: post-commit announced enqueue for $sha1 (claude-code)" \
  || bad "^v-loop[option-a]: post-commit did NOT print 'enqueued review for $sha1 (claude-code)' (Option A)"

# ^v-loop[enqueued]: the job actually appeared in roborev's queue for this repo
jobs_json="$("$ROBOREV" list --repo "$tmp" --json 2>/dev/null || echo '[]')"
job_id=$(printf '%s' "$jobs_json" | jq '.[0].id // empty' 2>/dev/null)
job_agent=$(printf '%s' "$jobs_json" | jq -r '.[0].agent // "?"' 2>/dev/null)
if [ -n "$job_id" ]; then
  ok "^v-loop[enqueued]: job=$job_id agent=$job_agent"
else
  bad "^v-loop[enqueued]: NO job found for the broken-hello-world commit"
fi

# ^v-loop[complete]: poll up to 4 minutes for the review to reach a terminal
# status. claude-code reviews of trivial diffs typically finish in 30–90s.
deadline=$(($(date +%s) + 240))
status=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  status=$("$ROBOREV" list --repo "$tmp" --json 2>/dev/null | jq -r '.[0].status // ""' 2>/dev/null)
  case "$status" in done|passed|failed) break ;; esac
  sleep 5
done
case "$status" in
  done|passed|failed) ok "^v-loop[complete]: review reached status=$status (job $job_id)" ;;
  *) bad "^v-loop[complete]: review did not reach a terminal status within 240s (status=$status; job=$job_id)"; status= ;;
esac

# ^v-loop[findings]: the reviewer should have flagged at least one issue in
# the broken hello world. If 0 open findings, the agent missed all 3 bugs —
# real failure of the loop's value, not just the test.
if [ -n "$status" ]; then
  open_now=$("$ROBOREV" list --repo "$tmp" --open --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
  if [ "${open_now:-0}" -gt 0 ]; then
    ok "^v-loop[findings]: claude-code flagged $open_now open finding(s) on the broken code"
  else
    bad "^v-loop[findings]: claude-code reviewed but found 0 open findings on intentionally-broken code (review job $job_id — 'roborev show $job_id' for the verdict)"
  fi
fi

# ^v-loop[blocking]: make a second commit and confirm Option B surfaces the
# now-open findings via pre-commit, BEFORE the commit finalizes.
echo "second change" >> app.py
git add app.py
c2err="$tmp/commit2.stderr"
git commit -q -m "seed-verify second commit" 2>"$c2err"
sha2=$(git rev-parse --short HEAD)

if grep -q "open review finding" "$c2err"; then
  ok "^v-loop[blocking]: pre-commit surfaced the open finding(s) before the second commit (Option B)"
else
  bad "^v-loop[blocking]: pre-commit did NOT surface open findings before the second commit (Option B fail)"
fi

# ^v-loop[option-a-second]: confirm Option A also fires on this second commit.
grep -qE "enqueued review for $sha2" "$c2err" \
  && ok "^v-loop[option-a-second]: post-commit announced enqueue for $sha2" \
  || bad "^v-loop[option-a-second]: post-commit silent on second commit (Option A regression)"

[ "$fails" -eq 0 ] || { printf '\n%d check(s) FAILED\n' "$fails" >&2; exit 1; }
printf '\nseed-roborev: all checks passed (full loop validated end-to-end)\n'
