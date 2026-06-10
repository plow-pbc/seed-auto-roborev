#!/usr/bin/env python3
"""PreToolUse[Bash] gate — DENY a Claude-initiated branch SWITCH
(`git checkout <branch>` / `git switch <branch>`, incl. `-b`/`-B`/`-c`/`-C`
create-and-switch and `git checkout -`) while the branch you're LEAVING has open
roborev `verdict=F` reviews. It closes the enforcement gap the pre-push gate
leaves: the push gate is per-push-per-current-branch, so a `verdict=F` strands
the moment you move off the branch — invisible until you check it back out
(SEED.md ## Open, "Branch-scoping orphans open findings"). This turns the prose
"drain before switching" rule into a forcing function.

Counterpart to roborev-pre-push-gate.py, anchored to the branch you're ON NOW
(the one the switch LEAVES) instead of the push target. Shares the SAME command
discovery, list, and outstanding-finding definition (`_is_open_fail` /
`_list_jobs`) via `_roborev_hooklib`, so the three surfaces can never disagree on
what counts as an open finding.

What gets gated vs. not (full rationale in `_is_branch_switch_args`):
  - GATED   — `git switch <b>`, `git switch -c|-C <new>`, `git checkout <b>`,
              `git checkout -b|-B <new>`, `git checkout -` (previous branch),
              and a bare `git checkout <oneword>` (read as a branch ref).
  - ALLOWED — `git checkout -- <path>`, `git checkout <ref> -- <path>`,
              `git checkout .`, `git checkout <a> <b>` (≥2 operands = pathspec),
              `git restore …` (never a branch op), and the bare no-operand
              `git checkout` / `git switch` (no destination → not a switch).
  When a bare single arg is ambiguous (branch vs. file) we GATE — a safe
  over-block (the agent restores via `git restore` / `git checkout -- f`, which
  aren't gated), never an under-gate that lets a real switch strand findings.

Unlike the push gate, this gate does NOT wait on in-flight reviews. A checkout
exports nothing, and an unfinished review on the branch you're leaving doesn't
vanish when you switch — it's still there (and still gated) when you come back.
Waiting would stall every branch switch on the daemon for no safety gain, so the
gate acts on the already-landed confirmed open-fail set only: deny on a terminal
`verdict=F`, allow otherwise.

ALLOWS (no-op) on anything that isn't a real branch-switching segment, on a
detached HEAD (no leaving-branch to scope to), and when roborev / git / the repo
can't be resolved (best-effort fail-OPEN — a broken dev install must not wedge
every branch switch; the commit bridge + verify.sh own that loud signal). It
also fails OPEN on an unreadable `roborev list` — DISTINCT from the push gate,
which fails CLOSED there: a push is the export boundary (an unreadable state must
not let unreviewed code leave), but a blocked checkout strands no code and a
wedged daemon blocking every branch switch is worse than letting one switch
through (the findings are still on the branch, surfaced again on the next
commit/push). Claude-Code-only, same scope as the push gate.
"""
from __future__ import annotations

import json
import os
import sys

from _roborev_hooklib import (
    _branch_switch_cwd,
    _find_roborev,
    _inside_git_repo,
    _current_branch,
    _git_toplevel,
    _list_jobs,
    _is_open_fail,
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


def _format_block(branch: str, jobs: list[dict]) -> str:
    lines = [
        f"Branch switch blocked: {len(jobs)} open roborev fail-verdict "
        f"review(s) on the branch you're LEAVING ({branch!r}) must be addressed "
        "first — switching away would strand them (they go invisible until you "
        "check this branch back out).",
        "",
    ]
    # Drifted open-fail rows (null/non-int id) still display usefully — fall back
    # to the short git_ref, matching the push gate's _format_block.
    for j in jobs:
        jid = j.get("id")
        ref = f"#{jid}" if isinstance(jid, int) else f"@{str(j.get('git_ref', '') or '?')[:8]}"
        lines.append(f"  - review {ref} (FAIL)")
    lines += [
        "",
        "Drain this branch BEFORE switching — `roborev list --open` on it, then "
        "resolve every open fail-verdict review with judgment per finding (do "
        "NOT clear them with `roborev refine`/`roborev fix`, which auto-apply "
        "findings without the valid-vs-YAGNI judgment):",
        "  1. `roborev show <id>` — read the findings.",
        "  2. VALID finding: fix it in a new commit on THIS branch, then "
        "`roborev close <id>`.",
        "  3. INVALID / YAGNI finding: `roborev comment <id> -m \"<why declined>\"` "
        "then `roborev close <id>`.",
        "",
        "Re-run the switch once no open fail-verdict reviews remain on this branch.",
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
    cwd = _branch_switch_cwd(cmd, fallback_cwd)
    if cwd is None or not _inside_git_repo(cwd):
        return _allow()  # not a real branch switch, or not in a repo
    branch = _current_branch(cwd)
    repo_root = _git_toplevel(cwd)
    if not branch or not repo_root:
        return _allow()  # detached HEAD / unresolvable repo → no leaving-branch
                         # to scope to; nothing to strand (see module docstring).
    roborev = _find_roborev()
    if roborev is None:
        return _allow()  # broken dev install → don't wedge every branch switch.

    jobs = _list_jobs(roborev, repo_root, branch)
    if jobs is None:
        return _allow()  # unreadable list → fail OPEN (see module docstring;
                         # the push gate fails CLOSED here, the checkout gate does
                         # NOT — a blocked switch strands no code).
    outstanding = [j for j in jobs if _is_open_fail(j)]
    if outstanding:
        return _deny(_format_block(branch, outstanding))
    return _allow()


if __name__ == "__main__":
    sys.exit(main())
