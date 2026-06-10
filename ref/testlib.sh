#!/usr/bin/env bash
# Shared assert harness for the seed-auto-roborev unit suites (sourced, not executed;
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

# --- shared roborev fake-CLI + fixture harness (gate suites) ------------------
# The pre-push and pre-checkout gate suites both mock $HOME with a fake roborev
# at the seed-installed path (~/.local/bin/roborev) that answers `roborev list
# --json --repo R --branch B` off a per-repo JSON fixture, plus the same fixture
# I/O + payload helpers. One copy here; each suite adds only its gate-specific
# bits. Callers must export `HOME`, `FIXTURES`, and `tmp` (a writable scratch
# dir) before calling, and prepend "$HOME/.local/bin" to PATH.

# roborev_fixture_path <repo_root> -> the fixture file for that repo (sha256 of
# the root; matches the fake CLI's keying so write+read agree).
roborev_fixture_path() { printf '%s/%s.json' "$FIXTURES" "$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"; }
# write_fixture <repo_root> <json_array> — the job list `list` returns for that repo.
write_fixture() { printf '%s' "$2" > "$(roborev_fixture_path "$1")"; }
is_deny() { printf '%s' "$1" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; }

# new_repo <fixture_json> -> echoes a throwaway git repo root on branch feature/x
# with its fixture written. (The branch name is the leaving/current branch both
# gates scope to.)
new_repo() {
  local d root; d="$(mktemp -d "$tmp/repo.XXXXXX")"
  git init -q -b feature/x "$d"
  root=$(git -C "$d" rev-parse --show-toplevel)
  write_fixture "$root" "$1"
  printf '%s' "$root"
}

# run_hook <hook_path> <repo_root> <git_cmd> — fire a Bash-tool payload (command
# + cwd) through the hook and echo its stdout.
run_hook() {
  local hook="$1" root="$2" cmd="$3"
  jq -n --arg cmd "$cmd" --arg cwd "$root" \
    '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd}' | python3 "$hook"
}

# setup_fake_roborev [with_wait] — install the fake roborev binary into
# $HOME/.local/bin/roborev. Always handles `list` (per-repo fixture array; a
# `listfail.<repohash>` sentinel makes it exit nonzero to simulate a wedged
# daemon). With the `with_wait` arg it also handles `wait --quiet --job N…`
# (flips each job to status=done + its eventual `.final` verdict, unless a
# `nofinish.<id>` sentinel keeps it in flight) — only the push gate needs that.
setup_fake_roborev() {
  local with_wait="${1:-}"
  mkdir -p "$HOME/.local/bin"
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
BIN
  if [[ "$with_wait" == "with_wait" ]]; then
    cat >> "$HOME/.local/bin/roborev" <<'BIN'
if [[ "$sub" == "wait" ]]; then
  ids=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --quiet) shift;;
      --job) shift; while [[ $# -gt 0 && "$1" != --* ]]; do ids+=("$1"); shift; done;;
      *) shift;;
    esac
  done
  for id in "${ids[@]}"; do
    [[ -f "$FIXTURES/nofinish.$id" ]] && continue
    for f in "$FIXTURES"/*.json; do
      [[ -f "$f" ]] || continue
      t="$f.t"; jq --argjson id "$id" \
        'map(if .id==$id then .status="done" | (if .final then .verdict=.final else . end) else . end)' \
        "$f" > "$t" && mv "$t" "$f"
    done
  done
  exit 0
fi
BIN
  fi
  printf 'exit 0\n' >> "$HOME/.local/bin/roborev"
  chmod +x "$HOME/.local/bin/roborev"
}
