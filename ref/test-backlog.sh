#!/usr/bin/env bash
# Unit tests for the machine-wide open-FAIL backlog surface:
#   - ref/roborev-list-all.py            (the `roborev list --all` seed helper)
#   - open_fail_backlog/format_backlog_summary in _roborev_hooklib.py
#   - the pre-push gate's NON-BLOCKING cross-branch surface on the allow path.
#
# Builds a real sqlite reviews.db under a mocked $HOME (the schema columns the
# backlog query joins on), so the read-only SELECT runs against true SQLite — no
# daemon. The gate tests here assert the cross-branch surface NEVER carries a
# permissionDecision (informational only); the hard-deny behavior is covered by
# test-gate.sh and must stay current-branch-only.
set -u

. "$(cd "$(dirname "$0")" && pwd)/testlib.sh"

REF="$(cd "$(dirname "$0")" && pwd)"
LIST_ALL="$REF/roborev-list-all.py"
GATE="$REF/roborev-pre-push-gate.py"
[ -x "$LIST_ALL" ]; assert_rc 0 $? "roborev-list-all.py is executable"

command -v jq >/dev/null    || { echo "jq required for this test suite" >&2; exit 1; }
command -v sqlite3 >/dev/null || { echo "sqlite3 required for this test suite" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp"
mkdir -p "$HOME/.roborev"
DB="$HOME/.roborev/reviews.db"

# Minimal schema: just the columns the backlog join reads. seed a real review
# graph across several repos/branches plus the noise cases the helper filters.
sqlite3 "$DB" <<'SQL'
CREATE TABLE repos (id INTEGER PRIMARY KEY, root_path TEXT UNIQUE NOT NULL, name TEXT NOT NULL);
CREATE TABLE review_jobs (id INTEGER PRIMARY KEY, repo_id INTEGER NOT NULL, branch TEXT);
CREATE TABLE reviews (id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL, verdict_bool INTEGER, closed INTEGER NOT NULL DEFAULT 0);

INSERT INTO repos VALUES (1,'/home/u/Hacking/alpha','alpha');
INSERT INTO repos VALUES (2,'/home/u/Hacking/beta','beta');
INSERT INTO repos VALUES (3,'/tmp/pytest-of-u/pytest-1/repo','fixturerepo');   -- ephemeral: must be filtered
INSERT INTO repos VALUES (4,'/private/tmp/smoke','smokerepo');                 -- ephemeral (macOS): filtered

-- alpha: two open FAILs on feat/x, one PASS (not a finding), one closed FAIL (not open)
INSERT INTO review_jobs VALUES (10,1,'feat/x');
INSERT INTO review_jobs VALUES (11,1,'feat/x');
INSERT INTO review_jobs VALUES (12,1,'feat/x');
INSERT INTO review_jobs VALUES (13,1,'feat/x');
INSERT INTO reviews VALUES (100,10,0,0);   -- open FAIL
INSERT INTO reviews VALUES (101,11,0,0);   -- open FAIL
INSERT INTO reviews VALUES (102,12,1,0);   -- PASS  (verdict_bool=1) -> excluded
INSERT INTO reviews VALUES (103,13,0,1);   -- closed FAIL            -> excluded

-- beta: one open FAIL on main
INSERT INTO review_jobs VALUES (20,2,'main');
INSERT INTO reviews VALUES (200,20,0,0);   -- open FAIL

-- fixture/ephemeral repos: open FAILs that MUST NOT appear in the backlog
INSERT INTO review_jobs VALUES (30,3,'main');
INSERT INTO reviews VALUES (300,30,0,0);
INSERT INTO review_jobs VALUES (40,4,'main');
INSERT INTO reviews VALUES (400,40,0,0);
SQL

# --- the JSON helper: exactly the 3 real open FAILs, fixtures filtered --------
json=$(python3 "$LIST_ALL" --json); rc=$?
assert_rc 0 "$rc" "list-all --json exits 0 on a readable DB"
count=$(printf '%s' "$json" | jq 'length')
assert_eq "3" "$count" "backlog has exactly the 3 real open FAILs (PASS + closed + 2 fixture-repo FAILs excluded)"
ids=$(printf '%s' "$json" | jq -c '[.[].id] | sort')
assert_eq "[100,101,200]" "$ids" "backlog returns the open-FAIL review ids across repos/branches"
assert_not_contains "$json" "fixturerepo" "ephemeral /tmp/pytest repo is filtered from the backlog"
assert_not_contains "$json" "smokerepo"   "ephemeral /private/tmp repo is filtered from the backlog"

# --- the human-readable helper -----------------------------------------------
human=$(python3 "$LIST_ALL"); rc=$?
assert_rc 0 "$rc" "list-all exits 0 on a readable DB (human output)"
assert_contains "$human" "3 open FAIL" "human summary counts the 3 open FAILs"
assert_contains "$human" "alpha" "human summary names repo alpha"
assert_contains "$human" "beta" "human summary names repo beta"
assert_contains "$human" "feat/x" "human summary names the branch"
assert_contains "$human" "active-vs-stale" "human summary carries the active-vs-stale cleanup nudge"
assert_not_contains "$human" "fixturerepo" "human summary excludes the ephemeral fixture repo"

# --- empty backlog (all closed) -> clean 'all clear', rc 0 -------------------
sqlite3 "$DB" "UPDATE reviews SET closed=1;"
out=$(python3 "$LIST_ALL"); rc=$?
assert_rc 0 "$rc" "list-all exits 0 when backlog is empty"
assert_contains "$out" "All clear" "empty backlog prints an all-clear line"
empty_json=$(python3 "$LIST_ALL" --json)
assert_eq "[]" "$empty_json" "empty backlog --json is []"
sqlite3 "$DB" "UPDATE reviews SET closed=0 WHERE id IN (100,101,200);"   # restore

# --- missing DB -> rc 1 (couldn't look, distinct from 'all clear') -----------
mv "$DB" "$DB.bak"
out=$(python3 "$LIST_ALL" 2>/dev/null); rc=$?
assert_rc 1 "$rc" "list-all exits 1 when the DB is unreadable (distinct from empty)"
mv "$DB.bak" "$DB"

# --- the gate's NON-BLOCKING cross-branch surface ----------------------------
# Stand up a clean repo on a branch with NO open FAILs of its own, but other
# branches in the DB DO have FAILs. The gate must ALLOW (no permissionDecision)
# while surfacing the backlog as additionalContext.
clean_repo="$tmp/clean"; mkdir -p "$clean_repo"
git -C "$clean_repo" init -q -b feat/clean
clean_root=$(git -C "$clean_repo" rev-parse --show-toplevel)
# Register this repo+branch in the DB with only a PASS review, so the gate's
# current-branch check (via the stub roborev `list`) finds nothing to deny on.
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
# Stub roborev: `list --json ... ` for the CURRENT branch returns [] (clean), so
# the gate reaches the allow path; the gate's cross-branch surface reads the DB
# directly (not via this stub).
cat > "$HOME/.local/bin/roborev" <<'BIN'
#!/usr/bin/env bash
sub="$1"; shift || true
[[ "$sub" == "list" ]] && { echo '[]'; exit 0; }
exit 0
BIN
chmod +x "$HOME/.local/bin/roborev"

payload=$(jq -n --arg cmd "git push" --arg cwd "$clean_root" \
  '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd}')
out=$(printf '%s' "$payload" | python3 "$GATE"); rc=$?
assert_rc 0 "$rc" "gate exits 0 on the allow path with a cross-branch backlog present"
# CRITICAL: no permissionDecision -> the push is NOT blocked by other branches.
has_decision=$(printf '%s' "$out" | jq 'has("hookSpecificOutput") and (.hookSpecificOutput | has("permissionDecision"))')
assert_eq "false" "$has_decision" "cross-branch backlog surface carries NO permissionDecision (non-blocking)"
ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "$ctx" "open FAIL" "gate surfaces the machine-wide backlog as additionalContext on allow"
assert_contains "$ctx" "INFORMATIONAL" "surfaced backlog is explicitly marked informational/non-blocking"
assert_contains "$ctx" "alpha" "surfaced backlog names the other-branch repos to sweep"

# When the backlog is empty, the allow path stays a SILENT clean allow (no JSON).
sqlite3 "$DB" "UPDATE reviews SET closed=1;"
out=$(printf '%s' "$payload" | python3 "$GATE"); rc=$?
assert_rc 0 "$rc" "gate exits 0 on a clean allow with an empty backlog"
assert_eq "" "$out" "gate emits nothing when the cross-branch backlog is empty (silent clean allow)"

assert_summary
