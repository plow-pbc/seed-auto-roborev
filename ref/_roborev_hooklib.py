#!/usr/bin/env python3
"""Shared helpers for the seed's two Claude-Code PreToolUse[Bash] hooks:

  - roborev-pre-commit-context.py  — WARNS (injects open fail-verdict reviews
    into context before `git commit`); never blocks.
  - roborev-pre-push-gate.py       — DENIES a `git push` while the branch has
    open fail-verdict reviews (after waiting for in-flight ones).

Both surfaces must agree on three things, so they live here in exactly one place:
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
import sqlite3
import subprocess
from pathlib import Path


# The seed installs roborev here (ref/install.sh). Trust that path first; fall
# back to PATH for a dev who keeps it elsewhere.
SEEDED_ROBOREV = Path.home() / ".local" / "bin" / "roborev"

# The daemon's machine-wide review store (one DB per machine). The cross-branch
# backlog view reads it directly — the `roborev list` CLI has no all-repos /
# all-branches mode, so there's no public seam to delegate to for the backlog.
ROBOREV_DB = Path.home() / ".roborev" / "reviews.db"

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


def _resolve_repo_cwd(cmd: str, fallback_cwd: str, subcommand: str) -> str | None:
    """Validate that `cmd` contains a real `git ... <subcommand> ...` invocation
    and return the cwd it operates on, else None (`echo git ... <subcommand>` is
    a no-match — the first shlex token must be exactly `git`). `subcommand` is
    "commit" for the context hook, "push" for the gate.

    If found, returns the value of `-C` ($VAR / ~ expanded), else `fallback_cwd`.
    Scoped to the git segment: `-C` in other shell segments or after the
    subcommand is ignored; last `-C` before the subcommand wins (git's own
    semantics)."""
    for tokens in _split_into_segments(cmd):
        if not tokens or tokens[0] != "git":
            continue
        sub_idx = _find_subcommand_idx(tokens)
        if sub_idx is None or tokens[sub_idx] != subcommand:
            continue
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


# A repo path is an EPHEMERAL test fixture (not real work to drain) when it lives
# under a system temp dir. roborev's own pytest suite, the seed's verify.sh
# throwaway repo, and ad-hoc smoke clones all land here and would otherwise
# dominate the backlog count with noise that vanishes on its own.
_EPHEMERAL_ROOT_PREFIXES = ("/tmp/", "/private/tmp/", "/var/folders/")


def _is_ephemeral_repo(root_path: object) -> bool:
    return isinstance(root_path, str) and root_path.startswith(_EPHEMERAL_ROOT_PREFIXES)


def open_fail_backlog(db_path: Path = ROBOREV_DB) -> list[dict] | None:
    """The MACHINE-WIDE open fail-verdict backlog: every unclosed FAIL review
    across ALL repos and branches in the daemon's store, ephemeral fixture repos
    filtered out. Read-only — a single SELECT, opened read-only so a concurrent
    daemon write is never at risk.

    Returns a list of `{repo, root_path, branch, id}` dicts (one per open FAIL),
    or `None` if the DB can't be read (missing file, locked, schema drift) — the
    same None-vs-[] distinction `_list_jobs` draws, so callers can tell "nothing
    open" from "couldn't look." This is INFORMATIONAL ONLY (the pre-push gate
    surfaces it non-blocking); a None just means "no backlog summary this time,"
    never a denied push.

    `reviews.verdict_bool = 0` is the DB-level spelling of `_is_open_fail`'s
    `verdict == "F"` (FAIL): the CLI maps the same column to the "F"/"P" letter.
    `reviews.closed = 0` is the same `not closed` both surfaces require. Kept here
    next to `_is_open_fail` so the two definitions of "outstanding finding" can't
    drift — one over the CLI rows, one over the DB rows, same predicate."""
    if not db_path.is_file():
        return None
    try:
        # Read-only (immutable) connection: never creates/locks/migrates the DB,
        # and won't block on the daemon's write lock.
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2)
        try:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                """
                SELECT repos.name        AS repo,
                       repos.root_path   AS root_path,
                       review_jobs.branch AS branch,
                       reviews.id        AS id
                FROM reviews
                JOIN review_jobs ON reviews.job_id = review_jobs.id
                JOIN repos       ON review_jobs.repo_id = repos.id
                WHERE reviews.verdict_bool = 0
                  AND reviews.closed = 0
                ORDER BY repos.name, review_jobs.branch, reviews.id
                """
            ).fetchall()
        finally:
            conn.close()
    except sqlite3.Error:
        return None
    return [dict(r) for r in rows if not _is_ephemeral_repo(r["root_path"])]


def format_backlog_summary(
    backlog: list[dict], current_repo_root: str = "", current_branch: str = ""
) -> str:
    """Render `open_fail_backlog()` output as a compact `repo  branch  count/ids`
    block for the pre-push gate's non-blocking surface, plus the active-vs-stale
    cleanup nudge. Empty backlog → "" (caller emits nothing).

    Groups by (root_path, branch) — keyed on ROOT, not repo name — and marks the
    EXACT (current_repo_root, current_branch) being pushed as already-covered by
    the hard gate. Root-granular on both axes is load-bearing: same-basename
    sibling clones (the `~/Hacking/<repo>` vs `~/services/<repo>` dual-clone
    pattern) share a repo *name* but live at different roots, so a name-keyed
    match would collapse them and mis-mark the un-pushed clone's abandoned FAIL
    as covered — the very hide-the-stale-FAIL failure this surface exists to
    prevent. All branches of one clone also share a `root_path`, so the branch
    axis keeps sibling branches of the pushed clone distinct too. The mark only
    appears when BOTH a current repo root and a current branch are given."""
    if not backlog:
        return ""
    # Key on root_path (distinct per clone); carry the display name alongside.
    groups: dict[tuple[str, str], list[int]] = {}
    display_name: dict[tuple[str, str], str] = {}
    for row in backlog:
        key = (row["root_path"], row["branch"] or "(detached)")
        groups.setdefault(key, []).append(row["id"])
        display_name.setdefault(key, row["repo"])
    lines = [
        f"roborev backlog: {len(backlog)} open FAIL review(s) across "
        f"{len(groups)} branch(es) machine-wide (this is INFORMATIONAL — your "
        "push is NOT blocked by other branches):",
        "",
    ]
    for (root_path, branch), ids in groups.items():
        is_current = (
            bool(current_repo_root) and bool(current_branch)
            and root_path == current_repo_root and branch == current_branch
        )
        mark = "  <- current branch (already covered by the hard gate)" if is_current else ""
        id_list = ", ".join(f"#{i}" for i in ids)
        lines.append(f"  {display_name[(root_path, branch)]}  {branch}  ({len(ids)}) {id_list}{mark}")
    lines += [
        "",
        "Sweep the STALE ones while you're here: open them with "
        "`roborev show <id>`, and for any that are days-old, caused by code you "
        "authored, or invalid / valid-but-YAGNI, resolve + `roborev close <id>` "
        "(fix-then-close, or `roborev comment <id> -m \"<why declined>\"` "
        "then close). But NEVER close a finding a parallel session is actively "
        "working — recently-created, on a branch checked out in another clone, or "
        "under a PR being iterated. When unsure whether a finding is active, "
        "LEAVE IT. This is the active-vs-stale test, not branch ownership.",
    ]
    return "\n".join(lines)
