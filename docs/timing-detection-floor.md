---
title: Timing detection floor
parent: Security Review (v1.0)
nav_order: 4
---

# Timing-verification detection floor — a threat-model derivation

## Why this document exists

The dudect gate answers a binary question — is `|t| < 4.5`? — which is a *statistical-significance* threshold, not a security statement. A pass means "no leak was detected at this sample size", which is only as strong as the sample size makes it. This document derives the quantity that *is* a security statement — the **minimum detectable difference (MDD)**, in nanoseconds — ties the sample counts to an explicit threat model and risk tolerance rather than a wall-clock budget, and records why real-world asset value is a weak lever here (the question that prompted it).

Scope: the MDD analysis below governs the **strict** end-to-end operations — `scalar_multiply_ct` and the strict-tier scalar arithmetic `scalar_mul` / `scalar_reduce` / `scalar_inv` (note `scalar_add` is *not* strict-gated — the harness emits no dudect line for it), whose dudect classes *are* secret-derived, so a detectable difference *is* a leak. The field/point operations also process secret-derived operands (the ladder feeds them the infinity accumulator and secret-scalar state for a scalar-dependent number of iterations — see [security.md](security.md#empirical-timing-verification)), but their *standalone* dudect tests deliberately use **synthetic, non-secret** operand-magnitude classes. Their |t| therefore measures sensitivity to those synthetic classes, not secret correlation; secret non-correlation for the field/point layer is established — *in the tested `k = 1`-vs-random contrast* — end-to-end by the strict ladder test (other partitions and higher moments remain the documented residual of §1, backstopped for the branch channel by ctgrind). So the attacker economics apply to the strict ops — the standalone field figures are a diagnostic, not a security floor.

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

At 99 % power (`z ≈ 2.33`), `MDD_99 ≈ 9.66·σ / √n`. This — not `|t| < 4.5` — is the number the certificate should state: *"this sweep would have caught, with ~99 % probability, a secret-dependent difference ≥ MDD_99 ns **in the tested class-mean contrast**."* Two qualifiers are load-bearing. First, the ~99 % is a **model estimate**, not a guaranteed lower bound: it uses a normal approximation and plugs in *sample* variances, so with finite samples — acute at ~500/class for `scalar_inv` — Welch's degrees of freedom and denominator are themselves estimated. Treat it as "≈99 % power under the additive-mean-shift model with sample-variance plug-in"; a conservative noncentral-Welch power with variance uncertainty is a #79 refinement. Second, the class-mean-contrast scope:

**What the MDD does and does not bound.** dudect — like TVLA — detects a *first-order* (mean) difference between the *two classes the harness picks* (for the ladder, `k = 1` vs a random scalar). MDD bounds a leak *in that contrast*. By itself it does not bound a leak that correlates with a *different* partition of the secret, that lives in a *higher moment* (a variance rather than a mean difference), or that cancels within the chosen classes. Two things narrow that gap: the classes are chosen to be worst-case for the operation — the `k = 1`-vs-random split maximises the ladder's scalar-dependent infinity-timing contrast, the site of the historical |t| = 875 leak (v0.17.0's infinity-branch, since fixed; distinct from the #25 GCC-15 reconstruction at |t| ≈ 21) — and **ctgrind covers the branch/addressing channel partition-agnostically** (it flags any secret-dependent branch or address, whatever the partition). What remains is a latency leak in an *untested* partition or moment; that residual is documented, not claimed away.

**The 20-run fraction gate vs the single-run MDD.** `MDD_99` above is the 99 %-power floor for a *single* run's `|t| ≥ τ` decision. The strict gate instead runs each op `N = 20` times and fails at **≥2 of 20** over threshold. In principle that aggregation lowers the floor via the order statistic: *if* the 20 runs were independent with equal per-run detection probability `p`, the gate would detect a consistent leak with `1 − (1−p)²⁰ − 20p(1−p)¹⁹`, which exceeds 99 % at `p ≈ 0.29`, giving a floor `Δ ≈ 5.6·σ/√n` — about **1.7× below** the single-run `MDD_99 ≈ 9.66·σ/√n`. **That independence is not established, though**: the 20 runs are sequential on one machine and the harness replays a fixed input/class seed, so shared thermal / frequency / machine-state effects can positively correlate their t-statistics — which makes the binomial *overstate* the aggregate power. So the honest default is to **report the conservative *per-run* bound** — the *maximum* per-run `MDD_99` across the 20 runs (§8). That is a per-run detection statement (each run would have caught a leak ≥ this with ~99 % probability) and does not depend on the independence assumption; it is deliberately **not** a claim about the ≥2/20 gate's *aggregate* power, which under unconstrained dependence is not pinned by the per-run figure (correlated runs can leave aggregate power below the per-run 99 %). The ~1.7× order-statistic gain — and the √20 ≈ 4.5× from *full* pooling — become available only after run-dependence is validated or modelled, an analysis/`n`-budget item for #79. (The `≥2/20` rule's role in the certificate is noise-robustness — it rejects a lone over-threshold run so a transient does not red the gate — not a licence for a smaller certified floor, which needs that dependence analysis.)

Three consequences fall straight out of `MDD ∝ σ / √n`:

- **Halving the floor costs 4× the samples.** The √ makes brute-force depth expensive — the same damping the attacker faces (§2).
- **σ is measured, not assumed.** The calibration sweep measures the per-class timing spread per operation, so the ruled-out `Δ` per op is an *output* of the run, not a guess.
- **The single-`σ`, equal-`n` form is a convenience approximation.** The harness computes the *general* Welch standard error `√(s₀²/n₀ + s₁²/n₁)` (`timing/dudect.c`), and pseudorandom class assignment gives unequal counts and possibly unequal variances. The balanced `σ/√n` form above is fine for reasoning about scaling, but the **reported** MDD (§8) must be computed from the two measured class variances and counts, or it can understate the floor and fail to support the ~99 % power claim.

## 2. The attacker's floor

An attacker faces the *same* statistics from the other side: they resolve a timing gap down to `Δ_att ∝ σ_att / √N_att`, where `σ_att` is their (larger) measurement noise and `N_att` their query budget. "Infinite queries" is not literal — `N_att` is bounded by rate limits, cost per query, and the risk of detection, which is what turns an abstract adversary into a finite floor.

Order-of-magnitude references from the literature (verify against the current editions before citing in a formal assessment):

- **Remote / network** — Crosby, Wallach & Riedi, *Opportunities and Limits of Remote Timing Attacks* (ACM TISSEC, ~2009): with enough averaging, ~100 ns is resolvable over a LAN, degrading to the microsecond range over the wider Internet. **Take the exact network figure from the primary source at calibration time — it feeds `Δ_att` and must not be quoted from memory** (drafts of this doc mis-stated the Internet figure). This is the classic model (cf. Brumley–Boneh 2005, ~1.4 M queries for an RSA key).
- **Co-located** (same host, shared cache/clock) — tighter, into the low-nanosecond range, but the attacker still contends for resources and cannot isolate the victim core the way the reference machine can.

The decisive property is the same √ damping: to resolve a `Δ` that is `k×` smaller, the attacker needs `k²×` the traces.

## 3. The security condition, and the sample count

Require our detection floor to sit below the chosen attacker's floor, with a margin `M` for "attacks only improve":

```
MDD_ours ≤ Δ_att / M
```

Substituting the power-corrected floor and solving for the required per-class sample count:

```
n ≥ ( (τ + z_{1−β}) · σ · √2 · M / Δ_att )²           (equal-variance form)
```

The `σ·√2` here is the equal-variance convenience form (§1). For the real, unequal per-class variances, substitute `σ·√2 → √(σ₀² + σ₁²)` at a planned equal count `n` per class — i.e. derive `n` from `σ₀² + σ₁²`, using the *larger*/actual variances so the run is not under-provisioned. This makes the sample count a *derived* quantity with two documented risk-tolerance knobs — the **attacker model** (which sets `Δ_att`) and the **margin `M`** (which banks headroom against future improvement). "≈5 minutes of compute" then falls out of `n`, rather than the other way round.

## 4. Where the samples go

The security floor is the MDD of the **strict** ops, whose classes are secret-derived (§scope). Among them, the slow, under-sampled ops set the coarsest — and only attacker-relevant — floor:

| Strict operation | ≈ n / class | ≈ σ | ≈ MDD_99 |
|---|---|---|---|
| `scalar_multiply_ct` (ladder) | ~5 000 | (measure) | ~ns |
| `scalar_inv` (Fermat) | ~500 | (larger — slow op) | **~tens–hundreds of ns** |

All four strict ops have secret-derived classes, so all four have an attacker-relevant MDD. `scalar_inv` and `scalar_multiply_ct` are the ones with the *fewest* samples — they are slow, so their counts were kept low — so they are the *likely coarsest* floor and the most likely place added samples buy real security; the calibration's measured `σ` confirms which actually dominates. (The `σ` and MDD columns are filled from that measurement; the numbers are illustrative.)

The field-op standalone tests (`fadd`/`fsub`/… at ~750 000 samples/class) are **not** secret-dependence tests: they compare synthetic operand-magnitude classes and, on GCC 15.1, register a real *non-zero* operand-value artefact (§scope; [security.md](security.md#empirical-timing-verification)). Their very tight sensitivity (~0.1 ns to those synthetic classes) is a diagnostic that the field arithmetic is well-behaved — **not** a secret-dependence floor. Secret correlation for the field/point layer is caught end-to-end by the strict ladder above, so more field-op samples buy diagnostic resolution, not security.

Caveat on interpretation: a *branch*-shaped leak is large (`scalar_inv` skipping a `scalar_mul` is of order a scalar-mul's cost — plausibly hundreds of ns) and is caught even at low `n` — and is covered deterministically by ctgrind regardless of `n`. The MDD floor matters for a small *latency*-shaped leak, which is exactly the channel ctgrind cannot see (see [security.md](security.md#empirical-timing-verification)).

## 5. Asset value is a weak, √-damped lever — not a linear weight

The natural instinct is to scale the security target by the value at stake (e.g. BSV vs BTC market caps, a ~20× differential). For *this* decision that is mostly the wrong model, for three separate reasons:

- **Wrong unit.** A timing attack recovers *one private key per measured victim*, not the market cap. The loss term is the *distribution of value held per vulnerable key*, which is only loosely coupled to aggregate cap — a low-priced coin with a whale key is a bigger target than a high-priced coin in a dust wallet.
- **Wrong linearity.** Even where value legitimately buys attacker budget, the effect is √-damped: `Δ_att ∝ 1/√N_att`, so letting `N_att` scale linearly with value turns a **20× value differential into only ~√20 ≈ 4.5×** finer attacker resolution — which a sufficiently large `M` could absorb, *if* `M` is calibrated to cover it (§3; the margin is future #79 work, not an existing calibrated quantity).
- **Wrong stance — the primitive is asset-agnostic.** `secp256k1` is the same curve for BTC, BCH, Ethereum (ECDSA) and others, and this gem ships as *source* compiled per installation — so it is the same **source contract**, not the same object code, that protects every consumer (the per-user binary is not even predictable, which is exactly why the #25 GCC-15.2 reconstruction mattered). You must calibrate to the **most-valuable / worst-plausible-future** consumer, because you cannot re-flash a shipped library when the price 20×s, and exploit-development cost is amortised across all victims on all chains. Weighting *down* by a lower-cap asset would actively under-protect a higher-value user of the identical source.

Where the instinct *is* sound — and is retained — is narrower: asset value informs **which attacker model** to calibrate against (§3's `Δ_att`, √-damped), and **how to prioritise verification effort** across a portfolio of components (the Common Criteria "target of evaluation" scoping idea). Neither is a linear multiplier on the floor of a given primitive.

## 6. The economic corner solution

Put real values into the cost-of-check / cost-of-attack / loss trade-off for this asset class:

- **Loss is high per victim, and the *exploit* amortises** — a recovered key hands the attacker that key's current holdings and all *future* signatures under it (not retroactively-spent funds, and not every consumer at once). What amortises is the *exploit-development* cost: the technique is built once and re-applied to any vulnerable victim over time. So per-victim loss is high *and* the attack is reusable — a leak is worth exploiting even for a modestly-funded key.
- **Attacks only improve** — better statistics, hardware, and exploit reuse erode any banked margin; and you cannot *rely on* every consumer promptly updating a shipped, per-user-compiled library, nor predict the per-user binary — so retroactive patching is not a dependable control.
- **Defence is nearly free** — constant-time code is a one-time engineering cost at ~zero runtime overhead.

When loss is catastrophic-and-amortised, attacks monotonically improve, and defence is free, the optimisation collapses to a corner: **tolerate no detectable leak.** So the conservative TVLA/dudect stance is the *output* of the economics, not a naïve alternative to them. The derivation in this document therefore sets **how hard we look** (the sample count / the ruled-out `Δ`), never **how much leak we tolerate** (none detectable).

## 7. Re-review triggers — and what doesn't

Because a passing sweep is a bounded *no-leak-detected* claim — a detection bound down to the MDD floor (§8), not proof of absence and not acceptable presence — the calibration is robust to some changes over time and sensitive to others. The distinction is operational — it says when a certificate must be regenerated, and answers the intuitive worry that a rising value at risk should force periodic review.

- **Asset value / price drift → effectively no re-review for plausible growth.** A passing certificate is a detection bound down to the MDD floor (§8); the code's timing behaviour it measures is a physical fact independent of price. The √-damping (§5) and a generous margin `M` (§3), with a conservative attacker model chosen up front, pre-absorb plausible growth — routine price movement stays inside the banked headroom. It is *not* a hard exemption, though: because §5 lets attacker query budget grow with value, `Δ_att` falls as value rises, so order-of-magnitude growth that pushes `MDD_99 > Δ_att / M` would require recalibration. The √-damping makes that a slow, checkable trigger (a ~100× value rise buys the attacker only ~10× resolution) — far weaker and rarer than the toolchain axis below, but reviewed against `M`, not ignored.
- **Toolchain *or microarchitecture* change → mandatory re-run.** A change to the `(source, compiler, flags, CPU/microcode)` tuple can move the compiled timing: a compiler reconstructing a branch from branchless source (the advisory-0001 / issue-#25 mechanism, invisible to source review), or new silicon/microcode shifting operand-value latency and the measured `σ` — which moves the MDD itself, invalidating the certificate even with source/compiler/flags fixed. The certificate stamps the CPU model and microcode revision precisely so such a change is detectable; it is the reference machine's standing re-run trigger (a `nixpkgs`/compiler-rev bump, or new silicon/microcode), firing on a *change event*, not a calendar. This is the sharp, concrete form of "review over time".
- **Attacker-capability advances → slow cadence.** Better statistics, hardware, or trace analysis lower the attacker floor `Δ_att` over time (the "attacks only improve" axis). This is precisely what the generous margin `M` buffers; revisit `M` and the attacker model on a long horizon, not per price move.

The counter-intuitive summary: the axis one expects to dominate re-review — how much is at stake — is √-damped and mostly absorbed by the margin, so it rarely triggers one; the compiler is the sharp, discrete trigger that reliably does.

## 8. What the certificate reports

Per strict operation, the sweep report should state:

- for each run, the two class variances and counts (`s₀,n₀`; `s₁,n₁`) and the per-run `MDD_99` from the general Welch standard error `√(s₀²/n₀ + s₁²/n₁)` (not a single-σ approximation), reduced across the 20 runs by a **stated rule**: the *maximum* per-run `MDD_99` (the deliberately conservative default, §1), or — *only* once run-dependence has been validated or modelled (§1) — the aggregate `≥2/20` gate floor; never an arbitrary or best-case run;
- the attacker floor `Δ_att` it was calibrated against, and the achieved headroom `Δ_att / MDD_99` (≥ `M` when the condition `MDD_99 ≤ Δ_att / M` holds).

That converts "`|t| < 4.5`" into an attacker-comparable claim — *"would have detected, with ~99 % probability, a secret-dependent difference ≥ X ns **in the tested class-mean contrast**, ≥ M× below a [network / co-located] attacker's resolution"* (with the §1 scope caveat, and ctgrind as the partition-agnostic branch backstop) — a materially stronger and more honest security statement than a bare `|t| < 4.5`. Note the framing: a *detection* bound ("would have caught"), not a claim of *absence* ("rules out") — the residuals in §1 mean the two are not the same.

## Risk-tolerance defaults (the two knobs to dial)

- **Attacker model → `Δ_att`.** Default to the tighter *co-located* floor rather than the looser network one (conservative; informed, but not linearly scaled, by asset exposure per §5).
- **Margin `M`.** Choose `M` from a documented risk posture — a future-capability horizon for "attacks only improve" — and *derive* `n` from it (§3), not the other way round. It is *not* free: `n ∝ M²`, so `M` 10→100 costs 100× the samples, with the binding constraint on the slow strict ops (`scalar_inv`, `scalar_multiply_ct`). If the derived `n` is infeasible there, that is an explicit tradeoff to surface — report the achieved `M`, or knowingly accept a higher floor — never let the compute budget silently cap the security margin, which would reverse the threat-model-first derivation this document exists to establish.

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
