#!/usr/bin/env bash
# Standalone unit tests for the seed-installed Claude-Code pre-push gate
# (roborev-pre-push-gate.py). Mocks $HOME with a fake roborev binary at the
# seed-installed path (~/.local/bin/roborev) that answers the gate's calls
# (`list --json …` and `wait --quiet --job …`) off per-repo JSON fixtures; no
# daemon required. The gate ALLOWS by emitting nothing (exit 0) and DENIES by
# printing a PreToolUse permissionDecision=deny JSON.
set -u

. "$(cd "$(dirname "$0")" && pwd)/testlib.sh"

HOOK="$(cd "$(dirname "$0")" && pwd)/roborev-pre-push-gate.py"
[ -x "$HOOK" ]; assert_rc 0 $? "pre-push gate is executable"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp"
FIXTURES="$tmp/fixtures"; mkdir -p "$FIXTURES"
# Prepend the stub bin dir so the gate's roborev resolution (seed path =
# ~/.local/bin/roborev under the mocked HOME) picks up the stub, not the real
# binary on the tester's PATH.
export PATH="$HOME/.local/bin:$PATH"
command -v jq >/dev/null || { echo "jq required for this test suite" >&2; exit 1; }

# Shared roborev fake-CLI + fixture harness (testlib.sh). The push gate calls
# `wait` (to drain in-flight reviews), so install the harness WITH the wait
# handler. run_push binds run_hook to this suite's HOOK, defaulting to `git push`.
setup_fake_roborev with_wait
run_push() { run_hook "$HOOK" "$1" "${2:-git push}"; }

# --- allow paths: nothing to gate -------------------------------------------
out=$(printf '%s' '{"tool_name":"Edit","tool_input":{}}' | python3 "$HOOK"); rc=$?
assert_rc 0 "$rc" "gate exits 0 on non-Bash"
assert_eq "" "$out" "gate emits nothing for non-Bash tool"

root=$(new_repo '[{"id":20,"git_ref":"abc123","status":"done","verdict":"F","closed":false}]')
out=$(run_push "$root" "ls -la")
assert_eq "" "$out" "gate allows a non-push Bash command (no deny emitted)"

# `echo git push` — first shlex token is echo, not git → must not gate.
out=$(run_push "$root" "echo git push")
assert_eq "" "$out" "gate ignores 'echo git push' (first token must be git)"

# --- deny: a confirmed open FAIL review (no in-flight) -----------------------
out=$(run_push "$root")
is_deny "$out"; assert_rc 0 $? "gate DENIES push with an open fail-verdict review"
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "$reason" "#20" "deny reason names the blocking review id"
assert_contains "$reason" "roborev close" "deny reason tells how to acknowledge/defer"
assert_contains "$reason" "roborev refine" "deny reason names the refine loop to steer off"
assert_contains "$reason" "roborev fix" "deny reason names the fix loop to steer off too"

# `git -C <dir> push` form resolves the repo via -C and still denies.
root2=$(new_repo '[{"id":21,"git_ref":"def456","status":"done","verdict":"F","closed":false}]')
out=$(printf '%s' "$(jq -n --arg cmd "git -C $root2 push origin HEAD" \
  '{tool_name:"Bash",tool_input:{command:$cmd},cwd:"/tmp"}')" | python3 "$HOOK")
is_deny "$out"; assert_rc 0 $? "gate honors 'git -C <dir> push' and denies on its open fail"

# --- allow: only PASS / closed / empty --------------------------------------
root=$(new_repo '[
  {"id":22,"git_ref":"p1","status":"done","verdict":"P","closed":false},
  {"id":23,"git_ref":"f1","status":"done","verdict":"F","closed":true}
]')
out=$(run_push "$root")
assert_eq "" "$out" "gate allows when only PASS + closed-fail reviews exist"

root=$(new_repo '[]')
out=$(run_push "$root")
assert_eq "" "$out" "gate allows when there are no reviews at all"

# --- in-flight handling (in-flight rows carry verdict:null until they finish) -
# Running review that finishes FAIL after the wait → deny.
root=$(new_repo '[{"id":30,"git_ref":"r30","status":"running","verdict":null,"final":"F","closed":false}]')
out=$(run_push "$root")
is_deny "$out"; assert_rc 0 $? "gate waits for an in-flight review, then DENIES when it finishes FAIL"

# Running review that finishes PASS after the wait → allow (wait doesn't over-block).
root=$(new_repo '[{"id":31,"git_ref":"r31","status":"running","verdict":null,"final":"P","closed":false}]')
out=$(run_push "$root")
assert_eq "" "$out" "gate allows after an in-flight review finishes PASS"

# Wait returns but the review is STILL in flight on re-query → fail-closed deny.
root=$(new_repo '[{"id":33,"git_ref":"r33","status":"running","verdict":null,"closed":false}]')
touch "$FIXTURES/nofinish.33"
out=$(run_push "$root")
is_deny "$out"; assert_rc 0 $? "gate fail-closed DENIES when a review is still in flight after the wait"

