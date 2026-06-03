#!/usr/bin/env bash
# Unit suite for ref/install.sh's binary fetch — the pinned-tag + checksum gate
# (the tamper/stale-binary guarantee). Runs the REAL installer hermetically under
# a temp $HOME with a stub PATH, so no daemon/git-global/network side effects: a
# bad digest makes install.sh exit at the gate (§1b) before any of step 2+ runs,
# so we only stub the fetch surface (uname, curl, sha256sum) + a pre-seeded claude.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ref/testlib.sh
. "$HERE/testlib.sh"

# linux-x86_64 is forced via the uname stub, so the expected URL + committed sha
# are deterministic regardless of the host running `just test`. Keep in sync with
# the matching arm in install.sh (a drift here means the gate isn't being tested).
EXPECT_URL="https://github.com/plow-pbc/seed-roborev/releases/download/v0.1/roborev-linux-x86_64"
GOOD_SHA="e4af0de02926cf0d3fc38176bfc096dbef90807418274655507440b3945f1184"

# Build a hermetic sandbox: temp HOME + a stub bin dir that shadows the fetch
# surface. $1 is the digest the sha256sum stub will report (good → match, wrong
# → mismatch); $2 is the `uname -m` arch (default x86_64). Echoes the sandbox
# root; caller runs install.sh against it.
make_sandbox() {
  local reported_sha="$1" arch="${2:-x86_64}" root stub
  root="$(mktemp -d)"; stub="$root/bin"
  mkdir -p "$stub" "$root/home/.local/bin"
  # claude already present → install.sh §1a skips the `curl | bash` bootstrap.
  printf '#!/bin/sh\nexit 0\n' > "$root/home/.local/bin/claude"; chmod +x "$root/home/.local/bin/claude"
  # §3+ (daemon, install-hook) talks to the real per-user service managers and
  # escapes the $HOME sandbox. The success case dies at §2 (running the junk
  # binary) before reaching them, but that's an incidental invariant — shadow
  # the managers with no-op stubs so the run stays hermetic even if a future
  # change let §2 pass (e.g. a maintainer making the stub bytes exec-able).
  for c in systemctl launchctl pkill loginctl sleep; do
    printf '#!/bin/sh\nexit 0\n' > "$stub/$c"
  done
  # uname → Linux/<arch> so the tested arm + URL are host-independent.
  printf '#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo %s;; *) echo Linux;; esac\n' "$arch" > "$stub/uname"
  # curl → log the requested URL, write junk bytes to the -o target (the gate
  # compares digests, not real machine code, so the bytes are irrelevant).
  cat > "$stub/curl" <<CURL
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2;; http*) url="\$1"; shift;; *) shift;; esac; done
printf '%s\n' "\$url" >> "$root/curl-urls"
[ -n "\$out" ] && printf 'not-a-real-binary\n' > "\$out"
exit 0
CURL
  # sha256sum → report the configured digest in `<digest>  <file>` form, so
  # install.sh's sha256() (which cuts field 1) sees exactly what we want.
  printf '#!/bin/sh\necho "%s  $1"\n' "$reported_sha" > "$stub/sha256sum"
  chmod +x "$stub"/*
  printf '%s' "$root"
}

run_install() { # run_install <sandbox-root> ; sets RC
  local root="$1"
  HOME="$root/home" PATH="$root/bin:/usr/bin:/bin" bash "$HERE/install.sh" >/dev/null 2>&1
  RC=$?
}

# --- Case 1: tampered/stale asset (wrong digest) → fail-closed -----------------
root="$(make_sandbox deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef)"
run_install "$root"
assert_eq "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)" "wrong digest exits nonzero"
assert_eq "$EXPECT_URL" "$(cat "$root/curl-urls" 2>/dev/null)" "fetches the pinned-tag URL"
assert_eq "0" "$([ -e "$root/home/.local/bin/roborev" ] && echo 1 || echo 0)" "no binary installed on mismatch"
assert_eq "0" "$([ -e "$root/home/.local/bin/roborev.tmp" ] && echo 1 || echo 0)" "temp download cleaned up on mismatch"
rm -rf "$root"

# --- Case 2: matching digest → binary is accepted + installed -----------------
# install.sh then tries to *run* the (junk) binary at step 2 and dies, but the
# gate has already passed and installed it — which is what this case asserts.
root="$(make_sandbox "$GOOD_SHA")"
run_install "$root"
assert_eq "1" "$([ -x "$root/home/.local/bin/roborev" ] && echo 1 || echo 0)" "matching digest installs an executable binary"
assert_eq "0" "$([ -e "$root/home/.local/bin/roborev.tmp" ] && echo 1 || echo 0)" "temp download cleaned up on success"
rm -rf "$root"

# --- Case 3: unsupported arch → fail-closed (no pinned checksum) ---------------
# Hits install.sh's `*)` arm before any fetch — must stop without touching curl
# or installing anything.
root="$(make_sandbox "$GOOD_SHA" riscv64)"
run_install "$root"
assert_eq "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)" "unsupported arch exits nonzero"
assert_eq "0" "$([ -e "$root/curl-urls" ] && echo 1 || echo 0)" "unsupported arch never fetches"
assert_eq "0" "$([ -e "$root/home/.local/bin/roborev" ] && echo 1 || echo 0)" "unsupported arch installs nothing"
rm -rf "$root"

assert_summary
