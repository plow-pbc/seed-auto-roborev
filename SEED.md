# Purpose

> See [README#Purpose](README.md#purpose).

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

## Dependencies

Software (external system requirements):

- **`roborev`** — the local AI commit reviewer ([plow-pbc/roborev](https://github.com/plow-pbc/roborev)). `ref/install.sh` resolves an existing `roborev` (on `PATH` or at `~/.local/bin/roborev`) or, if absent, downloads the platform-tagged release asset (`roborev-<os>-<arch>`) from a **pinned release tag** and **verifies it against a committed `sha256`** before installing into `~/.local/bin`. It stops loudly on an unsupported OS/arch (no pinned checksum), a missing/unreachable asset, or a checksum mismatch (tampered or stale asset) — it never installs unverified bytes.
- **`git`**, **`jq`** — standard system tools.

Per-OS service manager (user-scope, no sudo): `systemd --user` (Linux) or `launchd` LaunchAgent (macOS).

Run the following block. It is idempotent + fail-loud — asserts the binary, sets the review agent to `claude-code`, installs + starts the daemon as a user-level service, sets the global `core.hooksPath`, installs roborev's own git hooks (`post-commit` + `post-rewrite`) via `roborev install-hook --force`, and installs the Claude Code `PreToolUse[Bash]` [context bridge](#claude-specific-context-bridge) + [pre-push gate](#claude-specific-pre-push-gate) + [pre-checkout gate](#claude-specific-pre-checkout-gate) with their shared `_roborev_hooklib.py` — copied to the seed-owned path `${XDG_CONFIG_HOME:-$HOME/.config}/roborev/claude-hooks/` and registered into `~/.claude/settings.json` (a `jq` merge that preserves all other settings + dedupes on re-run). It also installs the Claude Code [usage skill](#claude-specific-usage-skill) to `~/.claude/skills/roborev/SKILL.md`. System-scope/`sudo` steps (e.g. `loginctl enable-linger` on a headless Linux box) are **surfaced** for the operator to run, never auto-run.

```bash
set -euo pipefail
bash "$(dirname "${BASH_SOURCE[0]:-$0}")/ref/install.sh"
```

## Objects

### roborev daemon

- The local review queue processor: `roborev daemon run`, listening on `roborev config get server_addr` (default `127.0.0.1:7373`). Installed as `roborev-daemon.service` (systemd `--user`, Linux) or `co.plow.roborev-daemon` (launchd LaunchAgent, macOS) so it survives reboot. Reads/writes `~/.roborev/reviews.db`.

### Review agent

- roborev's `default_agent` configuration value — the AI agent used to review each commit. This SEED sets it to **`claude-code`** (the `claude` CLI, which `roborev check-agents` confirms is reachable on the fleet). The roborev shipping default is `codex`, whose OAuth has been broken fleet-wide (`token_invalidated` / `refresh_token_reused` → 401). The SEED MUST set `claude-code` so a fresh install actually reviews, not silently fails on every job.

### Hook ownership split

- The git hooks live under `${XDG_CONFIG_HOME:-$HOME/.config}/roborev/git-hooks/`, addressed machine-wide via `git config --global core.hooksPath`, and are **both owned by roborev** — installed by **`roborev install-hook --force`** at [roborev is installed always-on](#roborev-is-installed-always-on) time. With `core.hooksPath` already set, `install-hook` writes them to that dir (not `.git/hooks/`), so they apply to every repo on the machine:
  - **`post-commit`** — enqueues a review after every commit (`roborev post-commit`). This is the seed's point 1 — "review every commit" — and roborev provides it natively; the seed adds no wrapper.
  - **`post-rewrite`** — remaps reviews when history is rewritten (rebase/amend).
- The seed does **not** layer its own confirmation/summary lines onto these hooks. The seed's purpose is to teach a *Claude Code agent* the review loop, and findings reach the agent through the two `PreToolUse[Bash]` hooks below (the [context bridge](#claude-specific-context-bridge) / [pre-push gate](#claude-specific-pre-push-gate)), not a terminal echo. A broken install (missing binary) surfaces to the agent via the bridge's loud context warning and on-demand via `verify.sh`.

### Claude-specific context bridge

- For Claude Code specifically, **this SEED installs** a `roborev-pre-commit-context.py` `PreToolUse[Bash]` bridge that surfaces open fail-verdict findings for the current repo+branch — injected into the agent's **context** right before the `git commit` tool call runs, so it can resolve them with judgment per finding — fix the valid ones (then `roborev close <id>`), decline the invalid/YAGNI ones (`roborev comment <id> -m "<why>"` recording why, then `roborev close <id>`), rather than via `roborev refine`/`roborev fix`. roborev's own `post-commit` hook reviews every commit but its findings have no native path back into an agent's context; this bridge is that path. It is copied to the seed-owned path `${XDG_CONFIG_HOME:-$HOME/.config}/roborev/claude-hooks/roborev-pre-commit-context.py` (NOT `~/.claude/hooks`, which is a symlink into an unrelated config repo) and registered in `~/.claude/settings.json`. If the roborev binary has gone missing (the SEED guarantees it is installed alongside the bridge, so a missing binary means a broken install and the commit would not be reviewed), the bridge injects a **loud warning** into the agent's context telling it to re-run the installer — context-only, never a hard `deny`. It's a dev-tool nudge on an operator-controlled machine, not a security gate; `verify.sh` is the on-demand everyone-covered check.

### Claude-specific pre-push gate

- For Claude Code, **this SEED also installs** a `roborev-pre-push-gate.py` `PreToolUse[Bash]` gate at the same seed-owned path, registered in `~/.claude/settings.json` with `timeout: 660`. Where the [bridge](#claude-specific-context-bridge) only **warns** before a commit, the gate **denies** a `git push` while the branch has open fail-verdict reviews — first waiting up to 600s (under the registered 660s hook timeout, so the timeout-deny emits before Claude Code kills the hook) for in-flight reviews to finish, then denying on a confirmed open fail, a wait-timeout, a still-in-flight review, **or an unreadable `roborev list`** (fail-closed throughout). This is the forcing function that keeps findings from accumulating unseen: commit is too frequent to block, so it warns; **push is the export boundary**, the right altitude for a hard gate. The deny isn't a security boundary (trivially bypassable on a box you control) — it converts the *silent-forget* failure (pushing over a `verdict=F` review you never read) into a conscious **resolve-each** step: for every open fail review the agent fixes a valid finding (in a new commit) or declines an invalid/YAGNI one (`roborev comment <id> -m "<why>"` recording why), then `roborev close <id>` either way — never cleared by the autonomous `roborev refine`/`roborev fix` loops, which apply findings WITHOUT the valid-vs-YAGNI judgment (and `refine` runs in a git worktree). All three hooks import a shared `_roborev_hooklib.py` (one command parser, one definition of an "outstanding finding"), so the warn and deny surfaces can never disagree. Scope limit: the gate is Claude-Code-only (a `PreToolUse` hook); codex/human pushes aren't gated — acceptable, since this seed's purpose is teaching the *Claude Code* agent the review loop. A missing roborev binary **allows** the push (the bridge + `verify.sh` own the broken-install signal; a dev install must not wedge every push).

### Claude-specific pre-checkout gate

- For Claude Code, **this SEED also installs** a `roborev-pre-checkout-gate.py` `PreToolUse[Bash]` gate at the same seed-owned path, registered in `~/.claude/settings.json`. Where the [push gate](#claude-specific-pre-push-gate) is anchored to the branch being *pushed*, this gate is anchored to the branch being **left**: it **denies** a `git checkout`/`git switch` to *another* branch while the **current** branch has open fail-verdict reviews — the enforcement half of the branch-scoping caveat in [## Open](#open) (a `verdict=F` strands the moment you move off a branch, invisible until you check it back out; the push gate, being per-push-per-current-branch, never sees it). It turns the skill's prose "drain before switching" rule into a forcing function. It gates the branch-leaving forms — `git switch <b>`, `git checkout <b>`, `-b`/`-B`/`-c`/`-C` create-and-switch, `git checkout -`/`git switch -` (previous branch), and a bare single-word `git checkout <ref>` (read as a branch) — but **NOT** file restores (`git checkout -- <path>`, `git checkout .`, `git checkout <ref> -- <path>`, `git restore …`) or the bare no-operand forms; an ambiguous bare single arg is gated (a safe over-block — the agent restores via the explicit `--`/`restore` forms, which aren't gated — never an under-gate that lets a real switch strand findings). It denies on EITHER a confirmed terminal `verdict=F` OR a **still-in-flight** (non-terminal, unclosed) review on the leaving branch — an in-flight one could land `verdict=F` after the agent switched away and strand the finding. Unlike the push gate it does **not** *wait* on the in-flight ones (a checkout exports nothing and is cheap to retry, so blocking-then-retry beats stalling the switch on the daemon) — it denies and tells the agent to `roborev wait` and re-try once drained. It fails **OPEN** on an unreadable `roborev list` (a blocked checkout strands no code, so a wedged daemon must not wedge every branch switch) — the deliberate inverse of the push gate's fail-CLOSED export-boundary stance. Claude-Code-only; a missing roborev binary **allows** the switch (same broken-install posture as the other hooks). It imports the same shared `_roborev_hooklib.py`, so all three surfaces agree on what counts as an open finding.

### Claude-specific usage skill

- The three `PreToolUse[Bash]` hooks above bring findings *to* the agent; this skill teaches the agent how to **use** roborev and the workflow contract those hooks serve. **This SEED installs** `skills/roborev/SKILL.md` to `~/.claude/skills/roborev/SKILL.md` — a Claude Code skill, the native mechanism for "how to use tool X + its loop," auto-activating on `git commit`/`git push`/`git checkout`/`git switch` triggers, a pre-push or pre-checkout gate denial, or a pre-commit context warning. It documents the review-loop contract, the command reference, and the operational sharp edges — the single source of truth, not restated here or in the README. It is installed as a **real file** under `~/.claude/skills/` (NOT into the `claude-config` repo): a config repo that symlink-manages its own skills preserves user-owned (seed-installed) entries, so the two coexist without collision. The contract is the agent-facing complement to the mechanical [gate](#claude-specific-pre-push-gate) — the gate *forces* the behavior, the skill *teaches* it, so it holds even where the gate is absent or bypassed.

## Actions

### roborev is installed always-on

The install action:

- MUST resolve the `roborev` binary: use an existing one (`PATH` / `~/.local/bin`), else auto-fetch the platform-tagged GitHub release asset (`roborev-<os>-<arch>`) from a **pinned release tag** and **verify it against a committed `sha256`** before installing into `~/.local/bin`. MUST stop loudly — never installing unverified bytes — on an unsupported OS/arch (no pinned checksum), a missing/unreachable asset, or a checksum mismatch.
- MUST set the [review agent](#review-agent)'s value globally: `roborev config set --global default_agent claude-code`. (Idempotent — re-setting the same value is a no-op.)
- MUST install the daemon as a **user-level** service (systemd `--user` / launchd LaunchAgent — no `sudo`). MUST be idempotent on already-running state: if a roborev daemon is already serving, the install enables the unit for boot durability but does NOT start a colliding second instance.
- MUST set `git config --global core.hooksPath` to the SEED's hooks directory **only if** that config is unset or already equal to it; if a *different* `core.hooksPath` is set, it MUST stop loudly rather than clobber.
- MUST install roborev's own git hooks by running `roborev install-hook --force` from within a git repo (the SEED's own clone works) — with `core.hooksPath` already set, roborev writes both `post-commit` (enqueue a review every commit) and `post-rewrite` (remap on rebase/amend) to that dir, not to `.git/hooks/`. The SEED layers no wrapper on these; findings reach the Claude agent via the `PreToolUse[Bash]` hooks (the [context bridge](#claude-specific-context-bridge) / [pre-push gate](#claude-specific-pre-push-gate)), not a terminal echo. MUST first `rm -f` any orphaned `pre-commit` + `roborev-hooklib.sh` a prior seed version installed to that dir — `install-hook --force` overwrites `post-commit`/`post-rewrite` but would otherwise leave the stale `pre-commit` wrapper firing on every commit, so an upgrade converges to the roborev-owned contract.
- MUST install the Claude Code [usage skill](#claude-specific-usage-skill) by copying `skills/roborev/SKILL.md` to `~/.claude/skills/roborev/SKILL.md`. Idempotent (overwrite-in-place); installed as a real file so a config repo's skill-symlink management leaves it intact.
- MUST NOT run `sudo`/system-wide installs; any such step (e.g. `loginctl enable-linger`) MUST be surfaced as text for the operator to run.

### A commit is reviewed

- After any `git commit` in any repo on the machine, roborev's own `post-commit` hook enqueues a review job to the [roborev daemon](#roborev-daemon). The daemon runs the review via the [review agent](#review-agent) (claude-code) and records a verdict in `~/.roborev/reviews.db` (`roborev list` / `roborev show`).

### Open findings are surfaced before the next commit, before push & before a branch switch

- Before any Claude-Code `git commit`, the [context bridge](#claude-specific-context-bridge) injects open fail-verdict reviews for the current repo+branch into the agent's context (non-blocking) — so the agent resolves them with judgment (fix the valid findings, then `roborev close <id>`; decline the invalid/YAGNI ones with `roborev comment <id> -m "<why>"` then `roborev close <id>`; not via `roborev refine`/`roborev fix`) before adding more commits, the cheap local gate that keeps a PR clean *before* it reaches an expensive knightwatch review. Before any Claude-Code `git push`, the [pre-push gate](#claude-specific-pre-push-gate) **denies** while open fail-verdict reviews remain — the forcing function that stops findings leaving the machine unseen. The push stays blocked until each open fail review is **resolved**, with judgment per finding: fix the valid findings (a new commit) and decline the invalid/YAGNI ones (`roborev comment <id> -m "<why>"` recording the reason), then `roborev close <id>` either way. Resolution MUST be by hand, per finding — NOT delegated to `roborev refine`/`roborev fix`, which apply every finding without the valid-vs-YAGNI judgment (and `refine` runs in a git worktree).
- Before any Claude-Code `git checkout`/`git switch` to *another* branch, the [pre-checkout gate](#claude-specific-pre-checkout-gate) **denies** the switch while the branch being **left** has open fail-verdict reviews — the enforcement half of "drain before switching" (without it, a `verdict=F` strands on the abandoned branch, unseen by the per-current-branch push gate). File restores (`git checkout -- <path>`, `git checkout .`, `git restore …`) are NOT gated.
- **A finished review is not a cleared finding.** A `verdict=F` review's daemon job *completing* does NOT resolve it: the review stays open — and keeps blocking the push gate AND the pre-checkout gate — until an **explicit `roborev close <id>`** (after a fix, or after a `roborev comment <id> -m "<why>"` decline). Finishing the commit/feature/PR does not clear it. The agent MUST **drain to zero** open fail-verdict reviews before every push and again at task/PR handoff (`roborev list --open` → resolve each `verdict=F`), not rely on the commit/PR being "done."

## Verify

Read-only on installed state, EXCEPT one ephemeral throwaway repo + a single commit there to prove the loop end-to-end (cleaned up before exit). `ref/verify.sh` is the deterministic equivalent.

```bash
bash "$(dirname "${BASH_SOURCE[0]:-$0}")/ref/verify.sh"
```

Static checks:

- **v-binary** — `roborev` resolves on `PATH` or at `~/.local/bin/roborev`.
- **v-daemon** — `roborev list` round-trips through the daemon.
- **v-agent** — `roborev config get default_agent` equals `claude-code`.
- **v-hookspath** — `git config --global core.hooksPath` equals the SEED's hooks dir.
- **v-postcommit** / **v-postrewrite** — both roborev-owned hooks (`post-commit`, `post-rewrite`) are present and executable in that dir.
- **v-nostale** — no orphaned `pre-commit` or `roborev-hooklib.sh` from a prior seed version remains in that dir (the installer removes them; their presence means a stale wrapper is still firing).
- **v-bridge** — the Claude Code [context bridge](#claude-specific-context-bridge) is installed executable at `${XDG_CONFIG_HOME:-$HOME/.config}/roborev/claude-hooks/roborev-pre-commit-context.py`, is registered as a `PreToolUse[Bash]` entry in `~/.claude/settings.json`, and injects a warning into the agent's context (not a `deny`) on a `git commit` when no roborev binary is reachable (broken-install signal).
- **v-lib / v-gate** — the shared `_roborev_hooklib.py` and the [pre-push gate](#claude-specific-pre-push-gate) `roborev-pre-push-gate.py` are installed alongside the bridge, the gate is registered as a `PreToolUse[Bash]` entry with `timeout: 660`, and a non-push Bash command is allowed (the gate never denies anything but a `git push`).
- **v-checkout** — the [pre-checkout gate](#claude-specific-pre-checkout-gate) `roborev-pre-checkout-gate.py` is installed executable alongside the bridge, registered as a `PreToolUse[Bash]` entry, and a file checkout (`git checkout -- <path>`) is allowed with a clean exit (the gate only ever denies a branch *switch*, never a file restore).
- **v-skill** — the Claude Code [usage skill](#claude-specific-usage-skill) is installed at `~/.claude/skills/roborev/SKILL.md` with valid `name: roborev` frontmatter.

End-to-end loop check (`v-loop`) — in one ephemeral throwaway repo it commits a deliberately-broken `app.py` (hardcoded API-key-shaped credential + OS-command-injection via `os.system(input())` + `TypeError` on the happy path), then validates the loop through the public `roborev list` seam (roborev's own `post-commit` hook is silent), asserting:

- **v-loop[enqueued]** — roborev's `post-commit` hook enqueued a job for that repo with `agent=claude-code`.
- **v-loop[complete]** — the job reaches a terminal `status` (`done`/`passed`/`failed`) within 240s.
- **v-loop[findings]** — `claude-code` flagged at least one open fail-verdict finding on the intentionally-broken code (proves the review is actually *finding* real bugs, not just running) — the loop's headline promise: bad code committed → review flags it → surfaces in `roborev list` for the bridge/gate to act on.

Any failed check MUST exit nonzero with a `FAIL v-…: <reason>` line — no silent partial success.

## Open

- **`core.hooksPath` replaces `.git/hooks` wholesale.** roborev's hooks (`post-commit`, `post-rewrite`) do not chain to a repo-local hook of the same name, and repos relying on other local hook types (`post-checkout`, `pre-push`, `commit-msg`, `post-merge`, …) will have those bypassed while `core.hooksPath` is set. At the current operating point no target repo depends on those; if one does, mirror it into the global hooks dir.
- **Branch-scoping orphans open findings — there is no all-branches/all-repos view.** `roborev list`, the [context bridge](#claude-specific-context-bridge), the [pre-push gate](#claude-specific-pre-push-gate), and the [pre-checkout gate](#claude-specific-pre-checkout-gate) are all scoped to the **current repo + current branch** (the hooks call `roborev list --repo <root> --branch <branch>`); a finding lands on whatever branch the commit was made on. The pre-checkout gate now **enforces** "drain before switching" — a Claude-Code `git checkout`/`git switch` away from a branch with open fail-verdict reviews is **denied**, so the agent can't silently strand findings by switching off the branch it dirtied. Residual gaps the gate does *not* close (so the per-branch sweep is still required): findings stranded by working in **another clone / another repo** (the gate only sees the branch you switch *from* in the repo you switch it *in*); a switch made by **human/codex git or any non-Claude path** (the gate is a `PreToolUse` hook, Claude-Code-only); and the gate fails **OPEN** on an unreadable `roborev list`. So a clean `roborev list --open` on the current branch can still read as "all clear" while `verdict=F` reviews accumulate unseen elsewhere. (The DB is machine-wide — one `~/.roborev/reviews.db` — so a finding *another* checkout left on the branch being pushed is still the pusher's to drain; the per-branch scope is only what hides findings on the branches you left.) The agent MUST still sweep **per branch** (revisit every branch it committed on before calling a task done), not trust one branch's clean read as machine-wide clear. A `roborev list --all` spanning branches/repos would collapse this sweep into one command — a future improvement, not current behavior.
