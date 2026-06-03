# seed-roborev

A [SEED](https://github.com/plow-pbc/seed) that turns on **always-on local commit review** with [roborev](https://github.com/plow-pbc/roborev): every commit on the machine is reviewed automatically by a local AI reviewer, and open findings are surfaced before the next commit.

## Purpose

roborev is the cheap, local first line of review. Running it on **every commit on every machine** catches issues early — *before* they reach the expensive, multi-specialist knightwatch PR review — so each knightwatch round is worth its cost instead of re-flagging things a local pass would have caught.

This SEED is the one-shot installer for that. It wires both halves of the loop machine-wide and verifies them fail-loud — DRY by design (roborev owns the hooks it already self-manages; the SEED only adds what's missing):

- **review after every commit** — `roborev install-hook --force` (run by the SEED) writes roborev's `post-commit` + `post-rewrite` into the global `core.hooksPath`. A user-level daemon (systemd `--user` / launchd LaunchAgent) processes the queue. The SEED also pins `default_agent=claude-code` (codex's OAuth has been broken fleet-wide; claude-code is the working reviewer).
- **check results before the next commit** — a SEED-owned git `pre-commit` hook surfaces open findings to stderr (and **always** prints either `roborev: 0 open findings ✓` or `roborev: N open review finding(s)`), so the operator sees on every commit that the check ran. Agent-agnostic (covers claude, codex, humans).
- **observable on every commit** — both hooks emit a one-line stderr confirmation every time. Silent success is indistinguishable from "roborev never installed"; the always-on lines are how you can tell at a glance that the loop is alive.

Claude Code additionally gets two `PreToolUse[Bash]` hooks, both living at the seed-owned path `~/.config/roborev/claude-hooks/` and wired into `~/.claude/settings.json`. They share `_roborev_hooklib.py` (the security-sensitive `git`/`roborev` discovery + PATH-attack-guard helpers), installed in the same dir:

- a **context bridge** (`roborev-pre-commit-context.py`) — an *earlier*, richer version of the before-commit check: it injects open findings into the agent's context before it runs `git commit`. Complement to the universal git `pre-commit`, not a replacement — and unlike that warn-only hook, the bridge **hard-blocks** the commit if the roborev binary has gone missing (a broken-install signal, since the SEED guarantees roborev is installed).
- a **pre-push gate** (`roborev-pre-push-gate.py`) — **blocks** a Claude push while the branch has open fail-verdict reviews, first waiting up to 10 minutes for any in-flight reviews to finish. Registered with `timeout 660` (it waits up to 600s; +60s headroom so the deny still emits).

## Install

If your agent has the `seed-install` skill:

> Install `git@github.com:plow-pbc/seed-roborev.git`

The agent clones the repo, reads [`SEED.md`](SEED.md), runs its `## Dependencies` install steps (announcing each shell block first), then answers the `## Verify` prompts. CI / non-AI callers can run the deterministic equivalents at [`ref/install.sh`](ref/install.sh) and [`ref/verify.sh`](ref/verify.sh).

## Adding a platform

`install.sh` fetches the `roborev` binary from this repo's **GitHub Releases** as `roborev-<os>-<arch>` (e.g. `roborev-linux-x86_64`, `roborev-darwin-arm64`). To add a new platform (e.g. Raspberry Pi `linux-aarch64`):

```bash
# build/obtain the binary for the platform, then:
gh release upload v0.1 path/to/roborev#roborev-linux-aarch64 -R plow-pbc/seed-roborev
```

After upload, `install.sh` on that platform succeeds without manual prep. Until then it fails loud with the exact upload command.

## License

MIT.
