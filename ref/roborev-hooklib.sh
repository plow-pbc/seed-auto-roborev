#!/usr/bin/env bash
# Shared library for the SEED-owned git hooks (post-commit + pre-commit).
# SOURCED, never executed directly (git only runs files named like a hook, so
# this name is ignored). Owns the three things both hooks need:
#   1. a sanitized PATH (so a checkout-controlled bin/roborev|git|jq can't run
#      during a hook — the hooks fire in every repo, including untrusted ones);
#   2. roborev resolution + a LOUD failure when it's missing (the SEED
#      guarantees roborev is installed, so a missing binary is a broken install
#      and every commit silently going unreviewed is the exact failure the
#      always-on confirmation lines exist to prevent);
#   3. chaining to a repo-local hook of the same name.

# Fixed, trusted PATH (mirrors the daemon service's PATH). Exported so the
# git/jq/head calls in the hook bodies also resolve from trusted dirs only.
# Save the caller's PATH first so a chained repo-local hook is exec'd with the
# operator's full environment (nvm/pyenv/venv/asdf shims, …), not this truncated
# one — sanitizing our own body must not regress an existing repo-local hook.
ROBOREV_ORIG_PATH="$PATH"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# Echo the resolved roborev path (stdout) on success; on a missing binary, print
# a loud broken-install line to stderr and return 1 so the caller skips its
# roborev body but still chains the repo-local hook. Re-resolves per call (under
# the current $HOME/$PATH) so it stays testable.
roborev_or_warn() {
  local rb="$HOME/.local/bin/roborev"
  [ -x "$rb" ] || rb="$(command -v roborev || true)"
  if [ -x "$rb" ]; then printf '%s' "$rb"; return 0; fi
  echo "roborev: BROKEN INSTALL — binary not found; commits on this machine are NOT being reviewed. Re-run the seed installer: bash <seed-roborev>/ref/install.sh" >&2
  return 1
}

# Print the pre-commit open-findings summary to stderr: the count + short list of
# OPEN FAIL-verdict reviews on THIS repo+branch, or the clean line. Scoped and
# filtered to match the Claude bridge exactly so the two surfaces agree:
#   - pass `--repo`/`--branch` (the bridge's scoping; `roborev list --open` alone
#     is not reliably branch-scoped, and the wording claims "on this branch");
#   - keep only `verdict == "F" && !closed` (`--open` includes PASS rows, which
#     are NOT findings — counting them raw over-reports on a clean branch);
#   - re-check the branch in jq as defense-in-depth (refs/heads/ normalized; a
#     row missing the field falls back to the server-side `--branch` scoping).
roborev_findings_summary() {  # roborev_findings_summary <roborev-path>
  local rb="$1" fails n root branch
  root="$(git rev-parse --show-toplevel 2>/dev/null)"
  branch="$(git branch --show-current 2>/dev/null)"
  fails="$("$rb" list --open --json ${root:+--repo "$root"} ${branch:+--branch "$branch"} 2>/dev/null \
    | jq -c --arg b "$branch" '[.[] | select(.verdict=="F" and (.closed | not)
        and ((.branch // $b) | sub("^refs/heads/";"") == $b))]' 2>/dev/null || echo '[]')"
  n="$(printf '%s' "$fails" | jq 'length' 2>/dev/null || echo 0)"
  if [ "${n:-0}" -gt 0 ]; then
    echo "roborev: ${n} open review finding(s) on this branch — review before committing more:" >&2
    printf '%s' "$fails" | jq -r '.[] | "  \(.id)  \(.git_ref[0:8] // "?")"' 2>/dev/null | head -20 >&2
    [ "$n" -gt 20 ] && echo "  … (showing 20 of ${n}; run 'roborev list' for the rest)" >&2
    echo "(roborev show <id> for details; this is a non-blocking warning)" >&2
  else
    echo "roborev: 0 open findings on this branch ✓" >&2
  fi
}

# Exec a repo-local hook of the same name, if present and not this wrapper
# itself. Replaces the process, so call it LAST in each hook.
chain_repo_hook() {  # chain_repo_hook <hook-name> <self-path> [hook args...]
  local name="$1" self="$2"; shift 2
  local git_dir repo_hook
  git_dir="$(git rev-parse --git-dir 2>/dev/null || true)"
  repo_hook="${git_dir:+$git_dir/hooks/$name}"
  if [ -n "$repo_hook" ] && [ -x "$repo_hook" ] && ! [ "$repo_hook" -ef "$self" ]; then
    PATH="$ROBOREV_ORIG_PATH" exec "$repo_hook" "$@"
  fi
}
