#!/usr/bin/env bash
# Standalone unit tests for the seed-installed Claude-Code pre-push gate
# (roborev-pre-push-gate.py). The gate blocks a Claude-initiated `git push`
# while the branch has open roborev fail-verdict reviews, first waiting up to
# 10 min for any in-flight reviews to finish. No daemon required — a fake
# roborev serves a canned `list --json` fixture + a controllable `wait`.
#
# Ported from claude-config's tests/test-hooks.sh (the pre-push-gate scenarios).
set -u

# --- inline assert harness (mirrors test-bridge.sh) --------------------------
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

GATE="$(cd "$(dirname "$0")" && pwd)/roborev-pre-push-gate.py"
[ -x "$GATE" ]; assert_rc 0 $? "pre-push gate is executable"

# ---- fake-roborev harness for the pre-push gate ----
# The gate uses `roborev list --json` + `roborev wait` (not the sqlite DB the
# pre-commit bridge reads), so the fake roborev here serves a canned JSON
# fixture for `list` and a controllable `wait`.
#
# CRITICAL: `_find_roborev(repo_root)` rejects any roborev located UNDER
# repo_root (PATH-attack guard). So the fake binary MUST live outside the git
# repo — `gate_repo` puts the repo in a subdir and the fake bin in a sibling dir.

# make_fake_roborev <bindir> <list-json-fixture> [post-wait-fixture]
#   `list` cats the fixture; `wait` sleeps $FAKE_WAIT_SLEEP then exits $FAKE_WAIT_RC.
#   With a second fixture, `list` emits the first fixture on its first call and the
#   second on every subsequent call (counter file in $bindir) — modeling a review
#   that changes state between the gate's pre-wait list and its post-wait re-query.
make_fake_roborev() {
  local bindir="$1" fixture="$2" post="${3:-$2}"
  rm -f "$bindir/.list_calls"
  cat > "$bindir/roborev" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "list" ]; then
  # Verify the gate scoped the query by the EXPECTED repo + branch. A
  # wrongly-scoped query exits nonzero → the gate treats it as [] → allow,
  # which flips the deny-expecting tests RED. That's the regression guard.
  if [ -n "\${EXPECT_REPO:-}" ]; then
    printf '%s\n' "\$@" | grep -qxF -- "\$EXPECT_REPO" || { echo "wrong --repo" >&2; exit 1; }
  fi
  if [ -n "\${EXPECT_BRANCH:-}" ]; then
    printf '%s\n' "\$@" | grep -qxF -- "\$EXPECT_BRANCH" || { echo "wrong --branch" >&2; exit 1; }
  fi
  n=\$(cat "$bindir/.list_calls" 2>/dev/null || echo 0)
  echo \$((n + 1)) > "$bindir/.list_calls"
  if [ "\$n" -eq 0 ]; then cat "$fixture"; else cat "$post"; fi
  exit 0
fi
if [ "\$1" = "wait" ]; then sleep "\${FAKE_WAIT_SLEEP:-0}"; exit "\${FAKE_WAIT_RC:-0}"; fi
exit 0
EOF
  chmod +x "$bindir/roborev"
}

# fake_list_json <repo_root> <branch> [id status verdict closed]...
#   Per-row fields are passed as four separate positional args (consumed 4 at a
#   time) so an EMPTY verdict (a queued/running row) is representable without
#   whitespace-collapse. verdict is P/F/"" ; closed is true/false. Emits a
#   `list --json` array.
fake_list_json() {
  local repo="$1" branch="$2"; shift 2
  local first=1; printf '['
  while [ "$#" -ge 4 ]; do
    [ $first -eq 1 ] || printf ','; first=0
    printf '{"id":%s,"status":"%s","verdict":"%s","closed":%s,"branch":"%s","repo_path":"%s","commit_subject":"subj %s"}' \
      "$1" "$2" "$3" "$4" "$branch" "$repo" "$1"
    shift 4
  done
  printf ']'
}

# gate_repo — stand up an isolated env: a git repo in a SUBDIR with the fake
# roborev in a SIBLING bin dir (so `_find_roborev` does NOT reject it as
# under-repo). Echoes "<repo>|<bin>". Caller writes the list fixture + calls
# make_fake_roborev "$bin" "$fixture".
gate_repo() {
  local root repo bin
  root=$(mktemp -d); repo="$root/repo"; bin="$root/bin"
  mkdir -p "$repo" "$bin"
  ( cd "$repo" && /usr/bin/git init -q \
      && /usr/bin/git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
      && /usr/bin/git checkout -q -b feat/x ) >/dev/null 2>&1
  printf '%s|%s' "$repo" "$bin"
}

