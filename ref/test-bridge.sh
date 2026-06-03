#!/usr/bin/env bash
# Standalone unit tests for the seed-installed Claude-Code context bridge
# (roborev-pre-commit-context.py). Mocks $HOME with a fake roborev binary +
# a fake sqlite reviews.db; no daemon required. Ported from claude-config's
# tests/test-hooks.sh (the roborev-hook scenarios only — the --scan-file
# responsibility stayed in claude-config), plus a NEW hard-block scenario
# unique to the seed: a git-commit with NO roborev binary reachable must DENY.
set -u

# --- inline assert harness (mirrors claude-config tests/assert.sh) -----------
ASSERT_PASS=0 ASSERT_FAIL=0
assert_eq() { # assert_eq <expected> <actual> <msg>
  if [ "$1" = "$2" ]; then ASSERT_PASS=$((ASSERT_PASS+1));
  else ASSERT_FAIL=$((ASSERT_FAIL+1)); printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$3" "$1" "$2" >&2; fi
}
assert_contains() { # assert_contains <haystack> <needle> <msg>
  case $1 in *"$2"*) ASSERT_PASS=$((ASSERT_PASS+1));;
    *) ASSERT_FAIL=$((ASSERT_FAIL+1)); printf 'FAIL: %s\n  %q does not contain %q\n' "$3" "$1" "$2" >&2;; esac
}
assert_not_contains() { # assert_not_contains <haystack> <needle> <msg>
  case $1 in *"$2"*) ASSERT_FAIL=$((ASSERT_FAIL+1)); printf 'FAIL: %s\n  %q unexpectedly contains %q\n' "$3" "$1" "$2" >&2;;
    *) ASSERT_PASS=$((ASSERT_PASS+1));; esac
}
assert_rc() { # assert_rc <expected-rc> <actual-rc> <msg>
  if [ "$1" = "$2" ]; then ASSERT_PASS=$((ASSERT_PASS+1));
  else ASSERT_FAIL=$((ASSERT_FAIL+1)); printf 'FAIL: %s (rc expected %s got %s)\n' "$3" "$1" "$2" >&2; fi
}
fail() { ASSERT_FAIL=$((ASSERT_FAIL+1)); printf 'FAIL: %s\n' "$1" >&2; }
assert_summary() { printf '%s passed, %s failed\n' "$ASSERT_PASS" "$ASSERT_FAIL"; [ "$ASSERT_FAIL" -eq 0 ]; }

HOOK="$(cd "$(dirname "$0")" && pwd)/roborev-pre-commit-context.py"
[ -x "$HOOK" ]; assert_rc 0 $? "roborev bridge is executable"

# --- fixture: fake $HOME with a fake roborev binary + fake reviews.db --------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp"
mkdir -p "$HOME/.roborev" "$HOME/.local/bin"
# Prepend the stub bin dir so `_find_roborev`'s `shutil.which("roborev")`
# resolves to the stub here, not the real `~/.local/bin/roborev` on the
# tester's PATH.
export PATH="$HOME/.local/bin:$PATH"

# Fake roborev binary — script only ever calls `roborev show <id>` and only
# needs the body printed to stdout.
cat > "$HOME/.local/bin/roborev" <<'BIN'
#!/usr/bin/env bash
if [[ "$1" == "show" && "$2" == "42" ]]; then
  cat <<'OUT'
Review for job 42 (by claude-code)
Tokens: 1k ctx · 100 out
------------------------------------------------------------
## Review Findings
- **Severity**: High
- **Location**: test/file.py:1
- **Problem**: FAKE FINDING for tests. Leaked token: sk-FAKEsecretSHOULDbeMASKEDxyz789
- **Fix**: do the fake fix.
## Summary
Fake review.
OUT
fi
BIN
chmod +x "$HOME/.local/bin/roborev"

