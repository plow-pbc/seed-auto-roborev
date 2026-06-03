# seed-auto-roborev

A [SEED](https://github.com/plow-pbc/seed) that turns on **always-on local commit review** with [roborev](https://github.com/plow-pbc/roborev): every commit on the machine is reviewed automatically by a local AI reviewer, and open findings are surfaced before the next commit. Its point is to let roborev run **autonomously via a Claude Code agent** — the agent commits, the findings come back to it, and it acts on them before pushing.

## Purpose

roborev is the cheap, local first line of review. Running it on **every commit on every machine** catches issues early — *before* they reach the expensive, multi-specialist knightwatch PR review — so each knightwatch round is worth its cost instead of re-flagging things a local pass would have caught.

This SEED is the one-shot installer for that. It wires both halves of the loop machine-wide and verifies them fail-loud — DRY by design (roborev owns the git hooks it self-manages; the SEED only adds what's missing — the daemon, the agent, and the path from findings into a Claude Code agent's context):

- **review after every commit** — `roborev install-hook --force` (run by the SEED) installs roborev's own `post-commit` (enqueue a review every commit) and `post-rewrite` (remap on rebase/amend) into the global `core.hooksPath`. A user-level daemon (systemd `--user` / launchd LaunchAgent) processes the queue. The SEED also pins `default_agent=claude-code` (codex's OAuth has been broken fleet-wide; claude-code is the working reviewer).
- **check results before the next commit & before push** — for a Claude Code agent, the SEED installs two `PreToolUse[Bash]` hooks that bring roborev's findings into the agent's context, where it can act on them (roborev reviews every commit but has no native path back into agent context — this is that path).

Before `git commit`, a **context bridge** injects open fail-verdict findings for the current repo+branch into the agent's context so it can fix, defer, or `roborev close` them. It lives at the seed-owned path `~/.config/roborev/claude-hooks/roborev-pre-commit-context.py` and is wired into `~/.claude/settings.json`. If the roborev binary has gone missing (a broken-install signal, since the SEED guarantees roborev is installed), the bridge injects a **loud warning** into the agent's context — telling it to re-run the installer before continuing — rather than hard-blocking; it's a dev-tool nudge on a machine the operator controls, not a security gate.

Claude Code also gets a **pre-push gate** (`roborev-pre-push-gate.py`, same seed-owned path): where the bridge only *warns* before a commit, the gate **denies** a `git push` while the branch has open fail-verdict reviews — after waiting up to 600s for in-flight reviews to land. Commit is too frequent to block, so it warns; push is the export boundary, so it gates — the forcing function that stops findings piling up unseen. Both hooks share one `_roborev_hooklib.py`, so they agree on what an "outstanding finding" is. It's Claude-only and bypassable on a box you control — a workflow forcing function against silently pushing over a `verdict=F` you never read, not a security boundary.

Finally, the SEED installs a **`roborev` usage skill** to `~/.claude/skills/roborev/SKILL.md`. The hooks bring findings *to* the agent; the skill teaches the agent how to *use* roborev and the workflow contract those hooks serve — let in-flight reviews finish before push, fix valid findings or `roborev close` declined ones with a reason, never push over an unread `verdict=F` — plus the command reference (`status`/`list`/`show`/`wait`/`close`) and two sharp edges (the daemon unit is `roborev-daemon.service`, not `roborev`; run `roborev close <id>` standalone before `git commit`). It auto-activates on commit/push and lands as a real file, so a config repo that symlink-manages its own skills leaves it intact. The gate *forces* the behavior; the skill *teaches* it, so the contract holds even where the gate is absent or bypassed.

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
