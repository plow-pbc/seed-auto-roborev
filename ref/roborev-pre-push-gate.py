#!/usr/bin/env python3
"""PreToolUse[Bash] gate — DENY a Claude-initiated `git push` while the current
branch has outstanding roborev fail-verdict reviews, so findings get fixed or
acknowledged before code leaves the machine instead of accumulating unseen.

This is the deny-surface counterpart to roborev-pre-commit-context.py (the
warn-surface). The split is deliberate:

  - commit is too frequent + too early to block — you commit small and often
    while reviews run async, so the commit hook only WARNS (surfaces findings);
  - push is the export boundary — the right altitude for a hard gate. The deny
    isn't a security boundary (it's trivially bypassable on a box you control);
    it's a forcing function against the *silent-forget* failure mode: pushing
    over a `verdict=F` review you never looked at. It converts "forgot" into
    "consciously fixed it, or `roborev close`'d it."

Both surfaces import the SAME command parser, discovery, and outstanding-finding
definition (`_is_open_fail` / `_list_jobs`) from `_roborev_hooklib`, so they can
never disagree on what counts as an open finding.

ALLOWS (no-op) on anything that isn't a real `git ... push` segment, or when
roborev / git / the repo can't be resolved (best-effort; a broken dev install
must not wedge every push — the commit hook + verify.sh own that loud signal).
It DENIES on (a) a confirmed open fail-verdict review, (b) in-flight reviews
that exceed the wait timeout, or (c) a review still in flight after the wait
(fail-closed — an unreviewed push can't slip through). Before denying on
in-flight work it first waits up to 600s for queued/running reviews to finish,
because commit→push-immediately is the normal flow and the daemon needs a moment
to catch up. (The SEED post-commit hook
enqueues synchronously — the review row is listable before control returns — so
a just-committed HEAD shows up as in-flight, not as an empty list.)

Scope limits (by design, not gaps):
  - Detached HEAD → allow. With no branch there's nothing to scope
    `roborev list --branch` to; denying would block every detached-HEAD push,
    including in repos roborev doesn't track. Branch-scoped gating simply
    doesn't apply.
  - A chained `git commit && git push` in ONE Bash call → not gated for that
    call: PreToolUse fires once, before the string runs, so the new commit (and
    its review) doesn't exist yet. Caught on the next standalone push once the
    review lands. Detecting a trailing push after a commit segment isn't worth
    the parser complexity for a bypass that's trivially available anyway.
  - Claude-Code-only: codex/human pushes aren't gated (the commit-side git
    pre-commit shows everyone the findings first).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

from _roborev_hooklib import (
    _resolve_repo_cwd,
    _find_roborev,
    _inside_git_repo,
    _current_branch,
    _git_toplevel,
    _list_jobs,
    _is_open_fail,
    TERMINAL_STATUSES,
)

# How long to wait for in-flight reviews. Fixed — under the installer's
# registered 660s hook timeout, so the timeout-deny JSON always emits before
# Claude Code kills the hook. Not configurable: no env read, so no mistyped
# value can crash the hook before _deny() and no >660 value can get the deny
# killed mid-wait.
WAIT_TIMEOUT_SECS = 600


_LIST_FAIL_REASON = (
    "Push blocked: couldn't determine roborev review state — `roborev list` "
    "failed (timed out, errored, or returned unparseable output). The gate is "
    "fail-closed: a wedged daemon must not be mistaken for 'no open findings'. "
    "Check `roborev status`, then re-run the push."
)


def _allow() -> int:
    return 0  # exit 0, no stdout → normal permission flow proceeds


def _deny(reason: str) -> int:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    return 0


def _in_flight(jobs: list[dict]) -> list[dict]:
    """Reviews the daemon hasn't finished. Denylists TERMINAL_STATUSES rather
    than allowlisting {queued,running}, so ANY unrecognized non-terminal status
    (an enqueue/`pending`/`starting` state, or a future one) counts as in-flight
    and gets waited on — keeping the gate fail-CLOSED. An allowlist would treat
    an unknown non-terminal status as terminal and, with no `F` verdict yet, let
    an unreviewed push slip through (the exact silent-forget this gate prevents).
    A row with no/null status is also treated as in-flight (fail-closed). Drifted
    non-dict rows are ignored (best-effort, like `_is_open_fail`).

    A `closed` row is NOT in flight even mid-run: a `roborev close`'d review can
    never become an outstanding finding (`_is_open_fail` requires `not closed`),
    so waiting on it would only stall the push pointlessly."""
    return [j for j in jobs
            if isinstance(j, dict) and not j.get("closed", False)
            and j.get("status") not in TERMINAL_STATUSES]


def _wait_for(roborev: str, repo_root: str, ids: list[int]) -> bool:
    """Block until the given job IDs finish, bounded at WAIT_TIMEOUT_SECS.
    Returns True if the wait completed (regardless of pass/fail — the caller
    re-queries for the authoritative open-fail state), False on timeout.

    Signature `roborev wait --quiet --job <id…>` (batch ids after one --job) is
    verified against the live binary. A nonzero exit (not an exception) returns
    True → the caller's re-query still sees the job in flight → fail-closed deny,
    so a CLI drift over-blocks (safe) rather than letting a push through."""
    try:
        subprocess.run(
            [roborev, "wait", "--quiet", "--job", *[str(i) for i in ids]],
            cwd=repo_root, capture_output=True, text=True,
            timeout=WAIT_TIMEOUT_SECS,
        )
        return True
    except subprocess.TimeoutExpired:
        return False
    except (subprocess.SubprocessError, OSError):
        return True  # best-effort: if wait can't run, fall through to re-query


def _format_block(jobs: list[dict]) -> str:
    lines = [
        f"Push blocked: {len(jobs)} open roborev fail-verdict review(s) on this "
        "branch must be addressed first.",
        "",
    ]
    # Drifted open-fail rows (null/non-int id) still display usefully — fall back
    # to the short git_ref so the agent can find the review, matching how the
    # warn surface tolerates id-less rows rather than printing "review #None".
    for j in jobs:
        jid = j.get("id")
        ref = f"#{jid}" if isinstance(jid, int) else f"@{str(j.get('git_ref', '') or '?')[:8]}"
        lines.append(f"  - review {ref} (FAIL)")
    lines += [
        "",
        "For each: run `roborev show <id>` to see the findings, then either fix "
        "them in a new commit or `roborev close <id>` to acknowledge/defer. "
        "Re-run the push once no open fail-verdict reviews remain.",
    ]
    return "\n".join(lines)


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return _allow()
    if payload.get("tool_name") != "Bash":
        return _allow()
    cmd = (payload.get("tool_input") or {}).get("command", "")
    fallback_cwd = payload.get("cwd") or os.getcwd()
    cwd = _resolve_repo_cwd(cmd, fallback_cwd, "push")
    if cwd is None or not _inside_git_repo(cwd):
        return _allow()
    branch = _current_branch(cwd)
    repo_root = _git_toplevel(cwd)
    if not branch or not repo_root:
        return _allow()  # detached HEAD / unresolvable repo → nothing to scope
                         # `roborev list --branch` to; allow by design (see the
                         # module docstring's Scope limits).
    roborev = _find_roborev()
    if roborev is None:
        return _allow()

    jobs = _list_jobs(roborev, repo_root, branch)
    if jobs is None:
        return _deny(_LIST_FAIL_REASON)

    # Deny IMMEDIATELY on an already-confirmed open fail — a terminal fail can't
    # be cleared by waiting, so never hang up to WAIT_TIMEOUT_SECS on unrelated
    # in-flight reviews first (the common case: an old verdict=F plus a freshly
    # enqueued review for the new commit).
    outstanding = [j for j in jobs if _is_open_fail(j)]
    if outstanding:
        return _deny(_format_block(outstanding))

    # Nothing confirmed yet. If reviews are still in flight they may land as
    # fails, so wait for them, then re-query for the authoritative state.
    flight = _in_flight(jobs)
    if flight:
        # Only int ids can be waited on. A drifted row with a null/non-int id is
        # NOT skipped-and-forgotten: ids ends up empty, we skip the wait, and the
        # still-in-flight re-check below denies — fail-CLOSED, like every other
        # drift path here (never int(None), which would crash → no deny → push).
        ids = [int(j["id"]) for j in flight if isinstance(j.get("id"), int)]
        if ids and not _wait_for(roborev, repo_root, ids):
            return _deny(
                f"Push blocked: {len(ids)} roborev review(s) on this branch did "
                f"not complete within {WAIT_TIMEOUT_SECS}s "
                f"(job id(s): {', '.join(map(str, ids))}). Re-run the push once "
                "they finish, or investigate the daemon (`roborev status`)."
            )
        jobs = _list_jobs(roborev, repo_root, branch)  # re-query post-wait
        if jobs is None:
            return _deny(_LIST_FAIL_REASON)
        outstanding = [j for j in jobs if _is_open_fail(j)]
        if outstanding:
            return _deny(_format_block(outstanding))
        if _in_flight(jobs):
            return _deny(
                "Push blocked: roborev review(s) still in flight after the wait — "
                "re-run the push once they finish (`roborev status`)."
            )

    return _allow()


if __name__ == "__main__":
    sys.exit(main())