# Fake sqlite DB. Real roborev schema has more columns; the script reads only
# the ones in the JOIN/WHERE clauses, so a minimal schema is enough.
sqlite3 "$HOME/.roborev/reviews.db" <<'SQL'
CREATE TABLE repos (id INTEGER PRIMARY KEY, name TEXT, root_path TEXT UNIQUE);
CREATE TABLE review_jobs (id INTEGER PRIMARY KEY, repo_id INTEGER, git_ref TEXT, branch TEXT);
CREATE TABLE reviews (id INTEGER PRIMARY KEY, job_id INTEGER, verdict_bool INTEGER, closed INTEGER);
INSERT INTO review_jobs VALUES (42, 1, 'abc12345', 'feature/x');
INSERT INTO review_jobs VALUES (43, 1, 'def45678', 'feature/x');  -- passing, should not surface
INSERT INTO review_jobs VALUES (44, 1, 'fed98765', 'feature/x');  -- closed fail (acknowledged); should not resurface
INSERT INTO reviews VALUES (1, 42, 0, 0);  -- fail, open
INSERT INTO reviews VALUES (2, 43, 1, 0);  -- pass, open (excluded by verdict_bool=0)
INSERT INTO reviews VALUES (3, 44, 0, 1);  -- fail, CLOSED (excluded by closed=0; the "acknowledged" path)
SQL

repo_dir="$tmp/testrepo"
git init -q -b feature/x "$repo_dir"
# Backfill the real repo path into the DB. Use `git rev-parse --show-toplevel`
# so the path the script looks up matches the path the test stores (macOS
# /var/folders symlinks to /private/var/folders; git returns the realpath).
repo_root_canonical=$(git -C "$repo_dir" rev-parse --show-toplevel)
sqlite3 "$HOME/.roborev/reviews.db" "INSERT INTO repos VALUES (1, 'testrepo', '$repo_root_canonical');"

other_repo_dir="$tmp/otherrepo"
git init -q -b feature/x "$other_repo_dir"  # same branch name, different repo

# Test: non-Bash tool → silent no-op (no stdout, exit 0)
out=$(printf '%s' '{"tool_name":"Edit","tool_input":{}}' | python3 "$HOOK"); rc=$?
assert_rc 0 "$rc" "roborev bridge exits 0 on non-Bash"
assert_eq "" "$out" "roborev bridge emits nothing for non-Bash tool"

# Test: Bash but not git commit → no-op
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"cwd":"%s"}' "$repo_dir" | python3 "$HOOK"); rc=$?
assert_rc 0 "$rc" "roborev bridge exits 0 on non-commit Bash"
assert_eq "" "$out" "roborev bridge emits nothing for non-commit Bash"

# Test: git log --grep=commit (false-positive guard) → no-op
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git log --grep=commit"},"cwd":"%s"}' "$repo_dir" | python3 "$HOOK"); rc=$?
assert_eq "" "$out" "roborev bridge emits nothing for 'git log --grep=commit'"

# Test: echo-style false positive — `echo git -C ~/private-repo commit` would
# match the regex but the first shlex token is `echo`, not `git`, so the hook
# must NOT honor the embedded -C or surface findings.
payload=$(jq -n --arg cmd "echo 'git -C $other_repo_dir commit -m foo'" --arg cwd "$repo_dir" \
  '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd}')
out=$(printf '%s' "$payload" | python3 "$HOOK"); rc=$?
assert_eq "" "$out" "roborev bridge rejects 'echo git ... commit' (first shlex token must be git)"

