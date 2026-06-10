#!/usr/bin/env python3
"""Shared helpers for the seed's three Claude-Code PreToolUse[Bash] hooks:

  - roborev-pre-commit-context.py  — WARNS (injects open fail-verdict reviews
    into context before `git commit`); never blocks.
  - roborev-pre-push-gate.py       — DENIES a `git push` while the CURRENT branch
    has open fail-verdict reviews (after waiting for in-flight ones).
  - roborev-pre-checkout-gate.py   — DENIES a `git checkout`/`git switch` to
    ANOTHER branch while the branch you're LEAVING has open fail-verdict reviews
    (so findings can't be stranded by switching away). File restores
    (`git checkout -- f`, `git restore …`) are NOT gated — see
    `_is_branch_switch_args`.

All surfaces must agree on three things, so they live here in exactly one place:
  1. the command parser (is this a real `git <subcommand>` and which cwd?),
  2. roborev/git discovery,
  3. the DEFINITION of an "outstanding finding" (`_is_open_fail` + `_list_jobs`).

Underscore module name = importable from a sibling hook (the hyphenated hook
filenames are not valid Python module names). A hook runs with `sys.path[0]` set
to its own directory, so `from _roborev_hooklib import ...` resolves with no
sys.path hacks — the installer drops this file next to both hooks.

This is NOT a security boundary. The command parser is a best-effort convenience
on operator-controlled machines; a few wrapped invocations (`ENV=x git commit`,
`cd d && git commit` from a non-repo cwd) intentionally no-op rather than growing
a shell emulator (settled across the #2 review's parser-probe rounds). roborev's
own git hooks fire regardless of what this hook recognizes.
"""
from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
from pathlib import Path


# The seed installs roborev here (ref/install.sh). Trust that path first; fall
# back to PATH for a dev who keeps it elsewhere.
SEEDED_ROBOREV = Path.home() / ".local" / "bin" / "roborev"


def _emit_hook(extra: dict) -> None:
    """Print a PreToolUse hook result — `extra` merged into the
    `hookSpecificOutput` envelope all three hooks share (so a future envelope
    tweak has ONE writer). The bridge passes `additionalContext`; the gates pass
    `permissionDecision` + `permissionDecisionReason` via `_deny`."""
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", **extra}}))


def _deny(reason: str) -> int:
    """Emit a PreToolUse permission DENY with `reason`, returning 0 so callers can
    `return _deny(...)` straight out of `main()`. Shared by both gates — the
    pre-push and pre-checkout gates' deny envelope is byte-identical."""
    _emit_hook({"permissionDecision": "deny", "permissionDecisionReason": reason})
    return 0

_OPERATOR_TOKENS = {"&&", "||", "|", ";", "&"}
# git's global options that take a separate argument token (`-X val`). Long
# `--opt=val` forms carry their value in the same token; the startswith("-")
# clause in _find_subcommand_idx handles them.
_GIT_GLOBAL_OPTS_WITH_ARG = {"-C", "-c"}


def _split_into_segments(cmd: str) -> list[list[str]]:
    """Tokenize `cmd` once (quote-aware) and split the token stream on shell
    operator tokens (`&&`, `||`, `|`, `;`, `&`) into per-segment token lists.

    Uses `shlex(..., punctuation_chars=True)`, which groups runs of `&|;` into
    standalone tokens while leaving quoted argument strings (`-m "x && y"`)
    intact — so an operator *inside* a quoted commit message is preserved as
    part of the argument and never splits a segment. Returns `[]` on a tokenizer
    error (unbalanced quote), which fails closed to "no git segment"."""
    try:
        lexer = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        return []
    segments: list[list[str]] = []
    current: list[str] = []
    for tok in tokens:
        if tok in _OPERATOR_TOKENS:
            segments.append(current)
            current = []
        else:
            current.append(tok)
    segments.append(current)
    return segments


