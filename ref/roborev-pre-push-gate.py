#!/usr/bin/env python3
"""PreToolUse[Bash] gate — block a Claude-initiated `git push` when the current
branch has outstanding roborev fail-verdict reviews. First waits up to 10 minutes
for any in-flight (queued/running) reviews on the branch to finish.

No-ops (allow) on anything that isn't a real `git ... push` segment, or when
roborev / git / the repo can't be resolved — the gate is best-effort. It BLOCKS
on (a) a confirmed open fail-verdict review, (b) an in-flight review whose wait
exceeds the timeout, or (c) a review still in flight after the wait (fail-closed
so an unreviewed state can't slip through). Unlike the sibling
roborev-pre-commit-context.py (informational), this hook denies.

Shared `git`/`roborev` discovery + PATH-attack-guard helpers live in
`_roborev_hooklib` (also used by `roborev-pre-commit-context.py`).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

from _roborev_hooklib import (
    _find_roborev, _sanitized_env, _resolve_repo_cwd,
    _inside_git_repo, _current_branch, _git_toplevel,
)

WAIT_TIMEOUT_SECS = int(os.environ.get("ROBOREV_PUSH_WAIT_SECS", "600"))


def _allow() -> int:
    return 0  # exit 0, no stdout → normal permission flow proceeds


def _deny(reason: str) -> int:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    return 0


def _list_jobs(roborev: str, repo_root: str, branch: str) -> list[dict]:
    """roborev list --json for this repo+branch. [] on any error (best-effort)."""
    try:
        r = subprocess.run(
            [roborev, "list", "--json", "--repo", repo_root, "--branch", branch],
            cwd=repo_root, capture_output=True, text=True, timeout=10,
            env=_sanitized_env(repo_root),
        )
    except (subprocess.SubprocessError, OSError):
        return []
    if r.returncode != 0:
        return []
    try:
        data = json.loads(r.stdout)
    except (json.JSONDecodeError, ValueError):
        return []
    return data if isinstance(data, list) else []


def _outstanding(jobs: list[dict]) -> list[dict]:
    return [j for j in jobs
            if j.get("verdict") == "F" and not j.get("closed", False)]


def _in_flight(jobs: list[dict]) -> list[dict]:
    return [j for j in jobs if j.get("status") in ("queued", "running")]


def _wait_for(roborev: str, repo_root: str, ids: list[int]) -> bool:
    """Block until the given job IDs finish, bounded at WAIT_TIMEOUT_SECS.
    Returns True if the wait completed (regardless of pass/fail — the caller
    re-queries for the authoritative open-fail state), False on timeout."""
    try:
        subprocess.run(
            [roborev, "wait", "--quiet", "--job", *[str(i) for i in ids]],
            cwd=repo_root, capture_output=True, text=True,
            timeout=WAIT_TIMEOUT_SECS, env=_sanitized_env(repo_root),
        )
        return True
    except subprocess.TimeoutExpired:
        return False
    except (subprocess.SubprocessError, OSError):
        return True  # best-effort: if wait can't run, fall through to re-query


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
        return _allow()
    roborev = _find_roborev(repo_root)
    if roborev is None:
        return _allow()

    jobs = _list_jobs(roborev, repo_root, branch)
    flight = _in_flight(jobs)
    if flight:
        # roborev `id` is a system-assigned integer DB key, so int() can't fail
        # at the operating point; a non-int would be a roborev contract violation
        # we want to surface loudly (the hook errors → push proceeds — acceptable,
        # since the same malformed daemon state can't be meaningfully gated on).
        ids = [int(j["id"]) for j in flight]
        if ids and not _wait_for(roborev, repo_root, ids):
            return _deny(
                f"Push blocked: {len(ids)} roborev review(s) on this branch did not "
                f"complete within {WAIT_TIMEOUT_SECS} seconds "
                f"(job id(s): {', '.join(map(str, ids))}). Re-run the push once they "
                "finish, or investigate the roborev daemon (`roborev status`)."
            )
        jobs = _list_jobs(roborev, repo_root, branch)  # re-query post-wait
        if _in_flight(jobs):
            return _deny(
                "Push blocked: roborev review(s) still in flight after the wait — "
                "re-run the push once they finish (`roborev status`)."
            )
    outstanding = _outstanding(jobs)
    if not outstanding:
        return _allow()
    return _deny(_format_block(outstanding))


def _format_block(jobs: list[dict]) -> str:
    lines = [
        f"Push blocked: {len(jobs)} open roborev fail-verdict review(s) on this branch "
        "must be addressed first.",
        "",
    ]
    for j in jobs:
        lines.append(f"  - review #{j.get('id')} (FAIL)")
    lines += [
        "",
        "For each: run `roborev show <id>` to see findings, then either fix them in a "
        "new commit, or `roborev close <id>` to acknowledge/defer. Re-run the push when "
        "no open fail-verdict reviews remain.",
    ]
    return "\n".join(lines)


if __name__ == "__main__":
    sys.exit(main())
