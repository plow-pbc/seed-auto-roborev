#!/usr/bin/env bash
# Deterministic implementation of SEED.md ## Verify for seed-auto-roborev (v6).
# Read-only on installed state, EXCEPT one ephemeral throwaway git repo it
# creates + a single commit in it: a deliberately-broken hello-world that a
# claude-code reviewer must flag, proving the review loop end-to-end via the
# public `roborev list` seam (the post-commit hook is roborev's own, silent
# one). Cleaned up before exit. Fail-loud: any miss → nonzero.
set -uo pipefail

HOOKS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/roborev/git-hooks"
fails=0
ok()  { printf 'OK   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*" >&2; fails=$((fails+1)); }

ROBOREV="$(command -v roborev || true)"
[ -z "$ROBOREV" ] && [ -x "$HOME/.local/bin/roborev" ] && ROBOREV="$HOME/.local/bin/roborev"

# --- static checks -----------------------------------------------------------
[ -n "$ROBOREV" ] && ok "v-binary: roborev at $ROBOREV" || bad "v-binary: roborev not found"
if [ -n "$ROBOREV" ] && "$ROBOREV" list >/dev/null 2>&1; then
  ok "v-daemon: roborev daemon reachable"
else
  bad "v-daemon: roborev daemon not reachable"
fi
agent="$([ -n "$ROBOREV" ] && "$ROBOREV" config get default_agent 2>/dev/null | head -1 || echo '?')"
[ "$agent" = "claude-code" ] && ok "v-agent: default_agent=$agent" || bad "v-agent: default_agent='$agent' (expected claude-code)"
hp="$(git config --global core.hooksPath || true)"
[ "$hp" = "$HOOKS_DIR" ] && ok "v-hookspath: core.hooksPath=$HOOKS_DIR" || bad "v-hookspath: core.hooksPath='$hp' (expected $HOOKS_DIR)"
[ -x "$HOOKS_DIR/post-commit" ]  && ok "v-postcommit: post-commit executable (roborev-owned)"   || bad "v-postcommit: $HOOKS_DIR/post-commit missing or not executable"
[ -x "$HOOKS_DIR/post-rewrite" ] && ok "v-postrewrite: post-rewrite executable (roborev-owned)" || bad "v-postrewrite: $HOOKS_DIR/post-rewrite missing or not executable"
# No orphaned wrappers from a prior seed version (the installer removes them).
[ ! -e "$HOOKS_DIR/pre-commit" ]         && ok "v-nostale[pre-commit]: no orphaned seed pre-commit wrapper" || bad "v-nostale[pre-commit]: stale $HOOKS_DIR/pre-commit from a prior seed — re-run install.sh"
[ ! -e "$HOOKS_DIR/roborev-hooklib.sh" ] && ok "v-nostale[hooklib]: no orphaned roborev-hooklib.sh"        || bad "v-nostale[hooklib]: stale $HOOKS_DIR/roborev-hooklib.sh from a prior seed — re-run install.sh"

# --- v-bridge — Claude Code context bridge (seed-owned PreToolUse[Bash]) -----
BRIDGE="${XDG_CONFIG_HOME:-$HOME/.config}/roborev/claude-hooks/roborev-pre-commit-context.py"
[ -x "$BRIDGE" ] && ok "v-bridge[file]: installed at $BRIDGE" || bad "v-bridge[file]: missing/not-exec at $BRIDGE"
if [ -f "$HOME/.claude/settings.json" ] && \
   jq -e --arg b "$BRIDGE" 'any(.hooks.PreToolUse[]?;
     .matcher == "Bash" and
     any(.hooks[]?; .type == "command" and .command == $b))' \
   "$HOME/.claude/settings.json" >/dev/null 2>&1; then
  ok "v-bridge[settings]: PreToolUse[Bash] entry present in ~/.claude/settings.json"
else
  bad "v-bridge[settings]: PreToolUse[Bash] roborev entry NOT found in ~/.claude/settings.json"
fi
hb_repo="$(mktemp -d)"; ( cd "$hb_repo" && git init -q )
hb_out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"cwd":"%s"}' "$hb_repo" \
  | HOME="$(mktemp -d)" PATH="/usr/bin:/bin" "$BRIDGE" 2>/dev/null)