# Already-confirmed terminal FAIL + an unrelated in-flight review → deny on the
# confirmed fail (outstanding is evaluated before the in-flight wait), naming the
# terminal #50 rather than stalling on the running job.
root=$(new_repo '[
  {"id":50,"git_ref":"r50","status":"done","verdict":"F","closed":false},
  {"id":51,"git_ref":"r51","status":"running","verdict":null,"closed":false}
]')
out=$(run_push "$root")
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
is_deny "$out"; assert_rc 0 $? "gate denies on a confirmed terminal fail even with an in-flight review present"
assert_contains "$reason" "#50" "confirmed-fail deny names the terminal fail (#50), not a wait/timeout outcome"

# Drifted in-flight row with a null id must NOT crash the gate (int(None)) →
# fail-closed deny via the still-in-flight path, never a crash-allow.
root=$(new_repo '[{"id":null,"git_ref":"rnull","status":"running","verdict":null,"closed":false}]')
out=$(run_push "$root")
is_deny "$out"; assert_rc 0 $? "gate fail-closed DENIES a null-id in-flight row (no int(None) crash)"

# A terminal open-FAIL row with a null id still denies AND renders usefully —
# _format_block falls back to @<git_ref> instead of an unhelpful "review #None".
root=$(new_repo '[{"id":null,"git_ref":"reffallbk","status":"done","verdict":"F","closed":false}]')
out=$(run_push "$root")
is_deny "$out"; assert_rc 0 $? "gate denies a null-id terminal fail"
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "$reason" "@reffallb" "id-less fail row displays @git_ref, not #None"
assert_not_contains "$reason" "#None" "id-less fail row does not render 'review #None'"

# `roborev list` itself FAILS (wedged daemon / timeout / nonzero exit) → the gate
# must fail CLOSED (deny), not mistake an unreadable state for "no findings".
root=$(new_repo '[{"id":60,"git_ref":"r60","status":"done","verdict":"F","closed":false}]')
touch "$FIXTURES/listfail.$(printf '%s' "$root" | sha256sum | cut -d' ' -f1)"
out=$(run_push "$root")
is_deny "$out"; assert_rc 0 $? "gate fail-closed DENIES when roborev list fails (can't determine review state)"
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "$reason" "roborev status" "list-failure deny points at roborev status"

# `roborev list` returns JSON `null` (rc 0), NOT `[]`, for a repo+branch it has
# never reviewed (fresh/cloned repo, brand-new branch). That is empty, not a read
# failure — the gate must ALLOW, else it blocks every push in an untracked repo.
# (Distinct from the listfail case above: rc 0 + parseable, just no jobs.)
root=$(new_repo 'null')
out=$(run_push "$root"); rc=$?
assert_rc 0 "$rc" "gate exits 0 (no crash) when roborev list returns JSON null"
assert_eq "" "$out" "gate ALLOWS a push when roborev list returns JSON null (never-reviewed repo, not a failure)"

# --- status vocabulary: in-flight is a denylist of terminal states -----------
# An UNRECOGNIZED non-terminal status (outside {queued,running}) must be treated
# as in-flight (fail-closed), NOT silently allowed through. With the old
# allowlist this 'starting'+verdict!=F review would be treated terminal and the
# push allowed over an unfinished review. `nofinish` keeps it in flight so the
# re-query denies — proving it was waited on, not waved through.
root=$(new_repo '[{"id":40,"git_ref":"r40","status":"starting","verdict":"P","closed":false}]')
touch "$FIXTURES/nofinish.40"
out=$(run_push "$root")
is_deny "$out"; assert_rc 0 $? "gate treats an unrecognized non-terminal status (starting) as in-flight (fail-closed)"

# Terminal status=passed → allow (review finished, no open fail).
root=$(new_repo '[{"id":41,"git_ref":"r41","status":"passed","verdict":"P","closed":false}]')
out=$(run_push "$root")
assert_eq "" "$out" "gate allows a terminal status=passed review"

# Terminal status=failed carrying verdict F → deny (no wait — it's terminal).
root=$(new_repo '[{"id":42,"git_ref":"r42","status":"failed","verdict":"F","closed":false}]')
out=$(run_push "$root")
is_deny "$out"; assert_rc 0 $? "gate denies a terminal status=failed review carrying verdict F"

# --- roborev missing → allow (don't wedge a push on a broken dev install) ----
mr_home="$(mktemp -d)"; mr_repo="$(mktemp -d)"
( cd "$mr_repo" && git init -q -b feature/x && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git push"},"cwd":"%s"}' "$mr_repo" \
  | HOME="$mr_home" PATH="/usr/bin:/bin" "$HOOK")
assert_eq "" "$out" "gate allows the push when roborev is not installed (warn-surface owns that signal)"
rm -rf "$mr_home" "$mr_repo"

assert_summary
