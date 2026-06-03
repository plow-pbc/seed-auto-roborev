# seed-roborev

A [SEED](https://github.com/plow-pbc/seed) that turns on **always-on local commit review** with [roborev](https://github.com/plow-pbc/roborev): every commit on the machine is reviewed automatically by a local AI reviewer, and open findings are surfaced before the next commit.

## Purpose

roborev is the cheap, local first line of review. Running it on **every commit on every machine** catches issues early — *before* they reach the expensive, multi-specialist knightwatch PR review — so each knightwatch round is worth its cost instead of re-flagging things a local pass would have caught.

This SEED is the one-shot installer for that. It wires both halves of the loop machine-wide and verifies them fail-loud — DRY by design (roborev owns the hooks it already self-manages; the SEED only adds what's missing):

- **review after every commit** — `roborev install-hook --force` (run by the SEED) seeds roborev's `post-rewrite` into the global `core.hooksPath`; the SEED then writes its own `post-commit` wrapper that enqueues the review (`roborev post-commit`) and prints a one-line confirmation on every commit (silent success defeats observability). A user-level daemon (systemd `--user` / launchd LaunchAgent) processes the queue. The SEED also pins `default_agent=claude-code` (codex's OAuth has been broken fleet-wide; claude-code is the working reviewer).
- **check results before the next commit** — a SEED-owned git `pre-commit` hook surfaces open findings to stderr (and **always** prints one of `roborev: 0 open findings ✓`, `roborev: N open review finding(s)`, or `roborev: … status UNKNOWN` when `roborev list` fails or returns unparseable output — a broken daemon must never read as clean), so the operator sees on every commit that the check ran. Agent-agnostic (covers claude, codex, humans).
- **observable on every commit** — both hooks emit a one-line stderr confirmation every time, and if the roborev binary has gone missing they print a loud `BROKEN INSTALL` line instead of silently no-op'ing. Silent success (or silent absence) is indistinguishable from "roborev never installed"; the always-on lines are how you can tell at a glance that the loop is alive. Both wrappers share one small library (`roborev-hooklib.sh`) that resolves roborev from a trusted, sanitized `PATH` and owns that loud-failure + the repo-local-hook chain.

Claude Code additionally gets an *earlier*, richer version of the before-commit check: the SEED installs a `PreToolUse[Bash]` **context bridge** that injects open findings into the agent's context before it runs `git commit`. It lives at the seed-owned path `~/.config/roborev/claude-hooks/roborev-pre-commit-context.py` and is wired into `~/.claude/settings.json`. Complement to the universal git `pre-commit`, not a replacement. If the roborev binary has gone missing (a broken-install signal, since the SEED guarantees roborev is installed), the bridge injects a **loud warning** into the agent's context — telling it to re-run the installer before continuing — rather than hard-blocking; it's a dev-tool nudge on a machine the operator controls, not a security gate.

Claude Code also gets a **pre-push gate** (`roborev-pre-push-gate.py`, same seed-owned path): where the bridge only *warns* before a commit, the gate **denies** a `git push` while the branch has open fail-verdict reviews — after waiting up to `ROBOREV_PUSH_WAIT_SECS` (default 600s, clamped to ≤600s so the deny still emits before the hook timeout — raising it requires bumping the registered hook timeout too) for in-flight reviews to land. Commit is too frequent to block, so it warns; push is the export boundary, so it gates — the forcing function that stops findings piling up unseen. Both hooks share one `_roborev_hooklib.py`, so they agree on what an "outstanding finding" is. It's Claude-only and bypassable on a box you control — a workflow forcing function against silently pushing over a `verdict=F` you never read, not a security boundary.

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
