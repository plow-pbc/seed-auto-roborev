#!/usr/bin/env bash
# Standalone unit tests for the seed-installed Claude-Code pre-checkout gate
# (roborev-pre-checkout-gate.py). Mocks $HOME with a fake roborev binary at the
# seed-installed path (~/.local/bin/roborev) that answers the gate's only call
# (`list --json …`) off a per-repo JSON fixture; no daemon required. The gate
# ALLOWS by emitting nothing (exit 0) and DENIES a branch SWITCH (away from a
# branch with open verdict=F reviews) by printing a permissionDecision=deny JSON.
#
# Two axes are exercised: (1) the COMMAND PARSER — which checkout/switch forms
# count as a branch switch vs. a file restore (the gate's novel logic); (2) the
# DENY/ALLOW DECISION given the leaving-branch's open-fail state. The gate does
# NOT wait on in-flight reviews (a checkout exports nothing), so there's no
# wait/timeout machinery to test, unlike the push gate.
set -u

. "$(cd "$(dirname "$0")" && pwd)/testlib.sh"

HOOK="$(cd "$(dirname "$0")" && pwd)/roborev-pre-checkout-gate.py"
[ -x "$HOOK" ]; assert_rc 0 $? "pre-checkout gate is executable"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp"
mkdir -p "$HOME/.local/bin"
FIXTURES="$tmp/fixtures"; mkdir -p "$FIXTURES"
export PATH="$HOME/.local/bin:$PATH"
command -v jq >/dev/null || { echo "jq required for this test suite" >&2; exit 1; }

# Fake roborev. `list --json --repo R --branch B` prints repo R's fixture array
# (the gate filters verdict/status itself). A listfail.<repohash> sentinel makes
# `list` exit nonzero (wedged daemon) — the checkout gate must fail OPEN on that.
cat > "$HOME/.local/bin/roborev" <<BIN
#!/usr/bin/env bash
FIXTURES="$FIXTURES"
BIN
cat >> "$HOME/.local/bin/roborev" <<'BIN'
repo_hash() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
fixture_for() { printf '%s/%s.json' "$FIXTURES" "$(repo_hash "$1")"; }
sub="$1"; shift || true
if [[ "$sub" == "list" ]]; then
  repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in --repo) repo="$2"; shift 2;; --branch) shift 2;; --json) shift;; *) shift;; esac
  done
  [[ -f "$FIXTURES/listfail.$(repo_hash "$repo")" ]] && exit 3
  f="$(fixture_for "$repo")"
  if [[ -f "$f" ]]; then cat "$f"; else echo '[]'; fi
  exit 0
fi
exit 0
BIN
chmod +x "$HOME/.local/bin/roborev"

write_fixture() {  # write_fixture <repo_root> <json_array>
  printf '%s' "$2" > "$FIXTURES/$(printf '%s' "$1" | sha256sum | cut -d' ' -f1).json"
}

# Stand up a throwaway repo on branch feature/x, write its fixture (the open set
# on the branch being LEFT). Echoes the repo root.
new_repo() {  # new_repo <fixture_json> -> echoes repo root
  local d root; d="$(mktemp -d "$tmp/repo.XXXXXX")"
  git init -q -b feature/x "$d"
  root=$(git -C "$d" rev-parse --show-toplevel)
  write_fixture "$root" "$1"
  printf '%s' "$root"
}
run_cmd() {  # run_cmd <repo_root> <git_cmd>
  local root="$1" cmd="$2"
  local payload; payload=$(jq -n --arg cmd "$cmd" --arg cwd "$root" \
    '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd}')
  printf '%s' "$payload" | python3 "$HOOK"
}
is_deny() { printf '%s' "$1" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; }

OPEN_FAIL='[{"id":20,"git_ref":"abc123","status":"done","verdict":"F","closed":false}]'

# --- allow paths: nothing to gate (non-Bash, non-switch commands) ------------
out=$(printf '%s' '{"tool_name":"Edit","tool_input":{}}' | python3 "$HOOK"); rc=$?
assert_rc 0 "$rc" "gate exits 0 on non-Bash"
assert_eq "" "$out" "gate emits nothing for non-Bash tool"

root=$(new_repo "$OPEN_FAIL")
out=$(run_cmd "$root" "ls -la")
assert_eq "" "$out" "gate allows a non-git Bash command even with open fails"

# `echo git checkout other` — first shlex token is echo, not git → must not gate.
out=$(run_cmd "$root" "echo git checkout other")
assert_eq "" "$out" "gate ignores 'echo git checkout ...' (first token must be git)"

# --- DENY: switching AWAY from a branch with an open fail-verdict review ------
# Parametrize over every form that LEAVES the current branch; all must deny when
# the leaving branch has an open verdict=F. (Same fixture/repo state, different
# switch syntax — the parser's branch-switch recognition is the axis.)
for sw in \
  "git checkout other" \
  "git switch other" \
  "git checkout -b newbranch" \
  "git checkout -B newbranch" \
  "git switch -c newbranch" \
  "git switch -C newbranch" \
  "git checkout -" \
  "git switch -" \
  "git checkout featurefile"   # bare single word → treated as a branch ref
do
  root=$(new_repo "$OPEN_FAIL")
  out=$(run_cmd "$root" "$sw")
  is_deny "$out"; assert_rc 0 $? "gate DENIES branch switch '$sw' when leaving branch has an open fail"
done

