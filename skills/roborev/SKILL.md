---
name: roborev
description: Use when committing, pushing, or switching branches (git checkout / git switch) on a machine where roborev is installed (the seed-auto-roborev review loop) — covers the workflow contract (triage findings at commit time, fix or close every fail-verdict finding, never push or switch away over an unread verdict=F) and the roborev command usage (status / list / show / wait / close). Triggers on git commit/push/checkout/switch, a pre-push or pre-checkout gate denial, a pre-commit context warning, or "roborev findings".
---

# roborev — the always-on local review loop

roborev reviews **every commit on this machine** with a local AI reviewer, the cheap first pass *before* an expensive PR review (e.g. knightwatch). You don't trigger it — you **consume** its findings. This skill is the workflow contract + command reference for that loop.

## How the loop runs (you don't start any of this)

1. **Every `git commit`** → roborev's own `post-commit` git hook (installed machine-wide via `core.hooksPath`) enqueues a review job.
2. **The `roborev-daemon` user service** processes the queue with the `claude-code` agent and records a verdict in `~/.roborev/reviews.db`.
3. **Three Claude Code `PreToolUse[Bash]` hooks bring findings back to you** — the only native path from roborev's DB into an agent's context:
   - **pre-commit context bridge** — before a `git commit`, *injects* this repo+branch's open fail-verdict findings into your context. It only **warns**; it never blocks (commit is too frequent to gate).
   - **pre-push gate** — before a `git push`, it **denies** the push while the **current** branch has open fail-verdict reviews, waiting up to ~600s for in-flight ones to land. Push is the export boundary, so it's a hard gate.
   - **pre-checkout gate** — before a `git checkout`/`git switch` to *another* branch, it **denies** the switch while the branch you're **leaving** has open fail-verdict reviews (or still-in-flight ones that could land `verdict=F` after you've left). This ENFORCES "drain before switching" (below) so you can't strand findings by moving off a dirty branch — the push gate, being per-current-branch, would never see them. File restores (`git checkout -- <path>`, `git checkout .`, `git restore …`) are NOT gated. It doesn't *wait* on in-flight reviews (a switch is cheap to retry) — it denies and tells you to `roborev wait`, then re-try once the branch is drained.

The gates are Claude-only and bypassable on a box you control — a workflow forcing function against silently pushing/switching over a `verdict=F` you never read, **not** a security boundary.

## The contract — what you MUST do

**A finished review is NOT a cleared finding.** A verdict landing (the daemon finishing the job) means the review *ran* — it does NOT mean the finding is addressed. A `verdict=F` review stays in the open set, blocking the push gate, until you **explicitly `roborev close <id>`** — after fixing it, or after recording a decline reason with `roborev comment <id> -m "<why>"`. Finishing the commit, the feature, or the PR does **not** clear it; only `roborev close` does. (Older guidance framed reviews as "already completed by push time" — completed ≠ cleared; treat that as "ran early," never "handled.")

**When the pre-commit bridge surfaces open fail-verdict findings, triage each one immediately — don't defer to push.** Categorize EACH finding out loud as exactly one of:

