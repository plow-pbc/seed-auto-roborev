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

### roborev daemon ^obj-daemon

- The local review queue processor: `roborev daemon run`, listening on `roborev config get server_addr` (default `127.0.0.1:7373`). Installed as `roborev-daemon.service` (systemd `--user`, Linux) or `co.plow.roborev-daemon` (launchd LaunchAgent, macOS) so it survives reboot. Reads/writes `~/.roborev/reviews.db`.

### Global post-commit hook ^obj-hook

- `${XDG_CONFIG_HOME:-$HOME/.config}/roborev/git-hooks/post-commit`, referenced machine-wide via `git config --global core.hooksPath`. On every commit in every repo it enqueues a roborev review, then `exec`s the repo-local `.git/hooks/post-commit` if one exists (so a repo's own hook is preserved despite `core.hooksPath` replacing `.git/hooks`).

### Pre-commit review surfacing (companion, not owned here) ^obj-precommit

- The "show open roborev findings *before* the next commit" half lives in [claude-config](https://github.com/srosro/claude-config) as the `roborev-pre-commit-context.py` Claude Code `PreToolUse[Bash]` hook. This SEED owns only the after-every-commit enqueue; the two compose into the full loop.

## Actions

### roborev is installed always-on ^act-install

- The install action MUST assert the `roborev` binary is present and stop loudly if not (it is an external dependency, never auto-installed).
- It MUST install the daemon as a **user-level** service (systemd `--user` / launchd LaunchAgent — no `sudo`) and start it.
- It MUST set `git config --global core.hooksPath` to `^obj-hook`'s directory **only if** that config is unset or already equal to it; if a *different* `core.hooksPath` is already set, it MUST stop loudly rather than clobber the operator's existing hooks dir.
- It MUST NOT run `sudo`/system-wide installs; any such step (e.g. `loginctl enable-linger` on a headless box) MUST be surfaced as text for the operator to run.

### A commit is reviewed ^act-review

- After any `git commit` in any repo on the machine, `^obj-hook` enqueues a review to `^obj-daemon`, which reviews the commit asynchronously and records a verdict in `~/.roborev/reviews.db` (`roborev list` / `roborev show`).

## Verify

Read-only on installed state, except one ephemeral throwaway repo + test commit (cleaned up before exit). The prompts below are normative; `ref/verify.sh` is their deterministic equivalent for CI / non-AI callers. Announce each block in one line, then run it.

```bash
bash "$(dirname "${BASH_SOURCE[0]:-$0}")/ref/verify.sh"
```

- **^v-binary** — `roborev` resolves on `PATH` or at `~/.local/bin/roborev`.
- **^v-daemon** — `roborev list` round-trips through the daemon (it is running + reachable).
- **^v-hookspath** — `git config --global core.hooksPath` equals `^obj-hook`'s directory, and its `post-commit` is executable.
- **^v-enqueue** — in a fresh throwaway git repo, a single commit causes a roborev job to appear for that repo (the global hook fires for an arbitrary repo). The throwaway repo is removed before exit.

Any failed check MUST exit nonzero with a `FAIL ^v-…: <reason>` line — no silent partial success.

## Open

- **`core.hooksPath` replaces `.git/hooks` wholesale, not just `post-commit`.** `^obj-hook` chains the repo-local `post-commit`, but a repo relying on *other* local hook types (`pre-commit`, `post-checkout`, …) will have those bypassed while `core.hooksPath` is set. At the current operating point no target repo depends on non-`post-commit` local hooks; if one does, mirror that hook into the global hooks dir. A future revision MAY make the global dir a full per-type pass-through.