# run_gate <repo> <bin> <command> [extra env assignments...] — prints hook stdout
run_gate() {
  local repo="$1" bin="$2" cmd="$3"; shift 3
  # EXPECT_REPO/EXPECT_BRANCH arm the fake roborev's scope guard: the gate must
  # query `list --repo <toplevel> --branch feat/x` or the fake exits nonzero
  # (→ gate sees [] → allow), failing the deny-expecting assertions. The gate
  # passes git's canonical `--show-toplevel` (symlinks resolved), which on
  # macOS differs from the mktemp `$repo` (/var → /private/var), so we expect
  # the realpath.
  local repo_real; repo_real=$(cd "$repo" && /usr/bin/git rev-parse --show-toplevel)
  printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' "$repo" "$cmd" \
    | env EXPECT_REPO="$repo_real" EXPECT_BRANCH="feat/x" "$@" PATH="$bin:$PATH" HOME="$repo" "$GATE"
}

IFS='|' read -r GREPO GBIN <<<"$(gate_repo)"

# Non-push command → allow (no output)
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | "$GATE"); rc=$?
assert_rc 0 "$rc" "gate: non-push allowed (exit 0)"
assert_eq "" "$out" "gate: non-push emits no output"

# git push with an open FAIL review → deny, reason names the job id
fixF=$(mktemp); fake_list_json "$GREPO" feat/x 9 done F false 10 done P false > "$fixF"
make_fake_roborev "$GBIN" "$fixF"
out=$(run_gate "$GREPO" "$GBIN" "git push")
assert_eq "deny" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" "gate: open FAIL denies push"
assert_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')" "review #9" "gate: deny names the failing job id"

# git push with only PASS / closed reviews → allow (no output)
fixOK=$(mktemp); fake_list_json "$GREPO" feat/x 9 done F true 10 done P false > "$fixOK"
make_fake_roborev "$GBIN" "$fixOK"
out=$(run_gate "$GREPO" "$GBIN" "git push"); rc=$?
assert_rc 0 "$rc" "gate: no open-fail allows push (exit 0)"
assert_eq "" "$out" "gate: clean branch emits no deny"

# In-flight review whose `wait` outlasts the bound → deny (timeout). Both
# in-flight states (`queued` and `running`) take the wait path, so the same
# assertion is parametrized over both — an in-flight row has an empty verdict,
# which fake_list_json represents; the timeout fires first (FAKE_WAIT_SLEEP >
# ROBOREV_PUSH_WAIT_SECS).
for inflight in queued running; do
  fixR=$(mktemp); fake_list_json "$GREPO" feat/x 11 "$inflight" "" false > "$fixR"
  make_fake_roborev "$GBIN" "$fixR"
  out=$(run_gate "$GREPO" "$GBIN" "git push" ROBOREV_PUSH_WAIT_SECS=1 FAKE_WAIT_SLEEP=3)
  assert_eq "deny" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" "gate: in-flight ($inflight) past timeout denies"
  assert_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')" "did not complete" "gate: timeout reason explains ($inflight)"
done

# In-flight review that finishes within the bound, leaving no open-fail → allow.
# Realistic two-fixture sequence: pre-wait shows the job running; post-wait shows
# it done with a PASS verdict → re-query has no in-flight and no open-fail → allow.
fixClnPre=$(mktemp); fake_list_json "$GREPO" feat/x 11 running "" false > "$fixClnPre"
fixClnPost=$(mktemp); fake_list_json "$GREPO" feat/x 11 done P false > "$fixClnPost"
make_fake_roborev "$GBIN" "$fixClnPre" "$fixClnPost"
out=$(run_gate "$GREPO" "$GBIN" "git push" ROBOREV_PUSH_WAIT_SECS=5 FAKE_WAIT_SLEEP=0 FAKE_WAIT_RC=0); rc=$?
assert_rc 0 "$rc" "gate: in-flight that finishes clean allows push"
assert_eq "" "$out" "gate: finished-clean emits no deny"

# In-flight that's STILL running after the wait (e.g. wait returned but the
# daemon re-queued it) → deny. Pre-wait running; wait returns quick; post-wait
# STILL running → the gate must not let an unreviewed-state push slip through.
fixSipPre=$(mktemp); fake_list_json "$GREPO" feat/x 13 running "" false > "$fixSipPre"
fixSipPost=$(mktemp); fake_list_json "$GREPO" feat/x 13 running "" false > "$fixSipPost"
make_fake_roborev "$GBIN" "$fixSipPre" "$fixSipPost"
out=$(run_gate "$GREPO" "$GBIN" "git push" ROBOREV_PUSH_WAIT_SECS=5 FAKE_WAIT_SLEEP=0 FAKE_WAIT_RC=0)
assert_eq "deny" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" "gate: still-in-flight after wait denies"
assert_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')" "still in flight" "gate: still-in-flight deny reason explains"

