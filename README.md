# seed-auto-roborev

A [SEED](https://github.com/plow-pbc/seed) that turns on **always-on local commit review** with [roborev](https://github.com/plow-pbc/roborev): every commit on the machine is reviewed automatically by a local AI reviewer, and open findings are surfaced before the next commit. Its point is to let roborev run **autonomously via a Claude Code agent** — the agent commits, the findings come back to it, and it acts on them before pushing.

## Purpose

roborev is the cheap, local first line of review. Running it on **every commit on every machine** catches issues early — *before* they reach the expensive, multi-specialist knightwatch PR review — so each knightwatch round is worth its cost instead of re-flagging things a local pass would have caught.

This SEED is the one-shot installer for that. It wires both halves of the loop machine-wide and verifies them fail-loud — DRY by design (roborev owns the git hooks it self-manages; the SEED only adds what's missing — the daemon, the agent, and the path from findings into a Claude Code agent's context):

- **review after every commit** — `roborev install-hook --force` (run by the SEED) installs roborev's own `post-commit` (enqueue a review every commit) and `post-rewrite` (remap on rebase/amend) into the global `core.hooksPath`. A user-level daemon (systemd `--user` / launchd LaunchAgent) processes the queue. The SEED also pins `default_agent=claude-code` (codex's OAuth has been broken fleet-wide; claude-code is the working reviewer).
- **check results before the next commit, before push & before a branch switch** — for a Claude Code agent, the SEED installs three `PreToolUse[Bash]` hooks that bring roborev's findings into the agent's context, where it can act on them (roborev reviews every commit but has no native path back into agent context — this is that path).

Before `git commit`, a **context bridge** injects open fail-verdict findings for the current repo+branch into the agent's context so it can resolve them with judgment per finding — fix the valid ones early (bugs are cheapest to fix early), decline the invalid/YAGNI ones (`roborev comment <id> -m "<why>"` recording why), then `roborev close <id>` — rather than letting them pile up. (Not via `roborev refine`/`roborev fix`, which apply findings without that valid-vs-YAGNI judgment.) It lives at the seed-owned path `~/.config/roborev/claude-hooks/roborev-pre-commit-context.py` and is wired into `~/.claude/settings.json`. If the roborev binary has gone missing (a broken-install signal, since the SEED guarantees roborev is installed), the bridge injects a **loud warning** into the agent's context — telling it to re-run the installer before continuing — rather than hard-blocking; it's a dev-tool nudge on a machine the operator controls, not a security gate.

Claude Code also gets a **pre-push gate** (`roborev-pre-push-gate.py`, same seed-owned path): where the bridge only *warns* before a commit, the gate **denies** a `git push` while the current branch has open fail-verdict reviews — after waiting up to 600s for in-flight reviews to land. Commit is too frequent to block, so it warns; push is the export boundary, so it gates — the forcing function that stops findings piling up unseen. The push stays blocked until each open fail review is **resolved**: fix the valid findings (a new commit) and decline the invalid/YAGNI ones (`roborev comment <id> -m "<why>"` recording why), then `roborev close <id>` either way — by hand, per finding, never delegated to the autonomous `roborev refine`/`roborev fix` loops (they apply every finding without the valid-vs-YAGNI judgment, and `refine` runs in a git worktree). It's Claude-only and bypassable on a box you control — a workflow forcing function against silently pushing over a `verdict=F` you never read, not a security boundary.

And a **pre-checkout gate** (`roborev-pre-checkout-gate.py`, same seed-owned path) closes the branch-leaving gap: it **denies** a `git checkout`/`git switch` to *another* branch while the branch being **left** has open (or still-in-flight) fail-verdict reviews — so findings can't be silently stranded by switching off the branch that dirtied them (the per-current-branch push gate would never see them once you've moved). File restores (`git checkout -- <path>`, `git checkout .`, `git restore …`) are NOT gated; it's the enforcement half of "drain before switching." All three hooks share one `_roborev_hooklib.py`, so they agree on what an "outstanding finding" is.

Finally, the SEED installs a **`roborev` usage skill** to `~/.claude/skills/roborev/SKILL.md` — the agent-facing complement to the hooks. The hooks bring findings *to* the agent; the skill teaches it how to *use* roborev and the review-loop contract (the gate *forces* the behavior, the skill *teaches* it, so it holds even where the gate is absent). It auto-activates on commit/push/checkout/switch and lands as a real file, so a config repo that symlink-manages its own skills leaves it intact. The full contract, command reference, and operational sharp edges live in [`skills/roborev/SKILL.md`](skills/roborev/SKILL.md) — the single source of truth, not duplicated here.

## Install

If your agent has the `seed-install` skill:

> Install `git@github.com:plow-pbc/seed-auto-roborev.git`

The agent clones the repo, reads [`SEED.md`](SEED.md), runs its `## Dependencies` install steps (announcing each shell block first), then answers the `## Verify` prompts. CI / non-AI callers can run the deterministic equivalents at [`ref/install.sh`](ref/install.sh) and [`ref/verify.sh`](ref/verify.sh).

## Adding a platform

`ref/install.sh` fetches the `roborev` binary from this repo's **GitHub Releases** as `roborev-<os>-<arch>` (e.g. `roborev-linux-x86_64`, `roborev-darwin-arm64`), pinned to a release tag (`ROBOREV_TAG` in `ref/install.sh`) and verified against a committed `sha256`. To add a new platform (e.g. Raspberry Pi `linux-aarch64`) or bump the version:

```bash
# build/obtain the binary for the platform, then (<tag> must match
# ROBOREV_TAG in ref/install.sh — the installer owns the canonical tag):
gh release upload <tag> path/to/roborev#roborev-linux-aarch64 -R plow-pbc/seed-auto-roborev
shasum -a 256 path/to/roborev   # or: sha256sum — copy the digest
```

Then add (or update) that platform's `asset`/`sha` arm in `ref/install.sh`'s `case` — and bump `ROBOREV_TAG` if it's a new release. The checksum lives in git so the binary is verified before it's ever run; an unverified or mismatched asset fails loud rather than installing. Until a platform is added, `ref/install.sh` fails loud with the exact upload command.

## License

MIT.
