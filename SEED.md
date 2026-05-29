# Purpose

> See [README#Purpose](README.md#purpose).

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

## Dependencies

Software (external system requirements — surfaced, not auto-installed by this SEED):

- **`roborev`** on `PATH` or at `~/.local/bin/roborev` — the local AI commit reviewer ([plow-pbc/roborev](https://github.com/plow-pbc/roborev)). If missing, install it first; this SEED asserts its presence and stops loudly if absent.
- **`git`**, **`jq`** — standard system tools.

Per-OS service manager (user-scope, no sudo): `systemd --user` (Linux) or `launchd` LaunchAgent (macOS).

Run the following block to wire always-on roborev on this machine. The block is idempotent and fail-loud — it asserts the binary, installs + starts the daemon as a user-level service, and sets the global git `post-commit` hook (chaining to any repo-local hook). System-scope/`sudo` steps (e.g. `loginctl enable-linger` on a headless Linux box) are **surfaced for you to run**, never auto-run.

```bash
set -euo pipefail
bash "$(dirname "${BASH_SOURCE[0]:-$0}")/ref/install.sh"
```

## Objects

### roborev daemon

- The local review queue processor: `roborev daemon run`, listening on `roborev config get server_addr` (default `127.0.0.1:7373`). Installed as `roborev-daemon.service` (systemd `--user`, Linux) or `co.plow.roborev-daemon` (launchd LaunchAgent, macOS) so it survives reboot. Reads/writes `~/.roborev/reviews.db`.

### Global git hooks

- `${XDG_CONFIG_HOME:-$HOME/.config}/roborev/git-hooks/`, referenced machine-wide via `git config --global core.hooksPath`. Two hooks, each chaining to the repo-local hook of the same name if one exists (so a repo's own hooks are preserved despite `core.hooksPath` replacing `.git/hooks` wholesale):
  - **`post-commit`** — enqueues a roborev review of the just-made commit to the [roborev daemon](#roborev-daemon). (The *after-every-commit* half.)
  - **`pre-commit`** — surfaces any OPEN roborev findings for this repo+branch to stderr (warn-only, never blocks). Because the hook's stderr lands in the `git commit` tool output, **whichever agent ran the commit (claude OR codex) sees the findings** — this is the *before-the-next-commit* check, agent-agnostic by design (codex has no Claude-style pre-tool hook, so a git-level hook is the only check that covers it). (The *before-every-commit* half.)

### Claude-specific pre-commit enhancement

- For Claude Code specifically, [claude-config](https://github.com/srosro/claude-config)'s `roborev-pre-commit-context.py` `PreToolUse[Bash]` hook surfaces the same findings *earlier* (before the `git commit` tool call runs, with richer context injection). It is a complement to the [global git hooks](#global-git-hooks)' universal `pre-commit`, not a replacement — codex and humans rely on the git-level hook.

## Actions

### roborev is installed always-on

- The install action MUST assert the `roborev` binary is present and stop loudly if not (it is an external dependency, never auto-installed).
- It MUST install the daemon as a **user-level** service (systemd `--user` / launchd LaunchAgent — no `sudo`) and start it.
- It MUST set `git config --global core.hooksPath` to the [global git hooks](#global-git-hooks) directory **only if** that config is unset or already equal to it; if a *different* `core.hooksPath` is already set, it MUST stop loudly rather than clobber the operator's existing hooks dir.
- It MUST NOT run `sudo`/system-wide installs; any such step (e.g. `loginctl enable-linger` on a headless box) MUST be surfaced as text for the operator to run.

### A commit is reviewed

- After any `git commit` in any repo on the machine, the [global git hooks](#global-git-hooks)' `post-commit` enqueues a review to the [roborev daemon](#roborev-daemon), which reviews the commit asynchronously and records a verdict in `~/.roborev/reviews.db` (`roborev list` / `roborev show`).

### Open findings are surfaced before the next commit

- Before any `git commit`, the [global git hooks](#global-git-hooks)' `pre-commit` lists OPEN roborev reviews for the current repo+branch and prints them to stderr (non-blocking). The committing agent (claude/codex) or human sees them in the commit output and decides whether to address them before adding more commits — this is the cheap local gate that keeps a PR clean *before* it reaches an expensive knightwatch review.

## Verify

Read-only on installed state, except one ephemeral throwaway repo + test commit (cleaned up before exit). The prompts below are normative; `ref/verify.sh` is their deterministic equivalent for CI / non-AI callers. Announce each block in one line, then run it.

```bash
bash "$(dirname "${BASH_SOURCE[0]:-$0}")/ref/verify.sh"
```

- **`v-binary`** — `roborev` resolves on `PATH` or at `~/.local/bin/roborev`.
- **`v-daemon`** — `roborev list` round-trips through the daemon (it is running + reachable).
- **`v-hookspath`** — `git config --global core.hooksPath` equals the [global git hooks](#global-git-hooks) directory, and its `post-commit` is executable.
- **`v-precommit`** — the [global git hooks](#global-git-hooks)' `pre-commit` is executable.
- **`v-enqueue`** — in a fresh throwaway git repo, a single commit causes a roborev job to appear for that repo (the global hook fires for an arbitrary repo). The throwaway repo is removed before exit.

Any failed check MUST exit nonzero with a `FAIL v-…: <reason>` line — no silent partial success.

## Open

- **`core.hooksPath` replaces `.git/hooks` wholesale.** The [global git hooks](#global-git-hooks) chain the repo-local `post-commit` and `pre-commit`, but a repo relying on *other* local hook types (`post-checkout`, `pre-push`, `commit-msg`, …) will have those bypassed while `core.hooksPath` is set. At the current operating point no target repo depends on those other local hooks; if one does, mirror it into the global hooks dir. A future revision MAY make the global dir a full per-type pass-through.
