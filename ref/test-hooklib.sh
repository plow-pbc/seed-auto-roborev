#!/usr/bin/env bash
# Unit tests for ref/roborev-hooklib.sh — the shared git-hook library. Drives
# its functions under a controlled $HOME/$PATH; no daemon, no install required.
set -u

# Shared assert harness (assert_eq/_rc/_contains/_not_contains/fail/_summary).
. "$(cd "$(dirname "$0")" && pwd)/testlib.sh"

LIB="$(cd "$(dirname "$0")" && pwd)/roborev-hooklib.sh"
[ -f "$LIB" ]; assert_rc 0 $? "hooklib exists"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
. "$LIB"  # defines roborev_or_warn + chain_repo_hook (visible to () subshells)

# --- roborev_or_warn: present -> echoes the seed path, rc 0 ------------------
ok_home="$tmp/ok"; mkdir -p "$ok_home/.local/bin"
printf '#!/bin/sh\n' > "$ok_home/.local/bin/roborev"; chmod +x "$ok_home/.local/bin/roborev"
out=$( ( export HOME="$ok_home"; roborev_or_warn ) 2>/dev/null ); rc=$?
assert_rc 0 "$rc" "roborev_or_warn returns 0 when the binary is present"
assert_eq "$ok_home/.local/bin/roborev" "$out" "roborev_or_warn echoes the seed-installed path"

# --- roborev_or_warn: missing -> LOUD warning on stderr, empty stdout, rc 1 --
empty_home="$tmp/empty"; mkdir -p "$empty_home"
err=$( ( export HOME="$empty_home" PATH="/nonexistent"; roborev_or_warn 2>&1 >/dev/null ) );
out=$( ( export HOME="$empty_home" PATH="/nonexistent"; roborev_or_warn 2>/dev/null ) ); rc=$?
assert_rc 1 "$rc" "roborev_or_warn returns 1 when the binary is missing"
assert_eq "" "$out" "roborev_or_warn prints nothing to stdout when missing"
assert_contains "$err" "BROKEN INSTALL" "missing roborev warns LOUDLY (not a silent no-op)"
assert_contains "$err" "ref/install.sh" "missing-roborev warning names the seed installer"

# --- roborev_findings_summary: counts only OPEN FAIL verdicts, not PASS ------
# `roborev list --open` returns unresolved rows of ANY verdict; only verdict==F
# && !closed are findings. A fake roborev returns a mixed array; assert the
# summary counts the 2 open fails and excludes the PASS + closed-fail rows.
fs_bin="$tmp/fakeroborev"
cat > "$fs_bin" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "list" ] && echo '[{"id":1,"git_ref":"aaaa1111","verdict":"F","closed":false},
  {"id":2,"git_ref":"bbbb2222","verdict":"P","closed":false},
  {"id":3,"git_ref":"cccc3333","verdict":"F","closed":true},
  {"id":4,"git_ref":"dddd4444","verdict":"F","closed":false}]'
STUB
chmod +x "$fs_bin"
out=$( roborev_findings_summary "$fs_bin" 2>&1 )
assert_contains "$out" "2 open review finding(s)" "findings summary counts only open FAIL verdicts (PASS + closed-FAIL excluded)"
assert_not_contains "$out" "bbbb2222" "findings summary excludes PASS-verdict rows from the list"
assert_not_contains "$out" "cccc3333" "findings summary excludes closed-FAIL rows from the list"

# Clean branch (only PASS open) -> the '0 open findings ✓' line, not 'finding(s)'.
fs_clean="$tmp/fakeroborev_clean"
cat > "$fs_clean" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "list" ] && echo '[{"id":9,"git_ref":"eeee5555","verdict":"P","closed":false}]'
STUB
chmod +x "$fs_clean"
out=$( roborev_findings_summary "$fs_clean" 2>&1 )
assert_contains "$out" "0 open findings on this branch ✓" "findings summary prints the clean line when only PASS rows are open"

