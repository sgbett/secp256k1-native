---
title: Releasing
nav_order: 9
---

# Releasing

This is the pre-tag checklist — a literal gate where each box has to be ticked *before* the tag is pushed. The H-2 leak shipped precisely because a narrative-only "bare-metal dudect is required" prose gate lapsed between 0.17.0 and 0.18.0 (the patched release), and this document codifies that gate so a future release cannot silently skip it.

## Pre-tag checklist

- [ ] CI all green (Ruby matrix × CodeQL × tests × docs × CT source guard × CT assembly invariant) **on the tag SHA**. `docs.yml` and `ct-*.yml` have `paths:` filters, so a chain of PRs before tagging that didn't touch the filtered paths can leave the last workflow run at a stale SHA — before tagging, trigger a fresh run of each on `master` via Actions → workflow → *Run workflow* and confirm green.
- [ ] `bundle exec rspec` green locally.
- [ ] `security/run-checks.sh` overall PASS (differential fuzz, ASan + UBSan sweep, ctgrind, CT source guard, CT assembly invariant). ctgrind requires valgrind — on macOS run this gate via the Docker image.
- [ ] **Bare-metal dudect run on the reference hardware** — see the [timing verification runbook](timing-verification-runbook.md). Record CPU / microcode / kernel / compiler + per-op |t| in [`docs/security.md`](security.md) (and [`docs/risks.md`](risks.md) if the result materially changes the CT claim).
- [ ] **Re-run bare-metal dudect if the pinned/known-good compiler version changed** since the last release.
- [ ] CHANGELOG `[Unreleased]` section closed out with the tag date.
- [ ] If the release fixes a security finding: in-repo advisory `Patched in` line updated; GHSA published; CVE requested via the GHSA flow.

## Why bare-metal dudect is the load-bearing step

The deterministic CT checks observe the *source-level / structural* CT contract — the source-mask guard and the assembly-invariant run in CI on every commit, and `ctgrind`/valgrind secret-poisoning runs on the reference machine and locally via `security/run-checks.sh` (it needs valgrind, so it is not a CI job); bare-metal dudect observes the *statistical timing of the shipping-shaped binary* (the standalone harness at vanilla `-O2` — not byte-identical to a per-user `gem install`; see [security.md](security.md#empirical-timing-verification)) on the known-good compiler. Between them these cover the two failure modes H-2 exposed:

- **Source-level regression** — a contributor introducing a new branch. Caught by CI (`security/check-ct-mask-guard.sh`, the assembly-invariant, RSpec).
- **Compiler-level regression** — the compiler reconstructing a branch from branchless source. Caught *structurally* by the assembly-invariant CI check (`.github/workflows/ct-assembly-invariant.yml`) on every commit for the ladder loop body and `jp_add_internal`, and *statistically* by bare-metal dudect on the shipping compiler.

The assembly-invariant check narrows the gap by observing binary *structure* per commit, but the shipping-shaped binary's *statistical timing* is a superset — bare-metal dudect on the release compiler stays required (H-2's specific shape happened to be caught in `uint256_select` and would trip the assembly check, but a hypothetical regression in code the check doesn't inspect would surface only in dudect).

## Related

- Security discipline overview: [Security](security.md)
- Runbook: [Timing verification runbook](timing-verification-runbook.md)
- Structural controls: umbrella issue #54 (source grep, assembly check, this checklist)
