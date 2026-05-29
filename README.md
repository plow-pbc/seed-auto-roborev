# seed-roborev

A [SEED](https://github.com/plow-pbc/seed) that turns on **always-on local commit review** with [roborev](https://github.com/plow-pbc/roborev): every commit on the machine is reviewed automatically by a local AI reviewer, and open findings are surfaced before the next commit.

## Purpose

roborev is the cheap, local first line of review. Running it on **every commit on every machine** catches issues early — *before* they reach the expensive, multi-specialist knightwatch PR review — so each knightwatch round is worth its cost instead of re-flagging things a local pass would have caught.

This SEED is the one-shot installer for that. It wires both halves of the loop machine-wide and verifies them fail-loud:

- **review after every commit** — a git `post-commit` hook enqueues a roborev review; a user-level `daemon` processes the queue.
- **check results before the next commit** — a git `pre-commit` hook surfaces open findings to stderr, which lands in the `git commit` output the committing agent sees. This is **agent-agnostic** (covers claude, codex, and humans) — codex has no Claude-style pre-tool hook, so a git-level hook is the only thing that reaches it.

Claude Code additionally gets an *earlier*, richer version of the before-commit check via [claude-config](https://github.com/srosro/claude-config)'s `PreToolUse` hook — a complement to the universal git `pre-commit`, not a replacement.

## Install

If your agent has the `seed-install` skill:

> Install `git@github.com:plow-pbc/seed-roborev.git`

The agent clones the repo, reads [`SEED.md`](SEED.md), runs its `## Dependencies` install steps (announcing each shell block first), then answers the `## Verify` prompts. CI / non-AI callers can run the deterministic equivalents at [`ref/install.sh`](ref/install.sh) and [`ref/verify.sh`](ref/verify.sh).

## License

MIT.