printf '%s' "$hb_out" | jq -e '.hookSpecificOutput.additionalContext | contains("ref/install.sh")' >/dev/null 2>&1 \
  && ok "v-bridge[warn]: warns into context when roborev binary is missing" \
  || bad "v-bridge[warn]: did NOT warn on missing roborev binary"
rm -rf "$hb_repo"

# --- v-gate — Claude Code pre-push gate (seed-owned PreToolUse[Bash]) --------
HOOKLIB="${XDG_CONFIG_HOME:-$HOME/.config}/roborev/claude-hooks/_roborev_hooklib.py"
GATE="${XDG_CONFIG_HOME:-$HOME/.config}/roborev/claude-hooks/roborev-pre-push-gate.py"
[ -f "$HOOKLIB" ] && ok "v-lib: shared hooklib installed at $HOOKLIB" || bad "v-lib: missing at $HOOKLIB (bridge + gate import it)"
[ -x "$GATE" ] && ok "v-gate[file]: installed at $GATE" || bad "v-gate[file]: missing/not-exec at $GATE"
if [ -f "$HOME/.claude/settings.json" ] && \
   jq -e --arg g "$GATE" 'any(.hooks.PreToolUse[]?;
     .matcher == "Bash" and
     any(.hooks[]?; .type == "command" and .command == $g and .timeout == 660))' \
   "$HOME/.claude/settings.json" >/dev/null 2>&1; then
  ok "v-gate[settings]: PreToolUse[Bash] gate entry present (timeout 660)"
else
  bad "v-gate[settings]: PreToolUse[Bash] gate entry (timeout 660) NOT found in ~/.claude/settings.json"
fi
# v-gate[allow]: a non-push Bash command must be allowed — AND the gate must
# exit cleanly. Capture stderr + status so a silent CRASH (import error, missing
# python3 under the stripped PATH, any unhandled exception) can't masquerade as
# "allowed" by also producing empty stdout.
ga_cwd="$(mktemp -d)"; ga_home="$(mktemp -d)"; ga_err="$(mktemp)"
ga_out=$(printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"cwd":"%s"}' "$ga_cwd" \
  | HOME="$ga_home" PATH="/usr/bin:/bin" "$GATE" 2>"$ga_err"); ga_rc=$?
if [ "$ga_rc" -eq 0 ] && [ -z "$ga_out" ] && [ ! -s "$ga_err" ]; then
  ok "v-gate[allow]: non-push Bash command is allowed (clean exit, no deny)"
else
  bad "v-gate[allow]: gate did not cleanly allow (rc=$ga_rc, stdout='$ga_out', stderr='$(cat "$ga_err")')"
fi
rm -rf "$ga_cwd" "$ga_home" "$ga_err"

# --- v-listall — `roborev list --all` backlog helper (seed-owned) ------------
# The machine-wide open-FAIL backlog view the upstream CLI lacks. Installed
# alongside the hooks; reads ~/.roborev/reviews.db read-only. Smoke it against
# an empty mocked HOME (no DB) — it must exit 1 (couldn't look) with the GRACEFUL
# "could not read" message on stderr, NOT a crash (Python also exits 1 on an
# uncaught exception, so the rc alone can't tell graceful-return-1 from a
# traceback — assert the message AND the absence of a Traceback).
LISTALL="${XDG_CONFIG_HOME:-$HOME/.config}/roborev/claude-hooks/roborev-list-all.py"
[ -x "$LISTALL" ] && ok "v-listall[file]: backlog helper installed at $LISTALL" || bad "v-listall[file]: missing/not-exec at $LISTALL"
la_home="$(mktemp -d)"; la_err="$(mktemp)"
HOME="$la_home" python3 "$LISTALL" >/dev/null 2>"$la_err"; la_rc=$?
la_msg="$(cat "$la_err")"
if [ "$la_rc" -eq 1 ] && printf '%s' "$la_msg" | grep -q "could not read" && ! printf '%s' "$la_msg" | grep -q "Traceback"; then
  ok "v-listall[run]: helper exits 1 with the graceful 'could not read' status on a missing DB (no crash)"
else
  bad "v-listall[run]: helper did not cleanly report the missing-DB status (rc=$la_rc, stderr='$la_msg')"
fi
rm -rf "$la_home" "$la_err"