# Test: git commit on branch with an open fail-verdict review → emits JSON
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m foo"},"cwd":"%s"}' "$repo_dir" | python3 "$HOOK"); rc=$?
assert_rc 0 "$rc" "roborev bridge exits 0 on firing git commit"
printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName=="PreToolUse"' >/dev/null 2>&1
assert_rc 0 $? "roborev bridge emits PreToolUse JSON on firing git commit"
ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "$ctx" "roborev-review-id=42" "context surfaces the open fail's job ID"
assert_contains "$ctx" "FAKE FINDING" "context includes the roborev review body"
assert_contains "$ctx" "untrusted" "context warns review bodies are untrusted data"
assert_not_contains "$ctx" "roborev-review-id=43" "context excludes verdict=pass reviews"
assert_not_contains "$ctx" "roborev-review-id=44" "context excludes closed fail reviews (acknowledged via 'roborev close')"
# Secret redaction: the fake review body embeds a token-shaped string.
assert_not_contains "$ctx" "sk-FAKEsecretSHOULDbeMASKEDxyz789" "context redacts token-shaped secrets in review bodies"
assert_contains "$ctx" "redacted secret" "context marks redactions"
assert_contains "$ctx" "789" "context preserves last-3-chars per CLAUDE.md convention"

# Test: `git -C <dir> commit ...` form (used by cleanup/SKILL.md). cwd is
# elsewhere; -C points at the actual repo.
payload=$(jq -n --arg cmd "git -C $repo_dir commit -m foo" '{tool_name:"Bash",tool_input:{command:$cmd},cwd:"/tmp"}')
out=$(printf '%s' "$payload" | python3 "$HOOK"); rc=$?
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("roborev-review-id=42")' >/dev/null 2>&1
assert_rc 0 $? "roborev bridge honors 'git -C <dir> commit' (cleanup-style)"

# Test: repo-scoping — same branch name in a different repo should NOT surface
# the first repo's findings (branch-only lookup would).
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m foo"},"cwd":"%s"}' "$other_repo_dir" | python3 "$HOOK"); rc=$?
assert_eq "" "$out" "roborev bridge scopes lookup by repo, not branch alone (branch-collision case)"

# Test: a -C in a preceding shell segment must not poison the lookup. The
# git commit segment has no -C, so the script should use the payload's cwd.
payload=$(jq -n --arg cmd "git -C $other_repo_dir log && git commit -m foo" --arg cwd "$repo_dir" \
  '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd}')
out=$(printf '%s' "$payload" | python3 "$HOOK"); rc=$?
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("roborev-review-id=42")' >/dev/null 2>&1
assert_rc 0 $? "roborev bridge ignores -C in non-commit shell segments"

# Test: a -C *after* `commit` (a commit arg, not a git global flag) must not be
# honored as the git cwd — the parser stops at the `commit` subcommand.
payload=$(jq -n --arg cmd "git commit -C $other_repo_dir -m foo" --arg cwd "$repo_dir" \
  '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd}')
out=$(printf '%s' "$payload" | python3 "$HOOK"); rc=$?
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("roborev-review-id=42")' >/dev/null 2>&1
assert_rc 0 $? "roborev bridge ignores -C tokens after the commit subcommand"

# Test: PATH-attack guard — a repo-controlled `bin/roborev` script must NOT be
# executed by the hook. Stand up a hostile roborev INSIDE $repo_dir, put it
# first on PATH, then drive a commit. The hook should reject the in-repo path
# and fall back to the legit stub at $HOME/.local/bin/roborev.
mkdir -p "$repo_dir/bin"
sentinel="$tmp/MALICIOUS_RAN"
cat > "$repo_dir/bin/roborev" <<BIN
#!/usr/bin/env bash
touch "$sentinel"
echo "MALICIOUS OUTPUT — should not appear"
BIN
chmod +x "$repo_dir/bin/roborev"
payload=$(jq -n --arg cmd "git commit -m foo" --arg cwd "$repo_dir" \
  '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd}')
out=$(printf '%s' "$payload" | PATH="$repo_dir/bin:$PATH" python3 "$HOOK"); rc=$?
[ ! -f "$sentinel" ]; assert_rc 0 $? "roborev bridge rejects repo-controlled bin/roborev (PATH-attack guard)"
printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | grep -q "MALICIOUS OUTPUT" \
  && fail "context contains malicious roborev output — PATH-attack guard failed"
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("FAKE FINDING")' >/dev/null 2>&1
assert_rc 0 $? "PATH-attack guard falls through to fixed ROBOREV_CANDIDATES"
rm -rf "$repo_dir/bin"