# running → finishes-as-FAIL → deny. Pre-wait fixture shows the job running
# (empty verdict); post-wait fixture shows it done with an open FAIL. The gate
# must gate on the FRESH post-wait state, not the stale pre-wait list.
fixPre=$(mktemp); fake_list_json "$GREPO" feat/x 12 running "" false > "$fixPre"
fixPost=$(mktemp); fake_list_json "$GREPO" feat/x 12 done F false > "$fixPost"
make_fake_roborev "$GBIN" "$fixPre" "$fixPost"
out=$(run_gate "$GREPO" "$GBIN" "git push" ROBOREV_PUSH_WAIT_SECS=5 FAKE_WAIT_SLEEP=0 FAKE_WAIT_RC=1)
assert_eq "deny" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" "gate: running→finishes-FAIL denies on re-query"
assert_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')" "review #12" "gate: post-wait deny names the now-failed job id"

# `git -C <dir> push` (payload cwd elsewhere) → resolves the repo via -C, denies on open-fail.
fixC=$(mktemp); fake_list_json "$GREPO" feat/x 9 done F false > "$fixC"
make_fake_roborev "$GBIN" "$fixC"
GREPO_REAL=$(cd "$GREPO" && /usr/bin/git rev-parse --show-toplevel)
out=$(printf '{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"git -C %s push origin HEAD"}}' "$GREPO" \
  | env EXPECT_REPO="$GREPO_REAL" EXPECT_BRANCH="feat/x" PATH="$GBIN:$PATH" HOME="$GREPO" "$GATE")
assert_eq "deny" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" "gate: git -C <dir> push resolves repo + denies"

# An ABSOLUTE git path (`/usr/bin/git push`) must be recognized as a git
# invocation and gated — not treated as unresolved → allow (the bypass). Use a
# real GIT_CANDIDATES entry present on this host; assert it resolves to one (so
# the recognizer is genuinely exercised, never a vacuous skip).
ABS_GIT=""
for g in /usr/bin/git /opt/homebrew/bin/git /usr/local/bin/git; do [ -x "$g" ] && { ABS_GIT="$g"; break; }; done
[ -n "$ABS_GIT" ]; assert_rc 0 $? "gate: a GIT_CANDIDATES path exists to exercise the absolute-path recognizer (found: ${ABS_GIT:-none})"
fixAbs=$(mktemp); fake_list_json "$GREPO" feat/x 9 done F false > "$fixAbs"
make_fake_roborev "$GBIN" "$fixAbs"
out=$(run_gate "$GREPO" "$GBIN" "$ABS_GIT push")
assert_eq "deny" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" "gate: absolute git path ($ABS_GIT push) is recognized + denies (no bypass)"

# roborev not on PATH → allow (best-effort no-op). Restrict PATH to system dirs only.
out=$(printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"git push"}}' "$GREPO" \
  | PATH="/usr/bin:/bin" HOME="$GREPO" "$GATE"); rc=$?
assert_rc 0 "$rc" "gate: roborev missing → allow"
assert_eq "" "$out" "gate: roborev missing emits no deny"

# Untrusted commit_subject must NOT leak into the Claude-visible deny reason at
# all — neither the secret token NOR the non-secret prose. Redaction only strips
# token-shaped text; prompt-injection prose would survive it, so the subject is
# dropped from the message entirely. The deny still fires and names the job id
# (proves it's not passing vacuously on an empty/allow reason).
fixS=$(mktemp); printf '[{"id":9,"status":"done","verdict":"F","closed":false,"branch":"feat/x","repo_path":"%s","commit_subject":"leak AKIAIOSFODNN7EXAMPLE"}]' "$GREPO" > "$fixS"
make_fake_roborev "$GBIN" "$fixS"
out=$(run_gate "$GREPO" "$GBIN" "git push")
assert_eq "deny" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" "gate: open-fail still denies"
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "$reason" "review #9" "gate: deny names the failing job id (not vacuous)"
assert_not_contains "$reason" "AKIAIOSFODNN7EXAMPLE" "gate: deny reason omits secret-shaped subject token"
assert_not_contains "$reason" "leak" "gate: deny reason omits untrusted subject prose entirely"

assert_summary
