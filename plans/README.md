# Plans

Working implementation plans, tracked at the repo root so they land via PR and can be
picked up cold from another machine. (This project's `.claude/` is gitignored, so plans
live here, not under `.claude/plans/`.) Each maps to a tracking issue; the security-review
plans also map to the [review report](../docs/security-review-v1.md).

- [`21-scalar-reduction-carry.md`](21-scalar-reduction-carry.md) — #21 (v1 blocker):
  H-1 / I-2 / I-11, with the exact branchless C patch.
- [`22-boundary-hardening.md`](22-boundary-hardening.md) — #22: M-1 / L-3 / I-3 / L-4 /
  L-1 / L-2, wrapper reduce/validate fixes.
- [`61-reference-machine-nix.md`](61-reference-machine-nix.md) — [HLR] #61, follow-on to
  #25: codify the bare-metal dudect reference machine as declarative NixOS config (pinned
  toolchain + quiet-machine module + gate command). Forward-looking, not a review fix.

To run the gates these plans reference, see [`docs/running-checks.md`](../docs/running-checks.md):
Docker covers the three deterministic gates (incl. ctgrind); the dudect timing pass (#25)
needs bare metal per [`docs/timing-verification-runbook.md`](../docs/timing-verification-runbook.md),
which [`61-reference-machine-nix.md`](61-reference-machine-nix.md) aims to make reproducible.
