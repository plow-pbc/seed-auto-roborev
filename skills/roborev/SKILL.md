---
name: roborev
description: Use when committing, pushing, or switching branches (git checkout / git switch) on a machine where roborev is installed (the seed-auto-roborev review loop) — covers the workflow contract (triage findings at commit time, fix or close every fail-verdict finding, never push or switch away over an unread verdict=F) and the roborev command usage (status / list / show / wait / close). Triggers on git commit/push/checkout/switch, a pre-push or pre-checkout gate denial, a pre-commit context warning, or "roborev findings".
---

# roborev — the always-on local review loop

roborev reviews **every commit on this machine** (pytest fixture repos excepted — see step 1 below) with a local AI reviewer, the cheap first pass *before* an expensive PR review (e.g. knightwatch). You don't trigger it — you **consume** its findings. This skill is the workflow contract + command reference for that loop.

## How the loop runs (you don't start any of this)

1. **Every `git commit`** → the seed-wrapped `post-commit` git hook (installed machine-wide via `core.hooksPath`) enqueues a review job. The wrapper skips pytest fixture repos (`*/pytest-of-*/pytest-*` — test-suite throwaway commits would flood the DB with noise) and delegates everything else to roborev's underlying `roborev post-commit`.
2. **The `roborev-daemon` user service** processes the queue with the `claude-code` agent and records a verdict in `~/.roborev/reviews.db`.
3. **Three Claude Code `PreToolUse[Bash]` hooks bring findings back to you** — the only native path from roborev's DB into an agent's context:
   - **pre-commit context bridge** — before a `git commit`, *injects* this repo+branch's open fail-verdict findings into your context. It only **warns**; it never blocks (commit is too frequent to gate).
   - **pre-push gate** — before a `git push`, it **denies** the push while the **current** branch has open fail-verdict reviews, waiting up to ~600s for in-flight ones to land. Push is the export boundary, so it's a hard gate.
   - **pre-checkout gate** — before a `git checkout`/`git switch` to *another* branch, it **denies** the switch while the branch you're **leaving** has open fail-verdict reviews (or still-in-flight ones that could land `verdict=F` after you've left). This ENFORCES "drain before switching" (below) so you can't strand findings by moving off a dirty branch — the push gate, being per-current-branch, would never see them. File restores (`git checkout -- <path>`, `git checkout .`, `git restore …`) are NOT gated. It doesn't *wait* on in-flight reviews (a switch is cheap to retry) — it denies and tells you to `roborev wait`, then re-try once the branch is drained.

The gates are Claude-only and bypassable on a box you control — a workflow forcing function against silently pushing/switching over a `verdict=F` you never read, **not** a security boundary.

## The contract — what you MUST do

**A finished review is NOT a cleared finding.** A verdict landing (the daemon finishing the job) means the review *ran* — it does NOT mean the finding is addressed. A `verdict=F` review stays in the open set, blocking the push gate, until you **explicitly `roborev close <id>`** — after fixing it, or after recording a decline reason with `roborev comment <id> -m "<why>"`. Finishing the commit, the feature, or the PR does **not** clear it; only `roborev close` does. (Older guidance framed reviews as "already completed by push time" — completed ≠ cleared; treat that as "ran early," never "handled.")

**When the pre-commit bridge surfaces open fail-verdict findings, triage each one immediately — don't defer to push.** Categorize EACH finding out loud as exactly one of:

- **INVALID** (not a real problem) or **VALID-BUT-YAGNI** (real, but the only remedy adds a guard / branch / fallback / wrapper for a case that can't happen at the current operating point — **and especially likely when the finding is facet N+1 of a class you've already guarded in earlier commits on this branch**: roborev reviews only *this* commit's diff, so it can't see that facets 1..N already made N+1 redundant. When you spot that pattern, decline the *class* — close N+1 with a note — rather than fix-to-clear it) → `roborev comment <id> -m "<why>"` then `roborev close <id>`. Declining is legitimate; **silently leaving it open is not** — an open `verdict=F` blocks the push gate and means the finding is unread, not judged.
- **VALID** (a real bug or a genuine simplification) → fix it in the **very next commit** on the branch (its own follow-up commit, before other feature work), then `roborev close <id>`.

**Drain before every push, and again at task / PR handoff.** Run `roborev list --open`, resolve every `verdict=F` (fix-then-close, or comment-then-close), and leave **zero** open fail-verdict reviews. **Never push over an open or unread `verdict=F`** — the pre-push gate is the backstop hard stop, but draining at commit time and at handoff keeps the eventual push unblocked, and a green push is not proof you read the findings.

