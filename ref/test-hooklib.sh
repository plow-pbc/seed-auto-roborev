#!/usr/bin/env bash
# Unit tests for ref/roborev-hooklib.sh — the shared git-hook library. Drives
# its functions under a controlled $HOME/$PATH; no daemon, no install required.
set -u

ASSERT_PASS=0 ASSERT_FAIL=0
assert_eq()       { if [ "$1" = "$2" ]; then ASSERT_PASS=$((ASSERT_PASS+1)); else ASSERT_FAIL=$((ASSERT_FAIL+1)); printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$3" "$1" "$2" >&2; fi; }
assert_rc()       { if [ "$1" = "$2" ]; then ASSERT_PASS=$((ASSERT_PASS+1)); else ASSERT_FAIL=$((ASSERT_FAIL+1)); printf 'FAIL: %s (rc expected %s got %s)\n' "$3" "$1" "$2" >&2; fi; }
assert_contains() { case $1 in *"$2"*) ASSERT_PASS=$((ASSERT_PASS+1));; *) ASSERT_FAIL=$((ASSERT_FAIL+1)); printf 'FAIL: %s\n  %q does not contain %q\n' "$3" "$1" "$2" >&2;; esac; }
assert_summary()  { printf '%s passed, %s failed\n' "$ASSERT_PASS" "$ASSERT_FAIL"; [ "$ASSERT_FAIL" -eq 0 ]; }

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
