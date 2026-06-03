#!/usr/bin/env bash
# Standalone unit tests for the seed-installed Claude-Code context bridge
# (roborev-pre-commit-context.py). Mocks $HOME with a fake roborev binary at
# the seed-installed path (~/.local/bin/roborev) that answers the bridge's two
# subcommands (`list --json …` and `show <id>`) off a per-repo JSON fixture; no
# daemon required. Ported from claude-config's tests/test-hooks.sh (the
# roborev-hook scenarios only — the --scan-file responsibility stayed in
# claude-config), plus a scenario unique to the seed: a git-commit with NO
# roborev binary reachable must surface a loud WARNING into context (not deny).
set -u

# Shared assert harness (assert_eq/_rc/_contains/_not_contains/fail/_summary).
. "$(cd "$(dirname "$0")" && pwd)/testlib.sh"

HOOK="$(cd "$(dirname "$0")" && pwd)/roborev-pre-commit-context.py"
[ -x "$HOOK" ]; assert_rc 0 $? "roborev bridge is executable"

# --- fixture: fake $HOME with a fake roborev binary --------------------------
# The bridge no longer reads any DB — it drives roborev's public CLI:
#   roborev list --json --repo <root> --branch <branch>   -> JSON job array
#   roborev show <id>                                      -> review body
# The fake stub answers both off a per-repo JSON fixture: `$FIXTURES/<sha256
# of repo root>.json` holds the job array that `list` returns for that repo,
# and `show <id>` greps that array for the matching id's body. Keying on the
# repo root (passed via `--repo`) is what gives us repo-scoping for free.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp"
mkdir -p "$HOME/.local/bin"
FIXTURES="$tmp/fixtures"; mkdir -p "$FIXTURES"
# Prepend the stub bin dir so `_find_roborev`'s `shutil.which("roborev")`
# resolves to the stub here, not the real `~/.local/bin/roborev` on the
# tester's PATH.
export PATH="$HOME/.local/bin:$PATH"

# The fake stub + several assertions parse JSON with jq; fail loudly up front
# rather than swallowing a missing-jq into confusing "empty body" failures.
command -v jq >/dev/null || { echo "jq required for this test suite" >&2; exit 1; }

# Fake roborev binary. `list --json --repo R --branch B` prints the fixture
# job array for repo R (or `[]` if none); `show <id>` prints that job's body.
# The bridge filters verdict=="F" && !closed itself, so the stub returns the
# WHOLE array (including PASS/closed jobs) to exercise that filter for real.
cat > "$HOME/.local/bin/roborev" <<BIN
#!/usr/bin/env bash
FIXTURES="$FIXTURES"
BIN
cat >> "$HOME/.local/bin/roborev" <<'BIN'
fixture_for() {  # echoes the fixture path for a given --repo value
  local repo="$1"
  printf '%s/%s.json' "$FIXTURES" "$(printf '%s' "$repo" | sha256sum | cut -d' ' -f1)"
}
if [[ "$1" == "list" ]]; then
  repo=""; branch=""; shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="$2"; shift 2;;
      --branch) branch="$2"; shift 2;;
      --limit|--status) shift 2;;
      *) shift;;
    esac
  done
  f="$(fixture_for "$repo")"
  # Return the WHOLE fixture array regardless of --branch (the real CLI scopes
  # server-side, but the bridge ALSO re-filters by branch in Python as
  # defense-in-depth — so the stub stays branch-blind to prove that Python
  # filter carries the scoping, not the stub faithfully mimicking the CLI).
  if [[ -f "$f" ]]; then cat "$f"; else echo '[]'; fi
  exit 0
