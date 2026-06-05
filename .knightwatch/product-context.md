# Product context

This is a **SEED-convention repo**: `SEED.md` and `README.md` (RFC-2119
prose) are the authoritative artifacts; `ref/` is a single-operator
reference implementation of that prose. Review for **convention conformance
and prose↔ref drift**, not for product-scale hardening.

Operating point (org default):

- **Stage:** pre-PMF, early. Iteration speed > hardening for scale.
- **Userbase:** fewer than 10 users, often a single operator. Abstractions,
  flags, parallel modes, and defensive edge-case handling sized for
  thousands of users are over-engineering here, not robustness.
- **Spec rigidity:** the SEED prose IS the contract; a handled edge case the
  spec never asked for is a cost, not a feature.

**This repo's `ref/` payload:** Python Claude Code `PreToolUse[Bash]` hooks (commit context bridge, pre-push gate, shared hooklib) plus a bash install/test/verify harness. (roborev owns the actual git hooks — `post-commit`/`post-rewrite`, installed via `roborev install-hook` — not shipped in `ref/`.)
