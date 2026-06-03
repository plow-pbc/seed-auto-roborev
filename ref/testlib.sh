#!/usr/bin/env bash
# Shared assert harness for the seed-roborev unit suites (sourced, not executed;
# mirrors claude-config's tests/assert.sh). Each helper bumps ASSERT_PASS/FAIL;
# assert_summary prints the tally and exits non-zero if any assertion failed.
ASSERT_PASS=0 ASSERT_FAIL=0
assert_eq() { # assert_eq <expected> <actual> <msg>
  if [ "$1" = "$2" ]; then ASSERT_PASS=$((ASSERT_PASS+1));
  else ASSERT_FAIL=$((ASSERT_FAIL+1)); printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$3" "$1" "$2" >&2; fi
}
assert_rc() { # assert_rc <expected-rc> <actual-rc> <msg>
  if [ "$1" = "$2" ]; then ASSERT_PASS=$((ASSERT_PASS+1));
  else ASSERT_FAIL=$((ASSERT_FAIL+1)); printf 'FAIL: %s (rc expected %s got %s)\n' "$3" "$1" "$2" >&2; fi
}
assert_contains() { # assert_contains <haystack> <needle> <msg>
  case $1 in *"$2"*) ASSERT_PASS=$((ASSERT_PASS+1));;
    *) ASSERT_FAIL=$((ASSERT_FAIL+1)); printf 'FAIL: %s\n  %q does not contain %q\n' "$3" "$1" "$2" >&2;; esac
}
assert_not_contains() { # assert_not_contains <haystack> <needle> <msg>
  case $1 in *"$2"*) ASSERT_FAIL=$((ASSERT_FAIL+1)); printf 'FAIL: %s\n  %q unexpectedly contains %q\n' "$3" "$1" "$2" >&2;;
    *) ASSERT_PASS=$((ASSERT_PASS+1));; esac
}
fail() { ASSERT_FAIL=$((ASSERT_FAIL+1)); printf 'FAIL: %s\n' "$1" >&2; }
assert_summary() { printf '%s passed, %s failed\n' "$ASSERT_PASS" "$ASSERT_FAIL"; [ "$ASSERT_FAIL" -eq 0 ]; }
