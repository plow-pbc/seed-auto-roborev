#!/usr/bin/env bash
# Unit tests for ref/post-commit — the seed-owned post-commit wrapper that skips
# enqueueing a review for pytest fixture repos (paths under .../pytest-of-<user>/)
# while still delegating to `roborev post-commit` for every other repo.
#
# Contract under test:
#   - a repo whose path contains /pytest-of-  → hook exits 0, roborev NOT called
#   - any other repo (incl. a generic mktemp /tmp repo, as verify.sh uses) → hook
#     exits 0 and DOES call `roborev post-commit`
#   - an unresolved toplevel (not a git repo) → DELEGATES (skip only confirmed pytest)
#   - the pinned $HOME/.local/bin/roborev is preferred over a PATH roborev
# The pytest skip is intentionally narrower than _roborev_hooklib's display-side
# _EPHEMERAL_ROOT_PREFIXES: a blanket /tmp skip would break verify.sh's live-loop
# proof, which commits in a generic /tmp repo and asserts the hook enqueued.
set -u
. "$(cd "$(dirname "$0")" && pwd)/testlib.sh"

REF="$(cd "$(dirname "$0")" && pwd)"
HOOK="$REF/post-commit"
[ -x "$HOOK" ]; assert_rc 0 $? "ref/post-commit is executable"
command -v git >/dev/null || { echo "git required for this test suite" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Stub roborev on PATH that records each `post-commit` invocation. A clean $HOME
# (no ~/.local/bin/roborev) forces the hook's `command -v roborev` fallback to it.
stub="$tmp/bin"; mkdir -p "$stub" "$tmp/home"
ranlog="$tmp/roborev-ran"
cat > "$stub/roborev" <<BIN
#!/bin/sh
[ "\$1" = "post-commit" ] && echo ran >> "$ranlog"
exit 0
BIN
chmod +x "$stub/roborev"

# run_hook_in <repo_root> — fire the hook with cwd=repo (as git does); its exit
# status is the hook's rc (callers capture it via rc=$?).
# git's real dir is on PATH so `git rev-parse` in the hook resolves on hosts where
# git lives outside /usr/bin (Homebrew, Nix); only the roborev lookup is stubbed.
gitdir="$(dirname "$(command -v git)")"
run_hook_in() ( cd "$1" && HOME="$tmp/home" PATH="$stub:$gitdir:/usr/bin:/bin" "$HOOK" )

# --- a pytest fixture repo → hook SKIPS enqueue ------------------------------
pyrepo="$tmp/base/pytest-of-tester/pytest-0/sources/plow"
mkdir -p "$pyrepo"; git init -q "$pyrepo"
: > "$ranlog"; run_hook_in "$pyrepo"; rc=$?
assert_rc 0 "$rc" "hook exits 0 inside a /pytest-of-/ fixture repo"
assert_eq "" "$(cat "$ranlog" 2>/dev/null)" "roborev post-commit NOT called for a pytest fixture repo"

# Non-adjacent components also skip (the comment documents `*` spanning `/`); pins
# that contract against a future edit that tightens to require adjacency.
pygap="$tmp/base/pytest-of-tester/extra/pytest-0/repo"
mkdir -p "$pygap"; git init -q "$pygap"
: > "$ranlog"; run_hook_in "$pygap"; rc=$?
assert_rc 0 "$rc" "hook exits 0 for a pytest-of-*/…/pytest-* repo (non-adjacent)"
assert_eq "" "$(cat "$ranlog" 2>/dev/null)" "roborev NOT called when pytest-of-* and pytest-* are non-adjacent"

# --- a generic mktemp repo (verify.sh-style) → hook DELEGATES ----------------
realrepo="$tmp/scratch/repo"
mkdir -p "$realrepo"; git init -q "$realrepo"
: > "$ranlog"; run_hook_in "$realrepo"; rc=$?
assert_rc 0 "$rc" "hook exits 0 inside a normal repo"
assert_eq "ran" "$(cat "$ranlog" 2>/dev/null)" "roborev post-commit IS called for a non-pytest repo"

# --- a real repo whose name merely contains pytest-of- (no pytest-<N> dir) → DELEGATES
# Pins the documented contract: only the full pytest-of-<user>/…/pytest-<N> layout
# skips; a project literally named pytest-of-tools must still be reviewed. Guards
# against a future glob loosening back to a bare `*pytest-of-*`.
pofrepo="$tmp/pytest-of-tools/repo"; mkdir -p "$pofrepo"; git init -q "$pofrepo"
: > "$ranlog"; run_hook_in "$pofrepo"; rc=$?
assert_rc 0 "$rc" "hook exits 0 for a real repo named pytest-of-*"
assert_eq "ran" "$(cat "$ranlog" 2>/dev/null)" "roborev IS called for pytest-of-* with no pytest-<N> component"

# --- unresolved toplevel (not a git repo) → DELEGATES (skip only pytest) -----
# We must not suppress review just because the path couldn't be resolved — only a
# CONFIRMED /pytest-of-/ path skips; everything else falls through to roborev.
notrepo="$tmp/notgit"; mkdir -p "$notrepo"
: > "$ranlog"; run_hook_in "$notrepo"; rc=$?
assert_rc 0 "$rc" "hook exits 0 when toplevel can't be resolved"
assert_eq "ran" "$(cat "$ranlog" 2>/dev/null)" "roborev IS called when toplevel is unresolved (delegate, don't skip)"

# --- pinned $HOME/.local/bin/roborev is preferred over a PATH roborev ---------
# Primary production path: the seed installs roborev at ~/.local/bin. Place a
# distinct stub there and confirm it — not the PATH one — is invoked.
homebin="$tmp/home/.local/bin"; mkdir -p "$homebin"; pinlog="$tmp/pinned-ran"
cat > "$homebin/roborev" <<BIN
#!/bin/sh
[ "\$1" = "post-commit" ] && echo pinned >> "$pinlog"
exit 0
BIN
chmod +x "$homebin/roborev"
: > "$pinlog"; : > "$ranlog"; run_hook_in "$realrepo"; rc=$?
assert_rc 0 "$rc" "hook exits 0 via the pinned binary"
assert_eq "pinned" "$(cat "$pinlog" 2>/dev/null)" "pinned \$HOME/.local/bin/roborev is invoked"
assert_eq "" "$(cat "$ranlog" 2>/dev/null)" "PATH roborev is NOT used when the pinned binary exists"

# --- no roborev at all (neither pinned nor on PATH) → silent no-op, exit 0 ----
# The load-bearing missing-binary guard: a host without roborev must not error.
# Use a roborev-FREE bin dir (only git) so a system-packaged roborev in /usr/bin
# can't be resolved by the hook's fallback and enqueue a junk review (the very
# noise this fixes). Clean $HOME too (no ~/.local/bin/roborev) → neither lookup hits.
freebin="$tmp/freebin"; mkdir -p "$freebin"; ln -s "$(command -v git)" "$freebin/git"
emptyhome="$tmp/emptyhome"; mkdir -p "$emptyhome"
: > "$ranlog"; : > "$pinlog"
rc=0; ( cd "$realrepo" && HOME="$emptyhome" PATH="$freebin" "$HOOK" ) || rc=$?
assert_rc 0 "$rc" "hook exits 0 when no roborev binary is found"
assert_eq "" "$(cat "$ranlog" 2>/dev/null)$(cat "$pinlog" 2>/dev/null)" "no roborev invoked when none is present"

# --- fired by a REAL `git commit` under git's hook env (GIT_DIR exported) -----
# The cases above invoke the hook directly; this proves the skip/delegate contract
# still holds when git itself runs it via core.hooksPath, with GIT_DIR/GIT_INDEX_FILE
# exported (a setup where `git rev-parse --show-toplevel` could behave differently).
# A fresh $ihome (no pinned roborev) routes through the PATH stub into $ranlog.
# core.hooksPath points at a dedicated dir holding ONLY post-commit, so git can't
# also fire some other hook-named file that ref/ might gain later.
ihome="$tmp/ihome"; mkdir -p "$ihome"
hooksdir="$tmp/hooks"; mkdir -p "$hooksdir"; cp "$HOOK" "$hooksdir/post-commit"; chmod +x "$hooksdir/post-commit"
git_commit_in() { # git_commit_in <repo> — commit with the isolated hooksdir + stub roborev
  ( cd "$1"
    git config user.email t@t; git config user.name t
    echo x > f.txt; git add f.txt
    HOME="$ihome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      PATH="$stub:$gitdir:/usr/bin:/bin" git -c core.hooksPath="$hooksdir" commit -q -m x )
}
ipy="$tmp/ibase/pytest-of-tester/pytest-1/repo"; mkdir -p "$ipy"; git init -q "$ipy"
: > "$ranlog"; git_commit_in "$ipy"
assert_eq "" "$(cat "$ranlog" 2>/dev/null)" "real git commit in a pytest repo does NOT enqueue (skip holds under git's hook env)"
ireal="$tmp/ireal/repo"; mkdir -p "$ireal"; git init -q "$ireal"
: > "$ranlog"; git_commit_in "$ireal"
assert_eq "ran" "$(cat "$ranlog" 2>/dev/null)" "real git commit in a normal repo DOES enqueue (delegate under git's hook env)"

assert_summary