fi
if [[ "$1" == "show" ]]; then
  id="$2"
  # Find the body for this id across all fixtures (ids are globally unique).
  for f in "$FIXTURES"/*.json; do
    [[ -f "$f" ]] || continue
    body=$(jq -r --argjson id "$id" '.[] | select(.id==$id) | .body // empty' "$f" 2>/dev/null)
    if [[ -n "$body" ]]; then printf '%s\n' "$body"; exit 0; fi
  done
  exit 0
fi
exit 0
BIN
chmod +x "$HOME/.local/bin/roborev"

# Helper: write a fixture JSON array for a repo root. Each job object carries
# an extra `body` field the `show` stub serves (roborev's real `show` prints
# the body; real `list` doesn't include it, but stashing it here keeps the
# fixture in one place).
write_fixture() {  # write_fixture <repo_root> <json_array>
  local f; f="$FIXTURES/$(printf '%s' "$1" | sha256sum | cut -d' ' -f1).json"
  printf '%s' "$2" > "$f"
}

# Helper: stand up a throwaway repo on branch feature/x, write <fixture_json>
# keyed on its canonical root, fire a `git commit` payload through the hook, and
# echo the resulting additionalContext. Collapses the repeated init →
# show-toplevel → write_fixture → run-commit shape shared by the single-repo
# scenarios (PEM, empty-result, soft-fail, unterminated-PEM).
run_commit_for_fixture() {  # run_commit_for_fixture <fixture_json>
  local d root out
  d="$(mktemp -d "$tmp/throwaway.XXXXXX")"
  git init -q -b feature/x "$d"
  root=$(git -C "$d" rev-parse --show-toplevel)
  write_fixture "$root" "$1"
  # `python3 "$HOOK"` is the last pipe stage, so its rc propagates to the
  # command substitution. Assert it's 0: for the empty-expecting scenarios
  # (fail-soft, empty-result) a hook CRASH yields empty stdout too, so without
  # this an uncaught-exception regression would pass `assert_eq "" "$ctx"`
  # vacuously — defeating the fail-soft test's whole purpose.
  out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m foo"},"cwd":"%s"}' "$d" | python3 "$HOOK") \
    || fail "hook crashed (rc=$?) for fixture in $d"
  printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty'
}

PEM_BODY='## Review Findings
- **Severity**: High
- **Location**: test/file.py:1
- **Problem**: FAKE FINDING for tests. Leaked token: sk-FAKEsecretSHOULDbeMASKEDxyz789 plus github_pat_11ABCDE0aBcDeFgHiJ_kLmNoPqRsTuVwXyZ0123456789AbCdEfGhIjKl plus AWS_SECRET_ACCESS_KEY=SHOULDBEMASKEDsecret00000000000000000xy7
- **Fix**: do the fake fix.
## Summary
Fake review.'

repo_dir="$tmp/testrepo"
git init -q -b feature/x "$repo_dir"
# Use `git rev-parse --show-toplevel` so the fixture key matches the path the
# bridge passes to `--repo` (macOS /var/folders symlinks to /private/...; git
# returns the realpath, and so does the bridge via _git_toplevel).
repo_root_canonical=$(git -C "$repo_dir" rev-parse --show-toplevel)
# Job 42: open FAIL (surfaces). 43: PASS (excluded). 44: closed FAIL (excluded).
# 45: open FAIL but on a DIFFERENT branch (excluded — proves branch scoping).
write_fixture "$repo_root_canonical" "$(jq -n --arg body "$PEM_BODY" '[
  {id:42, git_ref:"abc12345def", branch:"feature/x", verdict:"F", closed:false, body:$body},
  {id:43, git_ref:"def45678abc", branch:"feature/x", verdict:"P", closed:false, body:"passing review"},
  {id:44, git_ref:"fed98765abc", branch:"feature/x", verdict:"F", closed:true,  body:"closed/acknowledged review"},
  {id:45, git_ref:"aaa11122bbb", branch:"main",      verdict:"F", closed:false, body:"other-branch fail"}
]')"

other_repo_dir="$tmp/otherrepo"
git init -q -b feature/x "$other_repo_dir"  # same branch name, different repo (no fixture -> [])

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
assert_not_contains "$ctx" "roborev-review-id=45" "context excludes other-branch fail reviews (branch scoping honored, not branch-blind)"
# Secret redaction: the fake review body embeds a token-shaped string.
assert_not_contains "$ctx" "sk-FAKEsecretSHOULDbeMASKEDxyz789" "context redacts token-shaped secrets in review bodies"
assert_not_contains "$ctx" "github_pat_11ABCDE0aBcDeFgHiJ" "context redacts fine-grained GitHub PATs (github_pat_)"
assert_not_contains "$ctx" "SHOULDBEMASKEDsecret00000000000000000xy7" "context redacts AWS secret access keys (assignment-aware, no prefix)"
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

# Test: quoted shell operators inside the commit MESSAGE must NOT tear the
# `git commit` segment apart. `git commit -m "x && y"` (and ; and | variants)
# previously regex-split inside the quoted `-m` arg, broke shlex on the
# unbalanced quote, and silently bypassed the hook. The finding must still
# surface for each operator.
for msg_op in "&&" ";" "|"; do
  payload=$(jq -n --arg cmd "git commit -m \"x $msg_op y\"" --arg cwd "$repo_dir" \
    '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd}')
  out=$(printf '%s' "$payload" | python3 "$HOOK")
  printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("roborev-review-id=42")' >/dev/null 2>&1
  assert_rc 0 $? "quoted '$msg_op' in commit message still surfaces the open fail (quote-aware segmentation)"
done

# Test: missing-binary WARNING is NOT bypassed by a quoted operator in the
# message. With no roborev binary, `git commit -m "a && b"` must still surface
# the warning context — the prior regex pre-split returned None before
# _find_roborev, silently skipping it.
qb_home="$(mktemp -d)"; qb_repo="$(mktemp -d)"
( cd "$qb_repo" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
qb_out=$(printf '%s' "$(jq -n --arg cmd 'git commit -m "a && b"' --arg cwd "$qb_repo" \
  '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd}')" \
  | HOME="$qb_home" PATH="/usr/bin:/bin" "$HOOK")
printf '%s' "$qb_out" | jq -e '.hookSpecificOutput.additionalContext | contains("ref/install.sh")' >/dev/null 2>&1
assert_rc 0 $? "missing-binary warning: quoted operator in commit message does NOT bypass it"
rm -rf "$qb_home" "$qb_repo"

# Test: false-positive guard against `git log --grep commit` (space form, not
# the `--grep=commit` form above). Subcommand must be the first non-option
# token after git, so `commit` as a flag value must not fire.
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git log --grep commit"},"cwd":"%s"}' "$repo_dir" | python3 "$HOOK"); rc=$?
assert_eq "" "$out" "roborev bridge rejects 'git log --grep commit' (subcommand must be the first non-option token after git)"

# Test (Probe 2): a PEM private-key BLOCK in a review body must be redacted in
# full — not just the BEGIN line. The bug was: redaction ran per-line AFTER
# splitlines(), and the PEM pattern matched only the BEGIN line, so the base64
# key body (subsequent lines) leaked into Claude's context. Drive a commit in
# its own repo whose open-FAIL review body embeds a full fake PEM block and
# assert the base64 body lines do NOT appear (and a redaction marker does).
PEM_REVIEW_BODY='## Review Findings
- **Problem**: leaked key in a fixture file:
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEAfakeBASE64keyBODYline1SHOULDnotLEAK0000000000000000
line2ALSObase64ishSHOULDnotLEAK111111111111111111111111111111111111
-----END RSA PRIVATE KEY-----
## Summary
Fake review with a PEM block.'
ctx=$(run_commit_for_fixture "$(jq -n --arg body "$PEM_REVIEW_BODY" '[
  {id:50, git_ref:"pem01234abc", branch:"feature/x", verdict:"F", closed:false, body:$body}
]')")
assert_contains "$ctx" "roborev-review-id=50" "PEM scenario surfaces the open fail review"
assert_not_contains "$ctx" "MIIEpAIBAAKCAQEAfakeBASE64keyBODYline1SHOULDnotLEAK" "PEM base64 body line 1 is NOT leaked into context"
assert_not_contains "$ctx" "line2ALSObase64ishSHOULDnotLEAK" "PEM base64 body line 2 is NOT leaked into context"
assert_contains "$ctx" "redacted private key block" "PEM block is replaced by a redaction marker"

# Test (Probe 4): roborev present but `list` returns no OPEN FAIL reviews ->
# the bridge ALLOWS (empty stdout, no context surfaced). This is the benign
# allow path that replaces the old "no reviews.db" gate. Drive a REAL git
# commit payload through a repo whose fixture has only PASS/closed jobs.
ctx=$(run_commit_for_fixture '[
  {"id":60,"git_ref":"pass1234abc","branch":"feature/x","verdict":"P","closed":false,"body":"clean"},
  {"id":61,"git_ref":"clsd1234abc","branch":"feature/x","verdict":"F","closed":true,"body":"acknowledged"}
]')
assert_eq "" "$ctx" "empty-result allow path: roborev present + no open FAIL reviews -> no context surfaced (allow)"

# Test (fail-soft): a DRIFTED `list` JSON shape — a job missing its `id` key
# that still passes the branch filter — must fail soft to empty, NOT raise an
# uncaught KeyError on every commit (the docstring promises no crash on drift).
ctx=$(run_commit_for_fixture '[
  {"git_ref":"noidfield0","branch":"feature/x","verdict":"F","closed":false,"body":"job missing its id key"}
]')
assert_eq "" "$ctx" "fail-soft on drifted JSON (job missing 'id'): no context surfaced, not a crash"

# Test (unterminated PEM): a BEGIN PRIVATE KEY + base64 body with NO matching
# END (truncated mid-key) must still redact the base64 — the terminated-only
# pattern would leak it.
UNTERM_PEM_BODY='## Review Findings
- **Problem**: leaked key (truncated, no END terminator):
-----BEGIN OPENSSH PRIVATE KEY-----
UNTERMfakeBASE64bodyLINEa_SHOULDnotLEAK
UNTERMfakeBASE64bodyLINEb_SHOULDnotLEAK'
ctx=$(run_commit_for_fixture "$(jq -n --arg body "$UNTERM_PEM_BODY" '[
  {id:70, git_ref:"untpem012a", branch:"feature/x", verdict:"F", closed:false, body:$body}
]')")
assert_contains "$ctx" "roborev-review-id=70" "unterminated-PEM scenario surfaces the open fail review"
assert_not_contains "$ctx" "UNTERMfakeBASE64bodyLINEa_SHOULDnotLEAK" "unterminated PEM (no END): base64 body NOT leaked into context"
assert_contains "$ctx" "redacted private key block" "unterminated PEM block replaced by the redaction marker"

# Test (cap + sort): more than MAX_REVIEWS (5) open-FAIL reviews must surface
# only the 5 NEWEST (highest id) AND report the dropped count — never silently
# truncate. 7 open fails (ids 80-86): assert 82-86 surface, 80/81 don't, and the
# "showing the 5 newest … other 2" note appears.
ctx=$(run_commit_for_fixture '[
  {"id":80,"git_ref":"cap80abcd","branch":"feature/x","verdict":"F","closed":false,"body":"cap finding 80"},
  {"id":81,"git_ref":"cap81abcd","branch":"feature/x","verdict":"F","closed":false,"body":"cap finding 81"},
  {"id":82,"git_ref":"cap82abcd","branch":"feature/x","verdict":"F","closed":false,"body":"cap finding 82"},
  {"id":83,"git_ref":"cap83abcd","branch":"feature/x","verdict":"F","closed":false,"body":"cap finding 83"},
  {"id":84,"git_ref":"cap84abcd","branch":"feature/x","verdict":"F","closed":false,"body":"cap finding 84"},
  {"id":85,"git_ref":"cap85abcd","branch":"feature/x","verdict":"F","closed":false,"body":"cap finding 85"},
  {"id":86,"git_ref":"cap86abcd","branch":"feature/x","verdict":"F","closed":false,"body":"cap finding 86"}
]')
assert_contains "$ctx" "roborev-review-id=86" "cap: newest (86) surfaces"
assert_contains "$ctx" "roborev-review-id=82" "cap: 5th-newest (82) surfaces"
assert_not_contains "$ctx" "roborev-review-id=81" "cap: 6th-newest (81) dropped by MAX_REVIEWS"
assert_not_contains "$ctx" "roborev-review-id=80" "cap: oldest (80) dropped by MAX_REVIEWS"
assert_contains "$ctx" "showing the 5 newest" "cap: header reports the truncation (no silent cap)"
assert_contains "$ctx" "other 2" "cap: header reports how many were dropped"

# Test: a row with NO `branch` key still surfaces — the field-absent fallback of
# the Python branch re-filter (an older roborev that omits `branch` falls back to
# server-side `--branch` scoping, not "drop everything").
ctx=$(run_commit_for_fixture '[
  {"id":90,"git_ref":"nobranch01","verdict":"F","closed":false,"body":"row with no branch field"}
]')
assert_contains "$ctx" "roborev-review-id=90" "branch re-filter: a row missing the branch field still surfaces"

# Test: a fully-qualified `refs/heads/<branch>` row still matches git's short
# `--show-current` name (the removeprefix normalization), so it isn't dropped.
ctx=$(run_commit_for_fixture '[
  {"id":91,"git_ref":"refsheads01","branch":"refs/heads/feature/x","verdict":"F","closed":false,"body":"fully-qualified ref"}
]')
assert_contains "$ctx" "roborev-review-id=91" "branch re-filter: refs/heads/<branch> normalizes to the short name (not dropped)"

# --- missing roborev binary -> loud WARNING into context (never deny) --------
# A git-commit payload in a real repo with NO roborev binary reachable must
# surface a loud, actionable warning (broken-install signal) — NOT deny, and
# NOT no-op. The agent reads it, re-runs the installer, and continues.
hb_home="$(mktemp -d)"; hb_repo="$(mktemp -d)"
( cd "$hb_repo" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
hb_out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"cwd":"%s"}' "$hb_repo" \
  | HOME="$hb_home" PATH="/usr/bin:/bin" "$HOOK")
printf '%s' "$hb_out" | jq -e '.hookSpecificOutput.additionalContext | contains("not installed")' >/dev/null 2>&1
assert_rc 0 $? "missing-binary: git-commit path surfaces a warning that roborev is not installed"
printf '%s' "$hb_out" | jq -e '.hookSpecificOutput.additionalContext | contains("ref/install.sh")' >/dev/null 2>&1
assert_rc 0 $? "missing-binary: warning names the real seed installer (ref/install.sh)"
printf '%s' "$hb_out" | jq -e '.hookSpecificOutput | has("permissionDecision") | not' >/dev/null 2>&1
assert_rc 0 $? "missing-binary: warns via context, never emits a permissionDecision (no deny)"
hb_noop=$(printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | HOME="$hb_home" PATH="/usr/bin:/bin" "$HOOK")
assert_eq "" "$hb_noop" "missing-binary: non-commit Bash with no roborev stays a silent no-op"
rm -rf "$hb_home" "$hb_repo"

assert_summary
