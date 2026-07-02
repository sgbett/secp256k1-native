---
title: Releasing
nav_order: 9
---

# Releasing

Pre-tag checklist. This is a literal gate — each box has to be ticked *before* the tag is pushed. The H-2 leak shipped precisely because a narrative-only "bare-metal dudect is required" prose gate lapsed between 0.17.0 and v1; codifying it here so a future release cannot silently skip it.

## Pre-tag checklist

- [ ] CI all green (Ruby matrix × CodeQL × tests × docs).
- [ ] `bundle exec rspec` green locally.
- [ ] Differential gate (`security/run-checks.sh`) — `regression vectors diverging = 0/7`.
- [ ] ctgrind clean (Docker on macOS, native on Linux).
- [ ] **Bare-metal dudect run on the reference hardware** — see the [timing verification runbook](timing-verification-runbook.md). Record CPU / microcode / kernel / compiler + per-op |t| in [`docs/security.md`](security.md) (and [`docs/risks.md`](risks.md) if the result materially changes the CT claim).
- [ ] **Re-run bare-metal dudect if the pinned/known-good compiler version changed** since the last release.
- [ ] CHANGELOG `[Unreleased]` section closed out with the tag date.
- [ ] If the release fixes a security finding: in-repo advisory `Patched in` line updated; GHSA published; CVE requested via the GHSA flow.

## Why bare-metal dudect is the load-bearing step

`ctgrind` observes the *source-level* CT contract on the CI toolchain; bare-metal dudect observes the *statistical timing of the shipping binary* on the known-good compiler. Between them these cover the two failure modes H-2 exposed:

- **Source-level regression** — a contributor introducing a new branch. Caught by CI (`security/check-ct-mask-guard.sh`, ctgrind, RSpec).
- **Compiler-level regression** — the compiler reconstructing a branch from branchless source. Caught only by bare-metal dudect on the shipping compiler.

The assembly-invariant CI check (`.github/workflows/ct-assembly-invariant.yml`) narrows the gap by observing binary *structure* on every commit, but the shipping binary's *statistical timing* is a superset — bare-metal dudect on the release compiler stays required.

## Related

- Security discipline overview: [Security](security.md)
- Runbook: [Timing verification runbook](timing-verification-runbook.md)
- Structural controls: umbrella issue #54 (source grep, assembly check, this checklist)