def _find_subcommand_idx(tokens: list[str]) -> int | None:
    """Index of git's subcommand token (first non-option after `git`). Skips
    global options and option+arg pairs (-C <dir>, -c <kv>). None if absent."""
    i = 1
    while i < len(tokens):
        tok = tokens[i]
        if tok in _GIT_GLOBAL_OPTS_WITH_ARG:
            i += 2  # skip the option AND its arg
            continue
        if tok.startswith("-"):
            i += 1  # short flag w/o arg, --long, or --long=val
            continue
        return i
    return None


def _resolve_dash_c(tokens: list[str], sub_idx: int, fallback_cwd: str) -> str:
    """The cwd a `git` segment operates on: the value of the last `-C` BEFORE the
    subcommand ($VAR / ~ expanded), else `fallback_cwd`. `-C` after the
    subcommand or in another segment is git-irrelevant and ignored. Last `-C`
    wins, relative `-C` composes onto the prior one (git's own semantics)."""
    resolved = None
    for i in range(sub_idx):
        if tokens[i] == "-C" and i + 1 < sub_idx:
            path = tokens[i + 1]
            expanded = os.path.expanduser(os.path.expandvars(path))
            if "$" in expanded:
                continue  # unresolvable env var
            if not os.path.isabs(expanded):
                base = resolved if resolved else fallback_cwd
                expanded = os.path.normpath(os.path.join(base, expanded))
            resolved = expanded
    return resolved if resolved else fallback_cwd


def _resolve_repo_cwd(cmd: str, fallback_cwd: str, subcommand: str) -> str | None:
    """Validate that `cmd` contains a real `git ... <subcommand> ...` invocation
    and return the cwd it operates on, else None (`echo git ... <subcommand>` is
    a no-match — the first shlex token must be exactly `git`). `subcommand` is
    "commit" for the context hook, "push" for the gate.

    If found, returns the value of `-C` ($VAR / ~ expanded), else `fallback_cwd`."""
    for tokens in _split_into_segments(cmd):
        if not tokens or tokens[0] != "git":
            continue
        sub_idx = _find_subcommand_idx(tokens)
        if sub_idx is None or tokens[sub_idx] != subcommand:
            continue
        return _resolve_dash_c(tokens, sub_idx, fallback_cwd)
    return None


def _is_branch_switch_args(subcommand: str, args: list[str]) -> bool:
    """Decide whether a `git <subcommand> <args…>` invocation LEAVES the current
    branch for another (the thing the checkout gate cares about), vs. restoring
    files / inspecting — which must NOT be gated.

    `args` is the token list AFTER the subcommand (options + operands, in order).

    A branch switch is:
      - `git switch <name>` / `git switch -c|-C <new>`  — `switch` is *always* a
        branch operation (it can't restore files), so any `switch` that isn't a
        pure no-op gates;
      - `git checkout <branch>` / `git checkout -b|-B <new>` / `git checkout -`
        (previous branch) — a checkout whose operand is a ref, not a pathspec.

    NOT a branch switch (do NOT gate):
      - `git checkout -- <path>` (explicit pathspec after `--`),
      - `git checkout <ref> -- <path>` / `git checkout . ` / `git checkout <path>`
        where the operand is a pathspec (restore-from-tree), and
      - `git restore …` (never a branch op — not handled here; the caller only
        routes checkout/switch in).

    The hard case is bare `git checkout <arg>` with no `--`: `<arg>` could be a
    branch OR a path. We resolve it the way git's own ambiguity rule biases —
    and the way that's SAFE for this gate — as follows:
      - `-b`/`-B`/`-c`/`-C` (create-and-switch) or `-` (previous branch) present
        → unambiguously a branch switch → gate.
      - an explicit `--` (or `--pathspec-from-file`) → file op → do NOT gate.
      - exactly one non-option operand and NO `--` → treat as a BRANCH ref and
        gate. This is the deliberate call: `git checkout <oneword>` reads as "go
        to branch <oneword>" in agent usage; the rare `git checkout <file>` to
        discard one file's changes is virtually always written with the explicit
        `git checkout -- <file>` / `git restore <file>` (or `git checkout .`)
        forms, which we DON'T gate. We accept that a literal bare
        `git checkout somefile.py` MIGHT be over-gated (denied) when the branch
        has open fails — a safe failure (the agent restores via `git restore` /
        `git checkout --`), never an under-gate that lets a real switch slip.
      - two-or-more non-option operands, OR a single operand of `.`  → pathspec
        restore (`git checkout <ref> -- <paths>` collapses to ≥2 operands once
        `--` is stripped; `git checkout .` is the whole-tree restore) → do NOT
        gate.

    Pure-inspection / no-operand forms (`git checkout` alone, `git switch`
    alone) carry no destination branch → not a switch → do NOT gate."""
    create_flags = {"-b", "-B", "-c", "-C"}
    has_create = any(a in create_flags for a in args)
    has_dashdash = "--" in args
    has_pathspec_from_file = any(
        a == "--pathspec-from-file" or a.startswith("--pathspec-from-file=")
        for a in args
    )
    # Operands = non-option tokens before any `--` (everything after `--` is a
    # pathspec by definition). Create-flag VALUES (`-b <new>`) are operands of
    # the flag, not the switch target, but their presence already forces a gate
    # via has_create, so we don't special-case them out of the operand count.
    operands = []
    for a in args:
        if a == "--":
            break
        if not a.startswith("-"):
            operands.append(a)

    if subcommand == "switch":
        # `switch` is exclusively a branch operation. Gate unless it's the bare
        # no-op (`git switch` with no branch and no -c/-C target). `git switch -`
        # (previous branch) reads `-` as an option token, so it's filtered out of
        # `operands` — handle it explicitly, mirroring the checkout path below.
        return has_create or "-" in args or bool(operands)

    # subcommand == "checkout"
    if has_dashdash or has_pathspec_from_file:
        return False                       # explicit file-restore form
    if has_create:
        return True                        # -b/-B create-and-switch
    if "-" in args:
        return True                        # `git checkout -` → previous branch
    if len(operands) == 1 and operands[0] != ".":
        return True                        # bare single ref → treat as branch
    return False                           # 0 operands, `.`, or ≥2 → not a switch


