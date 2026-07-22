---
title: Timing detection floor
parent: Security Review (v1.0)
nav_order: 4
---

# Timing-verification detection floor — a threat-model derivation

## Why this document exists

The dudect gate answers a binary question — is `|t| < 4.5`? — which is a *statistical-significance* threshold, not a security statement. A pass means "no leak was detected at this sample size", which is only as strong as the sample size makes it. This document derives the quantity that *is* a security statement — the **minimum detectable difference (MDD)**, in nanoseconds — ties the sample counts to an explicit threat model and risk tolerance rather than a wall-clock budget, and records why real-world asset value is a weak lever here (the question that prompted it).

Scope: this governs the **strict** (secret-scalar) operations, where a timing difference *is* a leak. The field/point **artefact** operations carry no secret (their operand-value latency is uncorrelated with the scalar — see [security.md](security.md#empirical-timing-verification)), so there is no attacker economics to compute for them and they are out of scope here.

## 1. The security-relevant quantity: minimum detectable difference (MDD)

For two classes with equal per-class sample count `n` and per-measurement timing standard deviation `σ`, Welch's t-statistic for a true mean difference `Δ` is

```
t = Δ / sqrt(2σ²/n) = Δ·√n / (σ·√2)
```

The gate flags a leak at `|t| ≥ τ` (`τ = 4.5`). Solving for the smallest `Δ` that trips the gate gives the **minimum detectable difference at the threshold**:

```
MDD_τ = τ·σ·√2 / √n ≈ 6.36 · σ / √n
```

`MDD_τ` is the 50-%-power floor — a `Δ` exactly this size is caught only half the time. For a claim of the form "a leak of size `Δ` *would have been caught*", use the **power-corrected** floor. To catch `Δ` with probability `1 − β` (add the standard-normal quantile `z_{1−β}`):

```
MDD_power ≈ (τ + z_{1−β})·σ·√2 / √n
```

At 99 % power (`z ≈ 2.33`), `MDD_99 ≈ 9.66·σ / √n`. This — not `|t| < 4.5` — is the number the certificate should state: *"this sweep would have caught, with ≥99 % probability, any secret-dependent timing difference ≥ MDD_99 ns."*

Two consequences fall straight out of `MDD ∝ σ / √n`:

- **Halving the floor costs 4× the samples.** The √ makes brute-force depth expensive — the same damping the attacker faces (§2).
- **σ is measured, not assumed.** The calibration sweep measures `σ` per operation, so the ruled-out `Δ` per op is an *output* of the run, not a guess.

## 2. The attacker's floor

An attacker faces the *same* statistics from the other side: they resolve a timing gap down to `Δ_att ∝ σ_att / √N_att`, where `σ_att` is their (larger) measurement noise and `N_att` their query budget. "Infinite queries" is not literal — `N_att` is bounded by rate limits, cost per query, and the risk of detection, which is what turns an abstract adversary into a finite floor.

Order-of-magnitude references from the literature (verify against the current editions before citing in a formal assessment):

- **Remote / network** — Crosby, Wallach & Riedi, *Opportunities and Limits of Remote Timing Attacks* (ACM TISSEC, ~2009): with enough averaging, ~100 ns is resolvable over a LAN, ~1 µs over a WAN. This is the classic model (cf. Brumley–Boneh 2005, ~1.4 M queries for an RSA key).
- **Co-located** (same host, shared cache/clock) — tighter, into the low-nanosecond range, but the attacker still contends for resources and cannot isolate the victim core the way the reference machine can.

The decisive property is the same √ damping: to resolve a `Δ` that is `k×` smaller, the attacker needs `k²×` the traces.

## 3. The security condition, and the sample count

Require our detection floor to sit below the chosen attacker's floor, with a margin `M` for "attacks only improve":

```
MDD_ours ≤ Δ_att / M
```

Substituting the power-corrected floor and solving for the required per-class sample count:

```
n ≥ ( (τ + z_{1−β}) · σ · √2 · M / Δ_att )²
```

This makes the sample count a *derived* quantity with two documented risk-tolerance knobs — the **attacker model** (which sets `Δ_att`) and the **margin `M`** (which banks headroom against future improvement). "≈5 minutes of compute" then falls out of `n`, rather than the other way round.

## 4. Where the samples go

Plugging plausible numbers in shows the field ops are already over-provisioned and the slow strict ops are the ones that matter:

| Operation | ≈ n / class | ≈ σ | ≈ MDD_99 |
|---|---|---|---|
| field ops (`fadd`/`fsub`/…) | ~750 000 | ~10–20 ns | **~0.1 ns** |
| `scalar_multiply_ct` (ladder) | ~5 000 | (measure) | ~ns |
| `scalar_inv` (Fermat) | ~500 | (larger — slow op) | **~tens–hundreds of ns** |

The field ops already rule out a *sub-nanosecond* secret-dependent difference — far below any attacker floor, so more samples there buy almost nothing. The **under-sampled, high-`σ` strict ops** (`scalar_inv`, `scalar_multiply_ct`) sit in the attacker-relevant band, so that is where added samples buy real floor. (The `σ` and MDD columns are filled from the calibration measurement; the numbers above are illustrative.)

Caveat on interpretation: a *branch*-shaped leak is large (`scalar_inv` skipping a `scalar_mul` ≈ hundreds of ns) and is caught even at low `n` — and is covered deterministically by ctgrind regardless of `n`. The MDD floor matters for a small *latency*-shaped leak, which is exactly the channel ctgrind cannot see (see [security.md](security.md#empirical-timing-verification)).

## 5. Asset value is a weak, √-damped lever — not a linear weight

The natural instinct is to scale the security target by the value at stake (e.g. BSV vs BTC market caps, a ~20× differential). For *this* decision that is mostly the wrong model, for three separate reasons:

- **Wrong unit.** A timing attack recovers *one private key per measured victim*, not the market cap. The loss term is the *distribution of value held per vulnerable key*, which is only loosely coupled to aggregate cap — a low-priced coin with a whale key is a bigger target than a high-priced coin in a dust wallet.
- **Wrong linearity.** Even where value legitimately buys attacker budget, the effect is √-damped: `Δ_att ∝ 1/√N_att`, so letting `N_att` scale linearly with value turns a **20× value differential into only ~√20 ≈ 4.5×** finer attacker resolution — which the existing margin on the well-sampled ops already absorbs.
- **Wrong stance — the primitive is asset-agnostic.** `secp256k1` is the same curve for BTC, BCH, Ethereum (ECDSA) and others; the *same object code* protects every consumer. You must calibrate to the **most-valuable / worst-plausible-future** consumer, because you cannot re-flash a shipped library when the price 20×s, and an exploit is developed once and amortised across all victims on all chains. Weighting *down* by a lower-cap asset would actively under-protect a higher-value user of the identical code.

Where the instinct *is* sound — and is retained — is narrower: asset value informs **which attacker model** to calibrate against (§3's `Δ_att`, √-damped), and **how to prioritise verification effort** across a portfolio of components (the Common Criteria "target of evaluation" scoping idea). Neither is a linear multiplier on the floor of a given primitive.

## 6. The economic corner solution

Put real values into the cost-of-check / cost-of-attack / loss trade-off for this asset class:

- **Loss ≈ catastrophic and amortised** — a leaked key is total (all past and future signatures, all funds) and the same leak hits every consumer at once.
- **Attacks only improve** — better statistics, hardware, and cross-victim amortisation erode any banked margin; you cannot patch a shipped, per-user-compiled library after the fact.
- **Defence is nearly free** — constant-time code is a one-time engineering cost at ~zero runtime overhead.

When loss is catastrophic-and-amortised, attacks monotonically improve, and defence is free, the optimisation collapses to a corner: **tolerate no detectable leak.** So the conservative TVLA/dudect stance is the *output* of the economics, not a naïve alternative to them. The derivation in this document therefore sets **how hard we look** (the sample count / the ruled-out `Δ`), never **how much leak we tolerate** (none detectable).

## 7. What the certificate reports

Per strict operation, the sweep report should state:

- measured `σ`, sample count `n`, and the derived **MDD_99 (ns)**;
- the attacker floor `Δ_att` it was calibrated against, and the achieved margin `MDD_99 / Δ_att`.

That converts "`|t| < 4.5`" into an attacker-comparable claim — *"rules out a secret-dependent timing difference ≥ X ns, ≥ M× below a [network / co-located] attacker's resolution"* — which is a materially stronger and more honest security statement.

## Risk-tolerance defaults (the two knobs to dial)

- **Attacker model → `Δ_att`.** Default to the tighter *co-located* floor rather than the looser network one (conservative; informed, but not linearly scaled, by asset exposure per §5).
- **Margin `M`.** Default generous (e.g. 10–100×) because compute is cheap and "attacks only improve"; a large `M` is free insurance here, not a tuned optimum.

## Honest boundary

The *fully* quantified approach — bounding the actual mutual / perceived information leaked (the "leakage certification" line, e.g. Bronchain–Standaert) — is evaluation-lab / academic territory. For a source-shipped library, MDD-versus-attacker-floor-with-margin is the *proportionate* level of rigour; full information-theoretic certification would be over-engineering.

## References

Pointers to verify against current editions, not verbatim citations:

- Reparaz, Balasch & Verbauwhede, *Dude, is my code constant time?* (DATE 2017) — the dudect methodology.
- Goodwill, Jun, Rohatgi & Rohrig, *A testing methodology for side-channel resistance validation* (2011) — TVLA; now ISO/IEC 17825.
- Standaert, Malkin & Yung, *A Unified Framework for the Analysis of Side-Channel Key Recovery Attacks* (Eurocrypt 2009) — success rate / guessing entropy vs traces.
- Crosby, Wallach & Riedi, *Opportunities and Limits of Remote Timing Attacks* (ACM TISSEC, ~2009) — network resolution vs samples.
- Standaert, *How (not) to Use Welch's t-test in Side-Channel Security Evaluations* (CARDIS 2018) — detection ≠ exploitation.
- Joint Interpretation Library, *Application of Attack Potential to Smartcards* — the standardised attack-potential (time / expertise / equipment / samples) rating used in Common Criteria evaluations.