# --- v-skill — Claude Code roborev usage skill ------------------------------
SKILL="$HOME/.claude/skills/roborev/SKILL.md"
# Assert the FIRST frontmatter block (line 1 `---`, line 2 `name: roborev`) — not
# just `name: roborev` matched anywhere, which malformed YAML could satisfy.
if [ -f "$SKILL" ] && [ "$(sed -n 1p "$SKILL")" = "---" ] && [ "$(sed -n 2p "$SKILL")" = "name: roborev" ]; then
  ok "v-skill: roborev usage skill installed with valid frontmatter at $SKILL"
else
  bad "v-skill: roborev skill missing or malformed at $SKILL (expected line 1 '---', line 2 'name: roborev')"
fi

# --- v-loop — end-to-end loop test ------------------------------------------
# Drives the full feedback loop: ephemeral repo → broken hello-world commit →
# wait for review → confirm the open fail-verdict finding surfaces via
# `roborev list`. Requires all static checks above to have passed.
if [ "$fails" -ne 0 ] || [ -z "$ROBOREV" ]; then
  bad "v-loop: skipped — preconditions failed above"
  printf '\n%d check(s) FAILED\n' "$fails" >&2; exit 1
fi

# pwd -P canonicalizes the path: on macOS `mktemp -d` returns a /var/... symlink
# to /private/var/..., but git (and thus roborev) records the resolved path, so a
# raw "$tmp" passed to `roborev list --repo` (below) wouldn't match the stored job.
tmp="$(cd "$(mktemp -d)" && pwd -P)"
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
"""Hello world with three obvious bugs (intentional for seed-auto-roborev verify):
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
git commit -q -m "seed-verify broken hello world"
sha1=$(git rev-parse --short HEAD)

# v-loop[enqueued]: roborev's post-commit hook enqueued a review for this repo.
jobs_json="$("$ROBOREV" list --repo "$tmp" --json 2>/dev/null || echo '[]')"
job_id=$(printf '%s' "$jobs_json" | jq '.[0].id // empty' 2>/dev/null)
job_agent=$(printf '%s' "$jobs_json" | jq -r '.[0].agent // "?"' 2>/dev/null)
if [ -n "$job_id" ]; then
  ok "v-loop[enqueued]: post-commit enqueued job=$job_id agent=$job_agent for $sha1"
else
  bad "v-loop[enqueued]: NO job enqueued for the broken-hello-world commit (post-commit hook fired?)"
fi

# v-loop[complete]: poll up to 4 minutes for the review to reach a terminal
# status. claude-code reviews of trivial diffs typically finish in 30–90s.
deadline=$(($(date +%s) + 240))
status=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  status=$("$ROBOREV" list --repo "$tmp" --json 2>/dev/null | jq -r '.[0].status // ""' 2>/dev/null)
  case "$status" in done|passed|failed) break ;; esac
  sleep 5
done
case "$status" in
  done|passed|failed) ok "v-loop[complete]: review reached status=$status (job $job_id)" ;;
  *) bad "v-loop[complete]: review did not reach a terminal status within 240s (status=$status; job=$job_id)"; status= ;;
esac

# v-loop[findings]: the reviewer should have flagged at least one issue in
# the broken hello world. If 0 open findings, the agent missed all 3 bugs —
# real failure of the loop's value, not just the test.
if [ -n "$status" ]; then
  # Count only OPEN FAIL-verdict reviews — the SAME `verdict=="F" && !closed`
  # contract the bridge + pre-push gate use (`--open` includes PASS rows, which
  # are not findings). Counting raw rows would let a PASS-only review satisfy the
  # loop's "the reviewer flagged the broken code" assertion.
  open_now=$("$ROBOREV" list --repo "$tmp" --open --json 2>/dev/null | jq '[.[] | select(.verdict=="F" and (.closed | not))] | length' 2>/dev/null || echo 0)
  if [ "${open_now:-0}" -gt 0 ]; then
    ok "v-loop[findings]: claude-code flagged $open_now open finding(s) on the broken code"
  else
    bad "v-loop[findings]: claude-code reviewed but found 0 open findings on intentionally-broken code (review job $job_id — 'roborev show $job_id' for the verdict)"
  fi
fi

[ "$fails" -eq 0 ] || { printf '\n%d check(s) FAILED\n' "$fails" >&2; exit 1; }
printf '\nseed-auto-roborev: all checks passed (full loop validated end-to-end)\n'