def _branch_switch_cwd(cmd: str, fallback_cwd: str) -> str | None:
    """Return the cwd of a real branch-switching `git checkout`/`git switch`
    segment in `cmd`, else None. Mirrors `_resolve_repo_cwd` (first shlex token
    must be exactly `git`; `-C` before the subcommand sets the cwd) but matches
    EITHER subcommand and additionally requires `_is_branch_switch_args` to
    classify it as a branch switch — so file restores (`git checkout -- f`,
    `git restore …`) and pure-inspection forms no-op."""
    for tokens in _split_into_segments(cmd):
        if not tokens or tokens[0] != "git":
            continue
        sub_idx = _find_subcommand_idx(tokens)
        if sub_idx is None or tokens[sub_idx] not in ("checkout", "switch"):
            continue
        if not _is_branch_switch_args(tokens[sub_idx], tokens[sub_idx + 1:]):
            continue
        return _resolve_dash_c(tokens, sub_idx, fallback_cwd)
    return None


def _find_roborev() -> str | None:
    """Resolve roborev: the seed-installed path (`~/.local/bin/roborev`) first,
    then PATH for a dev who keeps it elsewhere. None if none is reachable —
    a broken install, which the commit hook surfaces as a warning and the push
    gate treats as allow (don't hard-block a push on a broken dev install)."""
    if SEEDED_ROBOREV.is_file() and os.access(SEEDED_ROBOREV, os.X_OK):
        return str(SEEDED_ROBOREV)
    found = shutil.which("roborev")
    return found if found and os.path.isabs(found) else None


def _find_git() -> str | None:
    return shutil.which("git")


def _git_stdout(cwd: str, *args: str) -> str:
    """Run `git <args>` in `cwd`; trimmed stdout on success, "" else. Swallows
    all subprocess/OS errors so the hook stays best-effort."""
    git = _find_git()
    if git is None:
        return ""
    try:
        r = subprocess.run(
            [git, *args],
            cwd=cwd, capture_output=True, text=True, timeout=2,
        )
    except (subprocess.SubprocessError, OSError):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def _inside_git_repo(cwd: str) -> bool:
    return _git_stdout(cwd, "rev-parse", "--is-inside-work-tree") == "true"


