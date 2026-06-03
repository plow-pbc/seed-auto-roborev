#!/usr/bin/env python3
"""PreToolUse[Bash] context bridge — installed by the seed-roborev SEED to
surface open roborev fail-verdict reviews on the current branch into a Claude
Code agent's context right before it runs `git commit`, so the findings get a
chance to be addressed (or explicitly closed) instead of evaporating into the
daemon's sqlite.

The roborev post-commit hook enqueues a review after every commit, but its
findings have no native path back into Claude's context — they sit in
~/.roborev/reviews.db until someone runs `roborev list` or `tui`. This
hook reads the same DB and injects open fail-verdict reviews for the
current branch into Claude's context at the moment Claude is about to
commit again.

Triggers when the Bash command is `git commit` OR `git -C <dir> commit`
(latter is used by the `/cleanup` skill committing into a sibling
checkout). Every other Bash invocation is a silent no-op (empty stdout,
exit 0).

Unlike the universal git `pre-commit` hook (warn-only, prints to the
terminal), this bridge HARD-BLOCKS the commit if the roborev binary is
missing — the seed installs roborev alongside this bridge, so a missing
binary means a broken install and the commit would NOT be reviewed. When
findings are surfaced (binary present), the tool call is permitted to
proceed; the hook never blocks on findings, only on a broken install.

The lookup is scoped by BOTH repo root_path AND branch — branch-name
collisions across repos (every repo has `main`; multiple plow siblings
have `feat/release-preflight-and-deploy-fixes`, etc.) would otherwise
surface findings from the wrong repo.

Schema assumption: reads `reviews.verdict_bool` (0=fail, 1=pass) and
`reviews.closed`, joined to `review_jobs` on job_id and `repos` on
repo_id, filtered by `repos.root_path` + `review_jobs.branch`. If the
schema drifts the query will fail and the hook will no-op rather than
blow up.

Shared `git`/`roborev` discovery + PATH-attack-guard helpers live in
`_roborev_hooklib` (also used by `roborev-pre-push-gate.py`).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

from _roborev_hooklib import (
    DB_PATH, MAX_REVIEWS, UNTRUSTED_DATA_WARNING,
    _redact_secrets,
    _find_roborev, _sanitized_env, _resolve_repo_cwd,
    _inside_git_repo, _current_branch, _git_toplevel,
)


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    if payload.get("tool_name") != "Bash":
        return 0
    cmd = (payload.get("tool_input") or {}).get("command", "")
    fallback_cwd = payload.get("cwd") or os.getcwd()
    cwd = _resolve_repo_cwd(cmd, fallback_cwd, "commit")
    if cwd is None:                      # not a real `git ... commit` — silent no-op
        return 0
    if not _inside_git_repo(cwd):
        return 0
    repo_root = _git_toplevel(cwd)
    if not repo_root:
        return 0

    # This IS a git commit in a real repo. The seed installs roborev alongside
    # this hook, so a missing binary means a BROKEN install — hard-block the
    # commit rather than silently no-op'ing (which is indistinguishable from
    # "never installed"). Keyed on the binary, NOT the DB: a fresh install with
    # no reviews yet has no DB and is benign.
    roborev = _find_roborev(repo_root)
    if roborev is None:
        out = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": (
                    "roborev binary not found, but the seed-roborev Claude bridge "
                    "hook is active — the install is broken and this commit would "
                    "NOT be reviewed. Re-run `just install-roborev` (or the seed's "
                    "ref/install.sh) to restore it, then retry. To bypass "
                    "intentionally, remove the PreToolUse[Bash] roborev entry from "
                    "~/.claude/settings.json."
                ),
            }
        }
        print(json.dumps(out))
        return 0

    # Binary present -> surface open fail-verdict findings as informational
    # context (never blocks). DB absent = no reviews yet = benign, allow.
    if not DB_PATH.exists():
        return 0
    branch = _current_branch(cwd)
    if not branch:
        return 0
    rows = _fail_open_reviews(repo_root, branch)
    if not rows:
        return 0

    context = _format_findings(roborev, repo_root, branch, rows)
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": context,
        }
    }
    print(json.dumps(out))
    return 0


def _fail_open_reviews(repo_root: str, branch: str) -> list[tuple[int, str]]:
    import sqlite3
    try:
        con = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, timeout=1.0)
    except sqlite3.Error:
        return []
    try:
        rows = con.execute(
            """
            SELECT rj.id, substr(rj.git_ref, 1, 8)
            FROM review_jobs rj
            JOIN reviews r ON r.job_id = rj.id
            JOIN repos rp ON rp.id = rj.repo_id
            WHERE rp.root_path = ?
              AND rj.branch = ?
              AND r.verdict_bool = 0
              AND r.closed = 0
            ORDER BY rj.id DESC
            LIMIT ?
            """,
            (repo_root, branch, MAX_REVIEWS),
        ).fetchall()
    except sqlite3.Error:
        return []
    finally:
        con.close()
    return [(int(jid), sha) for jid, sha in rows]


def _format_findings(roborev: str, repo_root: str, branch: str, rows: list[tuple[int, str]]) -> str:
    header = (
        f"Open roborev fail-verdict reviews on this branch ({branch!r} in {repo_root}):\n"
        f"({len(rows)} review{'s' if len(rows) != 1 else ''} from prior commit(s) on this branch — "
        f"the daemon's findings haven't been addressed or explicitly closed.)\n\n"
        "For each: either fix it in this commit, defer (commit anyway), or close "
        "as acknowledged with `roborev close <id>`. The hook does NOT block this "
        "commit; this is informational.\n\n"
        f"{UNTRUSTED_DATA_WARNING}\n"
    )
    sanitized_env = _sanitized_env(repo_root)
    sections = [header]
    for jid, sha in rows:
        sections.append(f"\n<<<begin-roborev-review-id={jid} sha={sha}>>>")
        try:
            out = subprocess.run(
                [roborev, "show", str(jid)],
                capture_output=True, text=True, timeout=5,
                env=sanitized_env,
            )
            body = out.stdout if out.returncode == 0 else ""
        except (subprocess.SubprocessError, OSError):
            body = ""
        # roborev show prints a 2-line header + separator before the actual
        # review; skip those for brevity. Cap to ~40 lines per finding so a
        # large multi-finding review doesn't dominate the context budget.
        # Each kept line is run through _redact_secrets to enforce the
        # CLAUDE.md last-3-chars rule defensively — review bodies can quote
        # diffs/fixtures that happen to contain leaked tokens.
        lines = body.splitlines()
        kept = []
        for ln in lines:
            if ln.startswith("Review for job") or ln.startswith("Tokens:") or ln.startswith("----"):
                continue
            kept.append(_redact_secrets(ln))
            if len(kept) >= 40:
                kept.append("... (truncated)")
                break
        sections.append("\n".join(kept) if kept else "(roborev show returned nothing)")
        sections.append(f"<<<end-roborev-review-id={jid}>>>")
    return "\n".join(sections)


if __name__ == "__main__":
    sys.exit(main())
