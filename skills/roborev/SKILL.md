---
name: roborev
description: Use when committing or pushing code on a machine where roborev is installed (the seed-auto-roborev review loop) — covers the workflow contract (triage findings at commit time, fix or close every fail-verdict finding, never push over an unread verdict=F) and the roborev command usage (status / list / show / wait / close). Triggers on git commit/push, a pre-push gate denial, a pre-commit context warning, or "roborev findings".
---

# roborev — the always-on local review loop

roborev reviews **every commit on this machine** with a local AI reviewer, the cheap first pass *before* an expensive PR review (e.g. knightwatch). You don't trigger it — you **consume** its findings. This skill is the workflow contract + command reference for that loop.

## How the loop runs (you don't start any of this)

1. **Every `git commit`** → roborev's own `post-commit` git hook (installed machine-wide via `core.hooksPath`) enqueues a review job.
2. **The `roborev-daemon` user service** processes the queue with the `claude-code` agent and records a verdict in `~/.roborev/reviews.db`.
3. **Two Claude Code `PreToolUse[Bash]` hooks bring findings back to you** — the only native path from roborev's DB into an agent's context:
   - **pre-commit context bridge** — before a `git commit`, *injects* this repo+branch's open fail-verdict findings into your context. It only **warns**; it never blocks (commit is too frequent to gate).
   - **pre-push gate** — before a `git push`, it **denies** the push while the branch has open fail-verdict reviews, waiting up to ~600s for in-flight ones to land. Push is the export boundary, so it's a hard gate.

The gate is Claude-only and bypassable on a box you control — it's a workflow forcing function against silently pushing over a `verdict=F` you never read, **not** a security boundary.

## The contract — what you MUST do

**When the pre-commit bridge surfaces open fail-verdict findings, triage each one immediately — don't defer to push.** Categorize EACH finding out loud as exactly one of:

- **INVALID** (not a real problem) or **VALID-BUT-YAGNI** (real, but the only remedy adds a guard / branch / fallback / wrapper for a case that can't happen at the current operating point) → `roborev comment <id> -m "<why>"` then `roborev close <id>`. Declining is legitimate; **silently leaving it open is not** — an open `verdict=F` blocks the push gate and means the finding is unread, not judged.
- **VALID** (a real bug or a genuine simplification) → fix it in the **very next commit** on the branch (its own follow-up commit, before other feature work), then `roborev close <id>`.

**Never push over an unread `verdict=F`.** The pre-push gate is the backstop hard stop, but clearing findings at commit time keeps the eventual push unblocked — and a green push is not proof you read the findings.

Clearing roborev before push means each later PR-review round (knightwatch) is worth its token cost instead of re-flagging what this local pass already caught.

**Commit often, in small reviewable increments.** Each commit triggers its own review, so small commits mean those reviews run *while you keep working* and have already completed by the time you push — findings surface early, each review is sharper (less diff), and the push isn't left waiting on in-flight reviews.

## Commands

| Command | What it does |
|---|---|
| `roborev status` | Daemon health + queue depth. |
| `roborev list --open` | Unresolved *reviews* for the repo+branch — **any** verdict, including PASS rows, so not all of them are findings. The **actionable** ones are unclosed fail-verdict reviews (`verdict=F`) — what the bridge and gate act on. Add `--json` and filter `verdict=="F"` to list just those. |
| `roborev show <id>` | Read a specific finding (job ID, or a commit SHA / `HEAD`). |
| `roborev wait` | Block until HEAD's review lands — token-efficient; use this instead of polling before a push. |
| `roborev close <id>` | Mark a finding resolved/declined. |

## Two sharp edges

- **The daemon unit is `roborev-daemon.service`, NOT `roborev`.** `systemctl --user is-active roborev` returns `inactive` for the *nonexistent* unit name and looks like the daemon is down. Check `systemctl --user is-active roborev-daemon.service` (or just `roborev status`).
- **Run `roborev close <id>` standalone, BEFORE `git commit` — not chained as `close && commit`.** The chained form doesn't clear the gate in time: the commit blocks and HEAD doesn't advance.

## If the loop looks broken

- **No findings ever surfacing / `roborev` not found** → the install may be broken. Re-run the seed installer (`ref/install.sh` in [`plow-pbc/seed-auto-roborev`](https://github.com/plow-pbc/seed-auto-roborev)); `ref/verify.sh` is the fail-loud everyone-covered check.
- **Daemon not draining the queue** (`roborev status` shows jobs queued but none running) → `systemctl --user restart roborev-daemon.service` (Linux) / reload the `co.plow.roborev-daemon` LaunchAgent (macOS).