# Test: symlink-to-env escape — `bin/roborev -> /usr/bin/env` realpaths out of
# the repo but `env`-as-roborev would then exec a checkout-controlled `bin/show`
# from PATH. The literal-path check in `_is_under_repo` must catch this.
mkdir -p "$repo_dir/bin"
ln -sf /usr/bin/env "$repo_dir/bin/roborev"
show_sentinel="$tmp/MALICIOUS_SHOW_RAN"
cat > "$repo_dir/bin/show" <<BIN
#!/usr/bin/env bash
touch "$show_sentinel"
exit 0
BIN
chmod +x "$repo_dir/bin/show"
payload=$(jq -n --arg cmd "git commit -m foo" --arg cwd "$repo_dir" \
  '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd}')
out=$(printf '%s' "$payload" | PATH="$repo_dir/bin:$PATH" python3 "$HOOK")
[ ! -f "$show_sentinel" ]; assert_rc 0 $? "_find_roborev rejects in-repo symlink-to-env (would have routed roborev show through env → in-repo bin/show)"
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("FAKE FINDING")' >/dev/null 2>&1
assert_rc 0 $? "symlink-to-env guard still falls through to fixed ROBOREV_CANDIDATES"
rm -rf "$repo_dir/bin"

# Test: PATH-sanitization for the `roborev show` subprocess — even if the
# resolved roborev binary uses `#!/usr/bin/env <interp>`, env must not be able
# to find `<interp>` in a repo-controlled bin. Stand up $repo_dir/bin/bash as a
# sentinel, prepend to PATH, run the hook; verify the sentinel did NOT execute.
mkdir -p "$repo_dir/bin"
bash_sentinel="$tmp/MALICIOUS_BASH_RAN"
cat > "$repo_dir/bin/bash" <<BIN
#!/bin/bash
touch "$bash_sentinel"
exit 0
BIN
chmod +x "$repo_dir/bin/bash"
payload=$(jq -n --arg cmd "git commit -m foo" --arg cwd "$repo_dir" \
  '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd}')
out=$(printf '%s' "$payload" | PATH="$repo_dir/bin:$PATH" python3 "$HOOK")
[ ! -f "$bash_sentinel" ]; assert_rc 0 $? "_sanitized_env strips repo bin from PATH for roborev subprocess (env shebang can't bounce into repo bin/bash)"
rm -rf "$repo_dir/bin"

# Test: false-positive guard against `git log --grep commit` (space form, not
# the `--grep=commit` form above). Subcommand must be the first non-option
# token after git, so `commit` as a flag value must not fire.
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git log --grep commit"},"cwd":"%s"}' "$repo_dir" | python3 "$HOOK"); rc=$?
assert_eq "" "$out" "roborev bridge rejects 'git log --grep commit' (subcommand must be the first non-option token after git)"

# --- NEW: hard-block on missing roborev binary -------------------------------
# Hard-block: a git-commit payload in a real repo with NO roborev binary
# reachable must DENY the commit (broken-install signal), not no-op.
hb_home="$(mktemp -d)"; hb_repo="$(mktemp -d)"
( cd "$hb_repo" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
hb_out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"cwd":"%s"}' "$hb_repo" \
  | HOME="$hb_home" PATH="/usr/bin:/bin" "$HOOK")
printf '%s' "$hb_out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1
assert_rc 0 $? "hard-block: missing roborev binary on git-commit path -> permissionDecision=deny"
printf '%s' "$hb_out" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("install-roborev")' >/dev/null 2>&1
assert_rc 0 $? "hard-block: deny reason points at the re-install command"
hb_noop=$(printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | HOME="$hb_home" PATH="/usr/bin:/bin" "$HOOK")
assert_eq "" "$hb_noop" "hard-block: non-commit Bash with no roborev stays a silent no-op (never denies)"
rm -rf "$hb_home" "$hb_repo"

assert_summary