- **INVALID** (not a real problem) or **VALID-BUT-YAGNI** (real, but the only remedy adds a guard / branch / fallback / wrapper for a case that can't happen at the current operating point) → `roborev comment <id> -m "<why>"` then `roborev close <id>`. Declining is legitimate; **silently leaving it open is not** — an open `verdict=F` blocks the push gate and means the finding is unread, not judged.
- **VALID** (a real bug or a genuine simplification) → fix it in the **very next commit** on the branch (its own follow-up commit, before other feature work), then `roborev close <id>`.

**Drain before every push, and again at task / PR handoff.** Run `roborev list --open`, resolve every `verdict=F` (fix-then-close, or comment-then-close), and leave **zero** open fail-verdict reviews. **Never push over an open or unread `verdict=F`** — the pre-push gate is the backstop hard stop, but draining at commit time and at handoff keeps the eventual push unblocked, and a green push is not proof you read the findings.

**Branch-scoping orphans findings — this is the load-bearing caveat.** `roborev list`, the pre-commit bridge, the pre-push gate, and the pre-checkout gate are all scoped to the **current repo + current branch** (the hooks call `roborev list --repo <root> --branch <branch>`), and a finding lands on whatever branch the commit was made on. The pre-checkout gate now **enforces** drain-before-switching — it **denies** a `git checkout`/`git switch` away from a branch that still has open `verdict=F` reviews — so you can no longer *silently* strand findings by switching off the branch you dirtied. But it does **not** close the whole gap: findings still go invisible when you work in **another clone or another repo** (the gate only sees the branch you switch *from*, in the repo you switch it *in*), the gate is **Claude-only** (a human/codex switch isn't gated), a **`git commit && git switch` chained in one Bash call** slips through (the hook fires before the string runs, so the new commit's review isn't enqueued yet — run the switch standalone to get it gated), and it fails **open** if `roborev list` can't be read. There is also still **no `--all` / all-branches / all-repos view** today, so a clean `roborev list --open` on your *current* branch can read as "all clear" while `verdict=F` reviews pile up unseen on other branches and clones. (The DB is machine-wide — one `~/.roborev/reviews.db` — so a finding *another* checkout left on the branch you're pushing is still yours to drain; the per-branch scope is what hides findings on the branches you *left*.) Sweep **per branch** (check each branch you've committed on before you call a task done), and periodically check the broader backlog by revisiting those branches — don't trust a single branch's clean read as machine-wide clear. *(A real `roborev list --all` spanning branches/repos would make this sweep one command; today it must be done per-branch — noting as a future improvement, not current behavior.)*

Clearing roborev before push means each later PR-review round (knightwatch) is worth its token cost instead of re-flagging what this local pass already caught.

**Commit often, in small reviewable increments.** Each commit triggers its own review, so small commits mean those reviews run *while you keep working* and have already landed by the time you push — findings surface early, each review is sharper (less diff), and the push isn't left waiting on in-flight reviews. (Landing early is not the same as being cleared — you still close each one per the contract above.)

## Commands

| Command | What it does |
|---|---|
| `roborev status` | Daemon health + queue depth. |
| `roborev list --open` | Unresolved *reviews* for the **current repo + current branch only** — **any** verdict, including PASS rows, so not all of them are findings. The **actionable** ones are unclosed fail-verdict reviews (`verdict=F`) — what the bridge and gate act on. Add `--json` and filter `verdict=="F"` to list just those. There is no all-branches/all-repos view, so a clean read here does NOT mean the machine is clear (see *Branch-scoping orphans findings* above) — sweep each branch you've committed on. |
| `roborev show <id>` | Read a specific finding (job ID, or a commit SHA / `HEAD`). |
| `roborev wait` | Block until HEAD's review lands — token-efficient; use this instead of polling before a push. |
| `roborev close <id>` | Mark a finding resolved/declined. |

## Two sharp edges

- **The daemon unit is `roborev-daemon.service`, NOT `roborev`.** `systemctl --user is-active roborev` returns `inactive` for the *nonexistent* unit name and looks like the daemon is down. Check `systemctl --user is-active roborev-daemon.service` (or just `roborev status`).
- **Run `roborev close <id>` standalone, BEFORE `git commit` — not chained as `close && commit`.** The chained form doesn't clear the gate in time: the commit blocks and HEAD doesn't advance.

## If the loop looks broken

- **No findings ever surfacing / `roborev` not found** → the install may be broken. Re-run the seed installer (`ref/install.sh` in [`plow-pbc/seed-auto-roborev`](https://github.com/plow-pbc/seed-auto-roborev)); `ref/verify.sh` is the fail-loud everyone-covered check.
- **Daemon not draining the queue** (`roborev status` shows jobs queued but none running) → `systemctl --user restart roborev-daemon.service` (Linux) / reload the `co.plow.roborev-daemon` LaunchAgent (macOS).