def _current_branch(cwd: str) -> str:
    return _git_stdout(cwd, "branch", "--show-current")


def _git_toplevel(cwd: str) -> str:
    """Canonical repo root the daemon stored as `repos.root_path`."""
    return _git_stdout(cwd, "rev-parse", "--show-toplevel")


# roborev's TERMINAL review statuses (a review that has finished running). The
# pre-push gate denylists these to decide "in flight" — anything NOT terminal
# (queued, running, or any transient/future status) is treated as still-running
# so the gate waits on it and stays fail-closed. Keep in sync with the terminal
# set in `verify.sh` / `SEED.md`.
TERMINAL_STATUSES = ("done", "passed", "failed")


def _in_flight(jobs: list[dict]) -> list[dict]:
    """Reviews the daemon hasn't finished. Denylists TERMINAL_STATUSES rather
    than allowlisting {queued,running}, so ANY unrecognized non-terminal status
    (an enqueue/`pending`/`starting` state, or a future one) counts as in-flight
    — keeping both gates fail-CLOSED on an unknown status. A row with no/null
    status is also treated as in-flight. Drifted non-dict rows are ignored
    (best-effort, like `_is_open_fail`).

    A `closed` row is NOT in flight even mid-run: a `roborev close`'d review can
    never become an outstanding finding (`_is_open_fail` requires `not closed`),
    so neither gate should wait on / block over it."""
    return [j for j in jobs
            if isinstance(j, dict) and not j.get("closed", False)
            and j.get("status") not in TERMINAL_STATUSES]


def _is_open_fail(job: object) -> bool:
    """THE shared definition of an "outstanding finding" both surfaces gate on:
    a fail-verdict review that hasn't been acknowledged. `roborev list --open`
    means "unresolved, ANY verdict" and includes PASS rows, so `verdict == "F"`
    is load-bearing; `not closed` drops reviews acknowledged via `roborev close`.
    Tolerates a drifted/non-dict row (returns False) so callers fail soft."""
    return (
        isinstance(job, dict)
        and job.get("verdict") == "F"
        and not job.get("closed", False)
    )


def _list_jobs(roborev: str, repo_root: str, branch: str) -> list[dict] | None:
    """Full job list for this repo+branch via the public `roborev list` CLI.
    Repo+branch scoping is delegated to `--repo`/`--branch` (verified to filter
    server-side) — the same trust we place in the `--json`/`verdict` contract,
    rather than re-implementing branch comparison client-side.

    Returns `None` on ANY failure (subprocess/OS error, nonzero exit, JSON error,
    unexpected non-list shape) — DISTINCT from `[]`, a cleanly-parsed empty
    result. The distinction is load-bearing for the fail-closed push gate: it
    DENIES on `None` (couldn't determine review state) instead of mistaking a
    wedged daemon or timed-out `list` for "no findings" and waving an unreviewed
    push through. The warn-only commit bridge maps `None`→`[]` (under-reporting a
    non-blocking warning is benign). Mirrors the empty-vs-broken handling the git
    hooks use.

    A cleanly-parsed JSON `null` (rc 0) means "no jobs for this repo+branch" — it
    is what `roborev list` prints for a repo/branch it has never reviewed (a fresh
    or freshly-cloned repo, a brand-new branch). That is empty, NOT a read
    failure, so it maps to `[]` — otherwise the gate would deny every push in any
    repo roborev hasn't reviewed yet (the daemon is fine; there's simply nothing
    to find)."""
    try:
        r = subprocess.run(
            [roborev, "list", "--json", "--repo", repo_root, "--branch", branch],
            cwd=repo_root, capture_output=True, text=True, timeout=5,
        )
    except (subprocess.SubprocessError, OSError):
        return None
    if r.returncode != 0:
        return None
    try:
        data = json.loads(r.stdout)
    except (json.JSONDecodeError, ValueError):
        return None
    if data is None:        # roborev prints JSON `null`, not `[]`, for a never-
        return []           # reviewed repo+branch — a clean "no jobs", not a fault.
    return data if isinstance(data, list) else None