# Deny reason names the blocking review id, the leaving branch, and the drain path.
root=$(new_repo "$OPEN_FAIL")
out=$(run_cmd "$root" "git switch other")
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "$reason" "#20" "deny reason names the blocking review id"
assert_contains "$reason" "feature/x" "deny reason names the branch being LEFT"
assert_contains "$reason" "roborev close" "deny reason tells how to resolve/acknowledge"
assert_contains "$reason" "roborev refine" "deny reason names the refine loop to steer off"

# `git -C <dir> checkout other` form resolves the repo via -C and still denies.
root2=$(new_repo "$OPEN_FAIL")
out=$(printf '%s' "$(jq -n --arg cmd "git -C $root2 checkout other" \
  '{tool_name:"Bash",tool_input:{command:$cmd},cwd:"/tmp"}')" | python3 "$HOOK")
is_deny "$out"; assert_rc 0 $? "gate honors 'git -C <dir> checkout <branch>' and denies on the leaving branch's open fail"

# --- ALLOW: FILE-RESTORE forms (NOT branch switches) — even with open fails ---
# These restore working-tree files; they don't leave the branch, so they must
# NEVER be gated regardless of the branch's open-fail state.
for fc in \
  "git checkout -- somefile.py" \
  "git checkout HEAD -- somefile.py" \
  "git checkout ." \
  "git checkout main src/app.py" \
  "git restore somefile.py" \
  "git restore --staged somefile.py" \
  "git checkout --pathspec-from-file=list.txt"
do
  root=$(new_repo "$OPEN_FAIL")
  out=$(run_cmd "$root" "$fc")
  assert_eq "" "$out" "gate ALLOWS file-restore form '$fc' (not a branch switch)"
done

# Bare `git checkout` / `git switch` with no destination → not a switch → allow.
root=$(new_repo "$OPEN_FAIL")
out=$(run_cmd "$root" "git checkout"); assert_eq "" "$out" "gate allows bare 'git checkout' (no destination)"
out=$(run_cmd "$root" "git switch");   assert_eq "" "$out" "gate allows bare 'git switch' (no destination)"

# --- ALLOW: clean leaving branch (no open fails) -----------------------------
root=$(new_repo '[
  {"id":22,"git_ref":"p1","status":"done","verdict":"P","closed":false},
  {"id":23,"git_ref":"f1","status":"done","verdict":"F","closed":true}
]')
out=$(run_cmd "$root" "git switch other")
assert_eq "" "$out" "gate allows a switch when only PASS + closed-fail reviews exist on the leaving branch"

root=$(new_repo '[]')
out=$(run_cmd "$root" "git checkout other")
assert_eq "" "$out" "gate allows a switch when the leaving branch has no reviews at all"

# An IN-FLIGHT review (not yet verdict=F) does NOT block a switch — the gate acts
# on confirmed open fails only (no wait), unlike the push gate.
root=$(new_repo '[{"id":30,"git_ref":"r30","status":"running","verdict":null,"closed":false}]')
out=$(run_cmd "$root" "git switch other")
assert_eq "" "$out" "gate allows a switch with only an in-flight (non-fail) review (no wait, confirmed-fails only)"

# --- drift tolerance: a null-id terminal open-FAIL still denies + renders ------
root=$(new_repo '[{"id":null,"git_ref":"reffallbk","status":"done","verdict":"F","closed":false}]')
out=$(run_cmd "$root" "git switch other")
is_deny "$out"; assert_rc 0 $? "gate denies a null-id terminal fail on the leaving branch"
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "$reason" "@reffallb" "id-less fail row displays @git_ref, not #None"
assert_not_contains "$reason" "#None" "id-less fail row does not render 'review #None'"

# --- fail-OPEN: roborev list FAILS → ALLOW (distinct from the push gate) ------
# A wedged/timed-out list must NOT wedge every branch switch — a blocked checkout
# strands no code, so the checkout gate fails OPEN here (the push gate, an export
# boundary, fails CLOSED — that asymmetry is deliberate, see the module docstring).
root=$(new_repo "$OPEN_FAIL")
touch "$FIXTURES/listfail.$(printf '%s' "$root" | sha256sum | cut -d' ' -f1)"
out=$(run_cmd "$root" "git switch other"); rc=$?
assert_rc 0 "$rc" "gate exits 0 (no crash) when roborev list fails"
assert_eq "" "$out" "gate fail-OPEN ALLOWS a switch when roborev list fails (a blocked checkout strands no code)"

# `roborev list` returns JSON null (never-reviewed branch) → allow (empty, not a fault).
root=$(new_repo 'null')
out=$(run_cmd "$root" "git switch other"); rc=$?
assert_rc 0 "$rc" "gate exits 0 when roborev list returns JSON null"
assert_eq "" "$out" "gate ALLOWS a switch when roborev list returns JSON null (never-reviewed branch)"

# --- roborev missing → allow (don't wedge a switch on a broken dev install) ---
mr_home="$(mktemp -d)"; mr_repo="$(mktemp -d)"
( cd "$mr_repo" && git init -q -b feature/x && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git switch other"},"cwd":"%s"}' "$mr_repo" \
  | HOME="$mr_home" PATH="/usr/bin:/bin" "$HOOK")
assert_eq "" "$out" "gate allows the switch when roborev is not installed (broken-install signal owned elsewhere)"
rm -rf "$mr_home" "$mr_repo"

assert_summary
