# seed-roborev

A [SEED](https://github.com/plow-pbc/seed) that turns on **always-on local commit review** with [roborev](https://github.com/plow-pbc/roborev): every commit on the machine is reviewed automatically by a local AI reviewer, and open findings are surfaced before the next commit.

## Purpose

roborev is the cheap, local first line of review. Running it on **every commit on every machine** catches issues early — *before* they reach the expensive, multi-specialist knightwatch PR review — so each knightwatch round is worth its cost instead of re-flagging things a local pass would have caught.

This SEED is the one-shot installer for that: it wires roborev's git **post-commit** review (enqueue) + **daemon** (process the queue) machine-wide, and verifies the wiring fail-loud. The companion "surface open findings *before* a commit" piece ships separately in [claude-config](https://github.com/srosro/claude-config) as a Claude Code `PreToolUse` hook; this SEED owns the after-every-commit half.

## Install

If your agent has the `seed-install` skill:

> Install `git@github.com:plow-pbc/seed-roborev.git`

The agent clones the repo, reads [`SEED.md`](SEED.md), runs its `## Dependencies` install steps (announcing each shell block first), then answers the `## Verify` prompts. CI / non-AI callers can run the deterministic equivalents at [`ref/install.sh`](ref/install.sh) and [`ref/verify.sh`](ref/verify.sh).

## License

MIT.