# Repo+branch scoping is delegated to roborev's `--repo`/`--branch` (server-side).
# Assert the helper passes BOTH: a stub that honors both returns only this repo's
# rows on this branch — so a sibling-branch fail AND a sibling-repo fail are both
# excluded. (Dropping either flag would leave one of them in the count.)
fs_repo="$tmp/fsrepo"; git init -q -b feature/x "$fs_repo"
fs_root="$(git -C "$fs_repo" rev-parse --show-toplevel)"
fs_scoped="$tmp/fakeroborev_scoped"
printf '#!/usr/bin/env bash\nFS_ROOT=%q\n' "$fs_root" > "$fs_scoped"
cat >> "$fs_scoped" <<'STUB'
repo=""; branch=""; shift
while [ $# -gt 0 ]; do case "$1" in --repo) repo="$2"; shift 2;; --branch) branch="$2"; shift 2;; *) shift;; esac; done
all="[{\"id\":10,\"git_ref\":\"r10\",\"verdict\":\"F\",\"closed\":false,\"branch\":\"feature/x\",\"repo\":\"$FS_ROOT\"},
  {\"id\":11,\"git_ref\":\"r11\",\"verdict\":\"F\",\"closed\":false,\"branch\":\"other-branch\",\"repo\":\"$FS_ROOT\"},
  {\"id\":12,\"git_ref\":\"r12\",\"verdict\":\"F\",\"closed\":false,\"branch\":\"feature/x\",\"repo\":\"/other/sibling/repo\"}]"
printf '%s' "$all" | jq -c --arg r "$repo" --arg b "$branch" '[.[]|select((($r=="") or .repo==$r) and (($b=="") or .branch==$b))]'
STUB
chmod +x "$fs_scoped"
out=$( ( cd "$fs_repo"; roborev_findings_summary "$fs_scoped" ) 2>&1 )
assert_contains "$out" "1 open review finding(s)" "findings summary passes --repo AND --branch (sibling repo + sibling branch both excluded)"
assert_not_contains "$out" "r11" "findings summary excludes sibling-branch fail rows (via --branch)"
assert_not_contains "$out" "r12" "findings summary excludes sibling-repo fail rows (via --repo)"

# --- chain_repo_hook: execs a repo-local hook of the same name --------------
repo="$tmp/repo"; mkdir -p "$repo"; ( cd "$repo" && git init -q )
mkdir -p "$repo/.git/hooks"
printf '#!/usr/bin/env bash\necho LOCAL_HOOK_RAN\n' > "$repo/.git/hooks/pre-commit"
chmod +x "$repo/.git/hooks/pre-commit"
out=$( ( cd "$repo"; chain_repo_hook pre-commit "/not/the/repo/hook"; echo REACHED_AFTER ) 2>&1 )
assert_contains "$out" "LOCAL_HOOK_RAN" "chain_repo_hook execs the repo-local hook"
case "$out" in *REACHED_AFTER*) assert_rc 1 0 "chain_repo_hook exec replaces the process (no fall-through)";; *) assert_rc 0 0 "chain_repo_hook exec replaces the process (no fall-through)";; esac

# --- chain_repo_hook: no repo-local hook -> returns, caller continues --------
repo2="$tmp/repo2"; mkdir -p "$repo2"; ( cd "$repo2" && git init -q )
out=$( ( cd "$repo2"; chain_repo_hook pre-commit "/self"; echo CONTINUED ) 2>&1 )
assert_contains "$out" "CONTINUED" "chain_repo_hook returns when no repo-local hook exists"

# --- chain_repo_hook restores the caller's PATH for the exec'd repo hook -----
# The fix is `PATH="$ROBOREV_ORIG_PATH" exec "$repo_hook"`; a regression dropping
# it would run the chained hook under the truncated 5-dir PATH. Source the lib
# with a sentinel dir on PATH (which the sanitized PATH never contains) and
# assert the exec'd repo-local hook sees it — i.e. the caller's PATH was restored.
repo4="$tmp/repo4"; mkdir -p "$repo4"; ( cd "$repo4" && git init -q )
printf '#!/usr/bin/env bash\necho "CHAINED_PATH=$PATH"\n' > "$repo4/.git/hooks/pre-commit"
chmod +x "$repo4/.git/hooks/pre-commit"
out=$( ( PATH="$tmp/SENTINEL_BIN:$PATH"; . "$LIB"; cd "$repo4"; chain_repo_hook pre-commit "/not/self" ) 2>&1 )
assert_contains "$out" "$tmp/SENTINEL_BIN" "chain_repo_hook restores the caller's PATH for the exec'd repo hook (not the sanitized 5-dir PATH)"

# --- chain_repo_hook: recursion guard — repo-local hook IS this wrapper ------
# When core.hooksPath and a repo-local .git/hooks copy resolve to the same file,
# the `-ef self` guard must stop the wrapper exec-ing itself into an infinite
# loop. Pass self = the repo-local hook path and assert it falls through.
repo3="$tmp/repo3"; mkdir -p "$repo3"; ( cd "$repo3" && git init -q )
printf '#!/usr/bin/env bash\necho SHOULD_NOT_EXEC\n' > "$repo3/.git/hooks/pre-commit"
chmod +x "$repo3/.git/hooks/pre-commit"
out=$( ( cd "$repo3"; chain_repo_hook pre-commit "$repo3/.git/hooks/pre-commit"; echo FELL_THROUGH ) 2>&1 )
assert_contains "$out" "FELL_THROUGH" "chain_repo_hook recursion guard: does NOT exec when repo-local hook -ef self"
case "$out" in *SHOULD_NOT_EXEC*) fail "chain_repo_hook exec'd itself — recursion guard broken";; esac

assert_summary
