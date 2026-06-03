# Purpose

> See [README#Purpose](README.md#purpose).

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

## Dependencies

Software (external system requirements):

- **`roborev`** — the local AI commit reviewer ([plow-pbc/roborev](https://github.com/plow-pbc/roborev)). `ref/install.sh` resolves an existing `roborev` (on `PATH` or at `~/.local/bin/roborev`) or, if absent, downloads the platform-tagged release asset (`roborev-<os>-<arch>`) into `~/.local/bin`. It stops loudly only on an unsupported OS/arch or a missing published asset.
- **`git`**, **`jq`** — standard system tools.

Per-OS service manager (user-scope, no sudo): `systemd --user` (Linux) or `launchd` LaunchAgent (macOS).

Run the following block. It is idempotent + fail-loud — asserts the binary, sets the review agent to `claude-code`, installs + starts the daemon as a user-level service, sets the global `core.hooksPath`, delegates `post-rewrite` to roborev via `roborev install-hook --force`, writes the SEED's own `post-commit` + `pre-commit` wrappers (the always-on confirmation lines roborev's stock silent hooks don't provide), and installs the Claude Code `PreToolUse[Bash]` context bridge (`^obj-precommit`) — copied to the seed-owned path `${XDG_CONFIG_HOME:-$HOME/.config}/roborev/claude-hooks/` and registered into `~/.claude/settings.json` (a `jq` merge that preserves all other settings + dedupes on re-run). System-scope/`sudo` steps (e.g. `loginctl enable-linger` on a headless Linux box) are **surfaced** for the operator to run, never auto-run.

```bash
set -euo pipefail
bash "$(dirname "${BASH_SOURCE[0]:-$0}")/ref/install.sh"
```

## Objects

### roborev daemon ^obj-daemon

- The local review queue processor: `roborev daemon run`, listening on `roborev config get server_addr` (default `127.0.0.1:7373`). Installed as `roborev-daemon.service` (systemd `--user`, Linux) or `co.plow.roborev-daemon` (launchd LaunchAgent, macOS) so it survives reboot. Reads/writes `~/.roborev/reviews.db`.

### Review agent ^obj-agent

- roborev's `default_agent` configuration value — the AI agent used to review each commit. This SEED sets it to **`claude-code`** (the `claude` CLI, which `roborev check-agents` confirms is reachable on the fleet). The roborev shipping default is `codex`, whose OAuth has been broken fleet-wide (`token_invalidated` / `refresh_token_reused` → 401). The SEED MUST set `claude-code` so a fresh install actually reviews, not silently fails on every job.

### Hook ownership split ^obj-hook

- All hooks live under `${XDG_CONFIG_HOME:-$HOME/.config}/roborev/git-hooks/`, addressed machine-wide via `git config --global core.hooksPath`. Ownership:
  - **`post-rewrite`** — installed by **`roborev install-hook --force`** at `^act-install` time. Owned by roborev. Enqueues a review when history is rewritten (rebase/amend).
  - **`post-commit`** — **owned by this SEED.** A thin wrapper that calls `roborev post-commit` to enqueue the review AND prints a one-line stderr confirmation on every commit (`roborev: enqueued review for <sha> (claude-code)` or `roborev: post-commit FAILED — review NOT enqueued`). The always-on print is intentional — silent success defeats observability; the operator must see proof the hook fired. Chains to any repo-local `post-commit`.
  - **`pre-commit`** — **owned by this SEED.** Lists OPEN roborev reviews for the current repo+branch and **always** prints a one-line stderr summary: `roborev: N open review finding(s) on this branch — review before committing more: …` when findings exist, or `roborev: 0 open findings on this branch ✓` when clean. Warn-only, never blocks. Same observability rationale as post-commit. Chains to any repo-local `pre-commit`.

### Claude-specific context bridge ^obj-precommit

- For Claude Code specifically, **this SEED installs** a `roborev-pre-commit-context.py` `PreToolUse[Bash]` bridge that surfaces the same findings *earlier* — injected into the agent's **context** before the `git commit` tool call runs, with richer detail than the terminal `pre-commit` line. It is copied to the seed-owned path `${XDG_CONFIG_HOME:-$HOME/.config}/roborev/claude-hooks/roborev-pre-commit-context.py` (NOT `~/.claude/hooks`, which is a symlink into an unrelated config repo) and registered in `~/.claude/settings.json`. Complement to `^obj-hook`'s universal `pre-commit`, not a replacement — codex and humans rely on the git-level hook. If the roborev binary has gone missing (the SEED guarantees it is installed alongside the bridge, so a missing binary means a broken install and the commit would not be reviewed), the bridge injects a **loud warning** into the agent's context telling it to re-run the installer — context-only, never a hard `deny`. It's a dev-tool nudge on an operator-controlled machine, not a security gate; the agent-agnostic git `pre-commit` + `verify.sh` own the everyone-covered failure.

## Actions

### roborev is installed always-on ^act-install

The install action:

- MUST resolve the `roborev` binary: use an existing one (`PATH` / `~/.local/bin`), else auto-fetch the platform-tagged GitHub release asset (`roborev-<os>-<arch>`) into `~/.local/bin`. Stop loudly only on an unsupported OS/arch or a missing published asset.
- MUST set `^obj-agent`'s value globally: `roborev config set --global default_agent claude-code`. (Idempotent — re-setting the same value is a no-op.)
- MUST install the daemon as a **user-level** service (systemd `--user` / launchd LaunchAgent — no `sudo`). MUST be idempotent on already-running state: if a roborev daemon is already serving, the install enables the unit for boot durability but does NOT start a colliding second instance.
- MUST set `git config --global core.hooksPath` to the SEED's hooks directory **only if** that config is unset or already equal to it; if a *different* `core.hooksPath` is set, it MUST stop loudly rather than clobber.
- MUST delegate `post-rewrite` ownership to roborev by running `roborev install-hook --force` from within a git repo (the SEED's own clone works) — with `core.hooksPath` already set, roborev writes its hooks to that dir, not to `.git/hooks/`.
- MUST then write its own `post-commit` + `pre-commit` wrappers to the hooks dir, OVERWRITING roborev's stock silent `post-commit`: the wrapper still enqueues via `roborev post-commit` (no double-enqueue — only the wrapper runs) but adds the always-on one-line confirmation roborev's stock hook lacks (silent success defeats observability). `pre-commit` has no roborev counterpart.
- MUST NOT run `sudo`/system-wide installs; any such step (e.g. `loginctl enable-linger`) MUST be surfaced as text for the operator to run.

### A commit is reviewed ^act-review

- After any `git commit` in any repo on the machine, the `post-commit` hook (SEED-owned wrapper, calling `roborev post-commit`) enqueues a review job to `^obj-daemon`. The daemon runs the review via `^obj-agent` (claude-code) and records a verdict in `~/.roborev/reviews.db` (`roborev list` / `roborev show`).

### Open findings are surfaced before the next commit ^act-check

- Before any `git commit`, the `pre-commit` hook (SEED-owned) lists OPEN roborev reviews for the current repo+branch and prints them to stderr (non-blocking). The committing agent or human sees them in the commit output and decides whether to address them before adding more commits — the cheap local gate that keeps a PR clean *before* it reaches an expensive knightwatch review.

## Verify

Read-only on installed state, EXCEPT one ephemeral throwaway repo + a single commit there to prove the loop end-to-end (cleaned up before exit). `ref/verify.sh` is the deterministic equivalent.

```bash
bash "$(dirname "${BASH_SOURCE[0]:-$0}")/ref/verify.sh"
```

Static checks:

- **^v-binary** — `roborev` resolves on `PATH` or at `~/.local/bin/roborev`.
- **^v-daemon** — `roborev list` round-trips through the daemon.
- **^v-agent** — `roborev config get default_agent` equals `claude-code`.
- **^v-hookspath** — `git config --global core.hooksPath` equals the SEED's hooks dir, with both `post-commit` and `pre-commit` (both SEED-owned) executable.
- **^v-bridge** — the Claude Code context bridge (`^obj-precommit`) is installed executable at `${XDG_CONFIG_HOME:-$HOME/.config}/roborev/claude-hooks/roborev-pre-commit-context.py`, is registered as a `PreToolUse[Bash]` entry in `~/.claude/settings.json`, and injects a warning into the agent's context (not a `deny`) on a `git commit` when no roborev binary is reachable (broken-install signal).

End-to-end loop check (`^v-loop`) — in one ephemeral throwaway repo it commits a deliberately-broken `app.py` (hardcoded API-key-shaped credential + OS-command-injection via `os.system(input())` + `TypeError` on the happy path) and then a second commit, asserting:

- **^v-loop[option-b-clean]** — the FIRST commit's pre-commit prints `roborev: 0 open findings ✓` (clean-branch path of Option B).
- **^v-loop[option-a]** — that commit's post-commit prints `roborev: enqueued review for <sha1> (claude-code)` (Option A).
- **^v-loop[enqueued]** — a job for that repo exists in the roborev queue with `agent=claude-code`.
- **^v-loop[complete]** — the job reaches a terminal `status` (`done`/`passed`/`failed`) within 240s.
- **^v-loop[findings]** — `claude-code` flagged at least one open finding on the intentionally-broken code (proves the review is actually *finding* real bugs, not just running).
- **^v-loop[blocking]** — the SECOND commit's pre-commit surfaces the open finding(s) (`roborev: N open review finding(s)` — Option B's findings path), proving the loop's headline promise: bad code committed → review flags it → next commit's pre-commit blocks-warns about it.
- **^v-loop[option-a-second]** — that second commit's post-commit also prints its `enqueued review for <sha2>` line (no Option A regression).

Any failed check MUST exit nonzero with a `FAIL ^v-…: <reason>` line — no silent partial success.

## Open

- **`core.hooksPath` replaces `.git/hooks` wholesale.** The SEED's `post-commit` and `pre-commit` wrappers each chain to a repo-local hook of the same name; `post-rewrite` (roborev-owned) does not. Repos relying on other local hook types (`post-checkout`, `pre-push`, `commit-msg`, `post-merge`, …) will have those bypassed while `core.hooksPath` is set. At the current operating point no target repo depends on those; if one does, mirror it into the global hooks dir.