**Branch-scoping orphans findings — this is the load-bearing caveat.** `roborev list`, the pre-commit bridge, the pre-push gate, and the pre-checkout gate are all scoped to the **current repo + current branch** (the hooks call `roborev list --repo <root> --branch <branch>`), and a finding lands on whatever branch the commit was made on. The pre-checkout gate now **enforces** drain-before-switching — it **denies** a `git checkout`/`git switch` away from a branch that still has open `verdict=F` reviews — so you can no longer *silently* strand findings by switching off the branch you dirtied. But it does **not** close the whole gap: findings still go invisible when you work in **another clone or another repo** (the gate only sees the branch you switch *from*, in the repo you switch it *in*), the gate is **Claude-only** (a human/codex switch isn't gated), a **`git commit && git switch` chained in one Bash call** slips through (the hook fires before the string runs, so the new commit's review isn't enqueued yet — run the switch standalone to get it gated), and it fails **open** if `roborev list` can't be read. So a clean `roborev list --open` on your *current* branch does NOT by itself mean the machine is clear — `verdict=F` reviews can pile up unseen on other branches and clones. (The DB is machine-wide — one `~/.roborev/reviews.db` — so a finding *another* checkout left on the branch you're pushing is still yours to drain; the per-branch scope is what hides findings on the branches you *left*.) The machine-wide backlog view below collapses the cross-branch sweep into one command.

**The machine-wide backlog view — `roborev list --all` (seed helper).** Because upstream `roborev list` has no all-branches/all-repos mode, this SEED installs a helper that reads the daemon's `~/.roborev/reviews.db` directly (read-only) and prints **every job with an open fail-verdict review across all repos and branches** (one deduped row per open-FAIL job; every printed id is a **job id**, passable straight to `roborev show/close/comment`) — ephemeral temp-dir fixture repos (under `/tmp`, `/private/tmp`, `/var/folders`, `/private/var/folders`) filtered out as noise. Run it whenever you want the cross-branch picture instead of revisiting branches one by one:

```
python3 ~/.config/roborev/claude-hooks/roborev-list-all.py          # repo  branch  count/ids backlog
python3 ~/.config/roborev/claude-hooks/roborev-list-all.py --json   # raw rows for scripting
```

(`$XDG_CONFIG_HOME/roborev/claude-hooks/` if you've set `XDG_CONFIG_HOME`.) **The pre-push gate also surfaces this same backlog automatically** — on a clean (allowed) push it injects the machine-wide open-FAIL summary into your context as a non-blocking nudge. It is *informational only*: the hard push deny stays strictly **current-branch** — other branches' FAILs never block your push (that would wedge every push machine-wide), they're just surfaced so you sweep them.

**Backlog sweep — clean up STALE findings, never ACTIVE ones.** When the backlog surfaces (via the helper or the gate's allow-path nudge), explore the other-branch FAILs with `roborev show <id>` and resolve the **stale** ones: a finding is stale (yours to close) when it's **days-old**, **caused by code you authored**, or **invalid / valid-but-YAGNI** — close it (fix-then-`roborev close <id>`, or `roborev comment <id> -m "<why declined>"` then close). **Never close a finding a parallel session is actively working** — recently-created, on a branch currently checked out in another clone, or under a PR being iterated. **When unsure whether a finding is active, LEAVE IT.** This is the **active-vs-stale** test, not strict branch-ownership: a FAIL on a branch you don't own may still be stale-and-yours-to-close if it's old and abandoned, and a FAIL on "your" branch may be active in a sibling session — judge by activity, not by whose branch it is.

Clearing roborev before push means each later PR-review round (knightwatch) is worth its token cost instead of re-flagging what this local pass already caught.

**Commit often, in small reviewable increments.** Each commit triggers its own review, so small commits mean those reviews run *while you keep working* and have already landed by the time you push — findings surface early, each review is sharper (less diff), and the push isn't left waiting on in-flight reviews. (Landing early is not the same as being cleared — you still close each one per the contract above.)

## Commands

| Command | What it does |
|---|---|
| `roborev status` | Daemon health + queue depth. |
| `roborev list --open` | Unresolved *reviews* for the **current repo + current branch only** — **any** verdict, including PASS rows, so not all of them are findings. The **actionable** ones are unclosed fail-verdict reviews (`verdict=F`) — what the bridge and gate act on. Add `--json` and filter `verdict=="F"` to list just those. This is current-branch-scoped, so a clean read here does NOT mean the machine is clear (see *Branch-scoping orphans findings* above) — use the `--all` backlog helper below for the cross-branch picture. |
| `roborev-list-all.py` *(seed helper)* | The machine-wide open-FAIL backlog the upstream CLI lacks: every job with an unclosed `verdict=F` review across **all repos and branches** (one row per job; printed ids are JOB ids — pass them straight to `show`/`close`/`comment`), ephemeral temp-dir fixtures (`/tmp`, `/private/tmp`, `/var/folders`, `/private/var/folders`) filtered. Run `python3 ~/.config/roborev/claude-hooks/roborev-list-all.py` (add `--json` for raw rows). The pre-push gate auto-surfaces this same backlog (non-blocking) on a clean push. See *Branch-scoping orphans findings* for the active-vs-stale sweep policy. |
| `roborev show <id>` | Read a specific finding (job ID, or a commit SHA / `HEAD`). |
| `roborev wait` | Block until HEAD's review lands — token-efficient; use this instead of polling before a push. |
| `roborev close <id>` | Mark a finding resolved/declined. |

## Two sharp edges

- **The daemon unit is `roborev-daemon.service`, NOT `roborev`.** `systemctl --user is-active roborev` returns `inactive` for the *nonexistent* unit name and looks like the daemon is down. Check `systemctl --user is-active roborev-daemon.service` (or just `roborev status`).
- **Run `roborev close <id>` standalone, BEFORE `git commit` — not chained as `close && commit`.** The chained form doesn't clear the gate in time: the commit blocks and HEAD doesn't advance.

## If the loop looks broken

- **No findings ever surfacing / `roborev` not found** → the install may be broken. Re-run the seed installer (`ref/install.sh` in [`plow-pbc/seed-auto-roborev`](https://github.com/plow-pbc/seed-auto-roborev)); `ref/verify.sh` is the fail-loud everyone-covered check.
- **Daemon not draining the queue** (`roborev status` shows jobs queued but none running) → `systemctl --user restart roborev-daemon.service` (Linux) / reload the `co.plow.roborev-daemon` LaunchAgent (macOS).
