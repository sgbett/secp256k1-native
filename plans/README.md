# Plans

Working implementation plans captured from the pre-v1.0 security review while the
context was fresh, so the fixes can be picked up cold (e.g. from a different
machine). Each maps to a tracking issue and the
[review report](../docs/security-review-v1.md).

- [`21-scalar-reduction-carry.md`](21-scalar-reduction-carry.md) — issue #21
  (v1 blocker): H-1 / I-2 / I-11, with the exact branchless C patch.
- [`22-boundary-hardening.md`](22-boundary-hardening.md) — issue #22: M-1 / L-3 /
  I-3 / L-4 / L-1 / L-2, wrapper reduce/validate fixes.
- [`reference-machine-nix.md`](reference-machine-nix.md) — follow-on to #25
  (shipped in v0.18.0): codify the bare-metal dudect reference machine as
  declarative NixOS config (pinned toolchain + quiet-machine module + gate
  command). Forward-looking, not a review fix — renumber `NN-…` once an issue is filed.

Issue #23 (polish) is small enough that its issue text suffices — no plan.

To run the verification gates these plans reference, see
[`docs/running-checks.md`](../docs/running-checks.md) (Docker covers the three
deterministic gates incl. ctgrind; the dudect timing pass — issue #25, fixed in
v0.18.0 — needs bare metal per
[`docs/timing-verification-runbook.md`](../docs/timing-verification-runbook.md),
with [`reference-machine-nix.md`](reference-machine-nix.md) the plan to make that
box reproducible).
