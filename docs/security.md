---
title: Security
nav_order: 4
---

# Security

Safe usage guide, constant-time properties, and threat model for this gem.

## API safety guide

The `Point` class exposes two scalar multiplication methods:

| Method | Algorithm | Timing | Use for |
|---|---|---|---|
| `Point#mul(scalar)` | Montgomery ladder | **Constant-time** | All scalars — the safe default |
| `Point#mul_vt(scalar)` | wNAF (window size 5) | **Variable-time** | Public scalars only: signature verification, batch operations where speed matters |

`mul` is constant-time by default, matching OpenSSL's behaviour. The safe path is the easy path — you only need to think about the distinction if you need the ~2x speed advantage of `mul_vt` for public-scalar workloads.

`mul_ct` is retained as a deprecated alias for `mul`.

```ruby
g = Secp256k1::Point.generator
pubkey = g.mul(secret_key)          # safe for secret scalars (constant-time)
point = pubkey.mul(public_hash)     # safe for public scalars too (just slower)
point = pubkey.mul_vt(public_hash)  # faster, but only when scalar is public
```

### Constructing `Point` objects

Use one of these entry points for any `Point` instance you will later operate on with `mul` / `mul_vt`:

- `Point.generator` — the well-known generator G.
- `Point.from_bytes(bytes)` — SEC1 compressed (33 B) or uncompressed (65 B) deserialisation; validates `on_curve?` before returning.
- `Point.from_coordinates(x, y)` — raw coordinates with `on_curve?` validation; the required entry point for caller-supplied coordinates from an external protocol or user input.

`Point.new(x, y)` is the underlying constructor used by internal paths that *already know* the coordinates lie on the curve (`mul`, `add`, `negate`, etc.). It validates that x and y are Integers in `[0, P)` but does **not** verify curve membership. Calling `mul` on a Point built from off-curve coordinates is an invalid-curve precondition — always prefer `from_coordinates` for caller-supplied inputs (L-5).

### Pure-Ruby safety guard

`mul` will raise `Secp256k1::InsecureOperationError` if the native C extension is not loaded. This prevents silent degradation to pure-Ruby arithmetic that cannot guarantee constant-time execution. `mul_vt` is unaffected — it is explicitly variable-time and does not claim constant-time properties.

To check whether the extension is active:

```ruby
Secp256k1.native?  # => true if C extension is loaded
```

If you have evaluated the [risks](risks.md) and consciously accept the pure-Ruby implementation for your threat model, you can override the guard:

```ruby
# Option 1: environment variable
ENV['SECP256K1_ALLOW_PURE_RUBY_CT'] = '1'

# Option 2: explicit call (e.g., in an initialiser)
Secp256k1.allow_pure_ruby_ct!
```

Public-scalar operations (`mul`, field arithmetic, point operations) are unaffected and work in both modes without restriction.

## Constant-time discipline

### Field arithmetic

The field operations `fred`, `fsub`, `fneg`, and `fadd` use branchless conditional selection via bitwise masks derived from carry and borrow flags. Execution time does not depend on field values.

Inversion (`finv`) and square root (`fsqrt`) iterate over public constants (P-2 and (P+1)/4 respectively). Since the exponents are not secret, the variable iteration pattern is safe.

### Scalar arithmetic

The scalar operations `scalar_mul_internal`, `scalar_reduce`, and `scalar_add_internal` use branchless conditional selection — bitwise masks from carry/borrow flags and a captured topcarry — with no operand-dependent control flow. After the #21 fix, `scalar_reduce_limbs` is fully branchless: the previous `if (h == 0) continue` and `if (carry3)` guards in the residual fold were removed (the second-fold loop body is a faithful no-op when `h == 0`; the residual fold is now unconditional with topcarry capture, replacing the dropped-carry tail that caused H-1).

### Ruby↔C boundary contracts (#22)

After #22, the Ruby-facing wrappers enforce — not merely document — the Integer-in-`[0, P)` / `[0, N)` contract for every operation:

- All 16 native wrappers reject non-Integer inputs with `TypeError` (L-1). The 256-bit wrappers share one guard at `rb_to_uint256`; `rb_fred` packs 8 limbs directly (for 512-bit intermediates) and carries its own `RB_INTEGER_TYPE_P` guard.
- `rb_fadd` / `rb_fsub` / `rb_fneg` pre-reduce operands via `fred_internal` so the `_internal` functions' `a, b < P` precondition is always met (L-3, I-3).
- `rb_scalar_add` pre-reduces both operands mod N (M-1).
- `rb_scalar_mod` accepts any-width Integer (positive or negative) via Ruby `%` (L-4).
- `Point#mul` / `#mul_vt` reject non-Integer scalars with `ArgumentError` at the Ruby boundary (L-2). `Point#initialize` rejects y outside `[0, P)`.
- Pure-Ruby `fsub` / `fneg` canonicalise operands so the dfuzz differential's Ruby oracle agrees with the C wrapper on ≥ P inputs.

The C `_internal` functions retain the documented `a, b < P` / `< N` preconditions and are called directly from `jacobian.c` (which only feeds canonical intermediates) and from the wrappers post-reduction.

#### Pure-Ruby fallback divergences

Two intentional divergences exist between the pure-Ruby module functions (used when the C extension is not loaded) and the native wrappers:

- **Low-level field/scalar methods do not type-check.** `Secp256k1.fmul(1.5, 2)` and similar will compute on the Float value rather than raising `TypeError`. The user-facing `Point#mul` / `#mul_vt` reject non-Integer scalars at the Ruby boundary on both backends; the low-level pure-Ruby methods are documented as expecting `Integer` and do not enforce it. Users who need strict typing on the low-level surface should ensure the C extension is loaded.
- **`fsub` / `fneg` accept negative inputs in pure-Ruby**, returning the canonical non-negative residue (Ruby `%` semantics). The C wrappers reject negatives via `rb_to_uint256`. Backend parity holds for all non-negative inputs; the dfuzz harness only feeds non-negative inputs so the differential never observes this case.

`scalar_inv_internal` iterates over bits of the public constant N-2 via Fermat's little theorem. The branch on each bit is over public data; the per-iteration `scalar_mul_internal` operates on the secret base and is branchless.

### Montgomery ladder

The C extension implements the Montgomery ladder with a branchless conditional swap (`cswap`) using bitwise masking — no branch on the scalar bit. Both `cswap` and `jp_add_internal` are fully branchless: all input-dependent special cases (infinity checks, equal/negated point detection) are handled via mask-based `uint256_select` rather than conditional branches. This provides genuine constant-time scalar multiplication at the C level, with fixed 256 iterations regardless of scalar value.

### Pure-Ruby constant-time caveats

The Montgomery ladder algorithm is constant-time by design (fixed iteration count, no scalar-dependent branches). However, Ruby's interpreter introduces timing variability:

- Bignum arithmetic may have input-dependent timing at the VM level
- Garbage collection pauses are unpredictable
- No control over CPU cache behaviour

For production-grade side-channel resistance, use the native C extension. The pure-Ruby fallback provides algorithmic constant-time behaviour but cannot guarantee microarchitectural constant-time execution.

### Empirical timing verification

The C extension's constant-time claims are empirically tested at two levels, which answer different questions:

- **Deterministic (data-flow + disassembly).** Two checks answer *does any secret reach a branch?* without relying on timing. **ctgrind / valgrind** poisons secret inputs and lets Memcheck track data flow to any conditional jump/move or memory address — run on the reference machine and locally via `security/run-checks.sh` (it needs valgrind, so it is not a CI job). A **CT assembly-invariant** disassembles the compiled ladder + `jp_add_internal` and asserts no secret-dependent branch/cmov — this is the deterministic check that runs in **CI** on every push (`.github/workflows/ct-assembly-invariant.yml`), alongside a source-level mask-construction guard (`check-ct-mask-guard.sh`). Both are independent of hardware and noise, so they are trustworthy anywhere — the *primary* constant-time evidence.
- **Statistical (dudect, run on bare metal).** Following Reparaz, Balasch, and Verbauwhede (2017): for each function, two input classes exercise different sides of a branchless conditional, timings are collected, and Welch's t-test asks whether the distributions are distinguishable (|t| < 4.5 ⇒ no detectable leak). This is only trustworthy on a quiet, frequency-pinned physical machine — see the [bare-metal runbook](timing-verification-runbook.md), the [reproducible reference machine](reference-machine.md) that automates it across a pinned compiler set, and issue #25. It answers: *is the **compiled** timing actually flat?* — something no source inspection can establish.

Both are necessary, because **a source-level branchless implementation is not a compiled-level guarantee.** The compiler sits between them, and it can reintroduce a branch the source took pains to avoid.

#### The GCC 15 reconstruction finding (issue #25)

The bare-metal dudect pass for v1 (AMD Ryzen 9 9950X, GCC 15.2.0, `-O2`) measured a **stable, reproducible** leak in `scalar_multiply_ct_internal` — the Montgomery ladder, on the secret scalar — at **|t| ≈ 21** (random vs fixed scalar, ~560 ns separation, consistent across every run). ctgrind localised it to a secret-dependent conditional jump in `uint256_select`, and the disassembly confirmed the mechanism: **GCC 15.2 at `-O2` (the shipped optimisation level) recognises the branchless `(a & ~mask) | (b & mask)` select idiom, reconstructs the original boolean flag, and emits `je`/`jne`** to out-of-line copy blocks. The compiler had silently undone the branchless property the 0.17.0 |t|=875 fix relied on — a textbook "compiler defeats constant-time C" regression, invisible to source review and to the deterministic check on the *previous* toolchain.

The fix (see [security advisory GHSA-draft-ct-value-barrier](advisories/0001-compiler-reconstructed-ct-branch.md)) introduces a value barrier — `ct_value_barrier_u64()`, an empty `volatile` asm that makes a value opaque to the optimiser (the libsecp256k1/BoringSSL technique) — and routes **every** all-0s/all-1s select mask through a single `ct_mask_u64()` helper. Only `uint256_select` actively branchified under GCC 15.2/`-O2`; the field, scalar, and `cswap` masks did not, but are hardened identically as defence-in-depth against a future compiler reconstructing them.

#### Bare-metal results (post-fix)

Measured on the issue-#25 reference machine: **AMD Ryzen 9 9950X (Zen 5), microcode 0xb404023, Ubuntu 26.04 / Linux 7.0.0-14, GCC 15.2.0** — `systemd-detect-virt = none` (true bare metal), turbo/boost off, `performance` governor with min=max, SMT off, harness pinned with `taskset -c` under `chrt -f` real-time scheduling. Each figure is aggregated over **20 runs**.

| Function | mean \|t\| | max \|t\| | runs over 4.5 | Measurements/run | Result |
|---|---|---|---|---|---|
| `scalar_multiply_ct_internal` | 0.68 | 1.57 | 0 / 20 | 10,000 | **PASS** |
| `scalar_mul_internal` | 0.93 | 2.19 | 0 / 20 | 1,000,000 | PASS |
| `scalar_reduce` | 1.06 | 2.44 | 0 / 20 | 1,000,000 | PASS |
| `scalar_inv_internal` | 0.49 | 1.15 | 0 / 20 | 1,000 | PASS |
| `fadd_internal` | 0.58 | 1.44 | 0 / 20 | 1,500,000 | PASS |
| `fsub_internal` | 0.57 | 1.81 | 0 / 20 | 1,500,000 | PASS |
| `fneg_internal` | 0.72 | 2.09 | 0 / 20 | 1,500,000 | PASS |
| `fred_internal` | 2.28 | 6.11 | 2 / 20 | 1,500,000 | marginal |
| `jp_add_internal` (isolation) | 3.31 | 7.64 | 7 / 20 | 1,000,000 | marginal |

`scalar_multiply_ct_internal` — the headline secret-scalar operation — is now flat (0/20 runs over threshold, was stably |t| ≈ 21). The deterministic ctgrind check is **clean (exit 0)** across the whole extension: with every secret poisoned, nothing reaches a branch.

After the #21 fix `scalar_reduce_limbs` is fully branchless; the previous I-11 finding (secret-dependent branches on `h == 0` and `carry3` in the residual fold) is closed, corroborated above and by ctgrind reporting `0 errors` on the scalar layer.

#### Marginal field/point measurements — operand-value artefacts, not branches

`fred_internal` and `jp_add_internal` show a non-zero central |t| (means 2.3 and 3.3) with occasional single-run excursions to ~6–8. These are **operand-value microarchitectural artefacts, not data-dependent branches** — the deterministic ctgrind check confirms no secret reaches a control-flow decision in either, so they are not the GCC-reconstruction class above. Two distinct causes, both benign:

- **`jp_add_internal` (the long-documented ≈7.5 artefact):** comparing points with `Z = 1` (affine embedding) against points with non-trivial `Z` exercises field multiplications whose *operand values* differ (multiply-by-1 vs multiply-by-large), and the Zen-class multiplier's latency has a small value dependence. Within the Montgomery ladder both accumulators acquire non-trivial `Z` after the first iteration and scalar bits do not correlate with `Z`, so `scalar_multiply_ct_internal` itself stays flat.
- **`fred`/`fsub`-style field tests:** the dudect input classes are deliberately *operand-magnitude-asymmetric* (e.g. one class subtracts a tiny value from a full 256-bit one, the other swaps the roles) to stress the branchless correction path. The residual |t| reflects that synthetic magnitude asymmetry in the adder/borrow path, not a secret-dependent branch — ctgrind confirms no secret reaches a *branch*, but this is an operand-value *latency* effect ctgrind cannot observe, so its benignness with respect to the secret scalar rests instead on the flat **strict** `scalar_multiply_ct_internal` measured end-to-end on real operands (the borrow path is exercised there too, uncorrelated with scalar bits). Real field elements are always full-width residues mod *P*, so the synthetic tiny-operand class does not occur in practice; a realistic full-width-vs-full-width `fsub` test that could retire the artefact tier is tracked in [issue #78](https://github.com/sgbett/secp256k1-native/issues/78).

A non-isolated desktop (live GUI session, no `isolcpus` core reservation) also raises the noise floor — individual runs spike where an isolated core would not; the aggregate sign of these |t| values is unstable run-to-run, the signature of noise rather than a leak. These are catalogued here (and in [risks.md](risks.md#what-works-against-it)) as known measurement artefacts rather than claimed absent.

#### Randomised class assignment (issue #72)

The harness assigns each measurement to an input class **pseudorandomly** — a per-measurement draw from the harness PRNG, as Reparaz et al. specify — not by deterministic `i & 1` alternation. This matters on real hardware: a fixed A,B,A,B cadence *aliases* with periodic ~µs transients (an SMI, a brief frequency dip on the isolated core), so in phase-aligned runs the transient lands preferentially on one class and manufactures a large, single-class |t| that is pure artefact. The reproducible [reference machine](reference-machine.md) — a NixOS / GCC 15.1 build, **distinct from the Ubuntu / GCC 15.2 box whose figures appear above** — surfaced this: under `i & 1` its fastest field ops spiked to |t| = 218 (`fadd`) / 265 (`fred`) while the ~256× slower ladder, which averages transients out, stayed flat; drawing the class from the PRNG collapsed those to ~12 / ~6. Detection power is unaffected, because a genuine data-dependent leak correlates with the input **class**, not the measurement index, and so survives the change — the issue-#25 ladder leak, *before* it was fixed, read |t| ≈ 21, and a leak of that kind would still be caught under either scheme. Only the aliasing artefact is removed. What breaks the aliasing is the PRNG's aperiodicity (period ~2⁶⁴), not per-run variation, so the harness's fixed seed (reproducible inputs by design) is retained. The Ubuntu / GCC 15.2 figures above predate this change but are unaffected by it: that box did not alias (its residual |t| was already noise-floor), so its class-assignment order made no material difference.

#### Reference-machine figures (GCC 15.1) — per-toolchain calibration

The reproducible [reference machine](reference-machine.md) re-runs the same sweep on a toolchain pinned *distinct* from the issue-#25 box: **NixOS (nixpkgs `ac62194`), GCC 15.1, kernel 6.12.63** on the same AMD Ryzen 9 9950X (microcode `0xb404023`), with the C-state disable, the random-class harness ([issue #72](#randomised-class-assignment-issue-72)), and `copytoram` (USB idle) all active. N=20:

| Function | mean \|t\| | max \|t\| | runs \|t\|≥4.5 | Result |
|---|---|---|---|---|
| `scalar_multiply_ct_internal` | 0.52 | 1.38 | 0 / 20 | **PASS** (strict) |
| `scalar_mul_internal` | 0.89 | 2.70 | 0 / 20 | PASS (strict) |
| `scalar_reduce` | 0.78 | 1.95 | 0 / 20 | PASS (strict) |
| `scalar_inv_internal` | 0.21 | 0.59 | 0 / 20 | PASS (strict) |
| `fneg_internal` | 0.70 | 2.09 | 0 / 20 | PASS (lenient) |
| `fred_internal` | 2.57 | 10.31 | 3 / 20 | PASS (lenient) |
| `fadd_internal` | 3.17 | 8.64 | 6 / 20 | PASS (lenient) |
| `fsub_internal` | 8.26 | 25.85 | 9 / 20 | PASS (artefact) |
| `jp_add_internal` | 24.06 | 71.24 | 17 / 20 | PASS (artefact) |

All four **strict** (secret-scalar) operations are flat (0/20 runs at/over |t|=4.5), and each is additionally exercised under the deterministic **ctgrind** pass with its own secret input poisoned — the ladder (`scalar_multiply_ct_internal`), `scalar_mul_internal`, `scalar_reduce`, and `scalar_inv_internal` — which is **CLEAN** (nothing reaches a branch). The strict gate distinguishes a lone measurement transient from a real leak by the *fraction* of runs over threshold: a compiler-reconstructed branch is compiled in and shows in essentially every run (the #25 leak was 20/20), so a strict op reds the gate only when more than ~5% of runs are at/over 4.5 (i.e. more than one run in twenty) — a single blip is tolerated, a stable signal is not. A leak strong enough to fire on more than ~5% of runs cannot hide statistically (a compiler-reconstructed branch shows ~100% of the time, far above the tolerance). Two residuals of the 5% allowance are stated honestly rather than glossed: **(i)** a weak partial **branch** firing on too few runs to red the fraction gate is still caught deterministically by **ctgrind**, which now backstops *every* strict op individually (previously `scalar_inv_internal`, whose control flow branches only on the public exponent `N-2`, relied on that structural argument plus the statistical gate; it is now poisoned directly); **(ii)** a secret-correlated operand-**latency** effect is invisible to ctgrind, so the fraction gate is its sole backstop — a latency leak weak enough to stay under 5% of runs is not deterministically excluded. That residual sits at the measurement noise floor: a genuine data-dependent effect fires consistently (the #25 branch was 20/20; the `jp_add`/`fsub` latency artefacts run 17/20 and 9/20, never 1/20), whereas the strict ops here measure flat (0/20), not marginal. The field/point operations carry documented **operand-value microarchitectural artefacts** — **markedly larger on GCC 15.1 than the GCC 15.2 figures above** (`jp_add` ~24 vs 3.3, `fsub` ~8 vs 0.6). These are toolchain-dependent, not leaks — operand-value *latency* effects, not secret-dependent branches: ctgrind confirms no branch/addressing channel, and because ctgrind cannot observe latency, the secret-scalar benignness of the latency channel is established by the composed secret operation `scalar_multiply_ct_internal` staying flat end-to-end. The mechanisms differ (see the marginal-measurements analysis above): `jp_add`'s is the Zen **multiplier**'s operand-value latency (`Z = 1` vs non-trivial `Z`), whereas `fsub`'s arises in its magnitude-asymmetric **add/borrow** path — `fadd` and `fneg` do no multiplication at all.

Because the artefact magnitude is toolchain-specific, the gate's **lenient thresholds are calibrated per pinned toolchain** ([issue #74](https://github.com/sgbett/secp256k1-native/issues/74)), re-derived from the authoritative sweep whenever the compiler changes — an artefact floor, *not* loosen-to-green. The **mean** |t| is the stable, gated signal; the per-run **max** is noisy for these ~20 ns operations (across sweeps `jp_add` max ran 37/54/71 and `fsub` ~26, while the means held at ~16–24 and ~8–11), so its bound is only a loose gross-anomaly backstop. The bounds are **tiered** so a currently-flat op cannot regress up to the widest bound unnoticed: on GCC 15.1 the elevated artefact ops (`jp_add`, `fsub`) are bounded at `mean|t|<35`, the near-flat field ops (`fadd`, `fred`, `fneg`) at a tighter `mean|t|<15`, with a shared loose `max|t|<100` backstop. These sit above the observed artefact envelope. Crucially, the lenient bounds are **not** the primary leak detector for these operations — a #25-magnitude leak (|t| ≈ 21) would in fact slip under the 35 artefact bound. That is not a gap: `jp_add`/`fsub` are point/field building blocks, not secret-scalar operations, so a secret-correlated **branch** in them surfaces in both the **strict** `scalar_multiply_ct_internal` (gated at |t|<4.5, where the #25 ladder leak read ≈ 21 and was caught with wide margin) and the deterministic **ctgrind** pass, while a secret-correlated operand-**latency** effect — which ctgrind cannot observe — surfaces in the strict ladder alone. The ctgrind pass is built **vanilla at `-O2`** (`NIX_HARDENING_ENABLE=""`; the shipped optimisation level and hardening, since `extconf.rb` appends `-O2` and the gem ships without the nix wrapper's hardening), so it exercises **shipping-shaped** codegen — the same compiler, `-O2`, and hardening-off, hence the same vanilla-`-O2` branch reconstructions the #25 advisory documents. The dudect timing harness is built the same way, so the calibrated bounds describe a shipping-shaped binary, not a hardened variant.

Codegen *identity* for the constant-time property — as opposed to the shipping-shaped *behavioural* checks above — is established separately and deterministically: `nix/vanilla-ext.sh` disassembles the real `jacobian.c` at vanilla `-O2` and asserts the ladder and `jp_add_internal` are branchless (this is the gate's `codegen: PASS` step), and `nix/codegen-equivalence.sh` ties the nix-vanilla build to a stock-distro `gcc` of the same major (*passing on nix ⇒ passing on stock*). Three limits are stated rather than claimed away: **(i)** the gem is compiled on each user's machine by `mkmf`, inheriting that Ruby's `RbConfig` CFLAGS, so there is no single canonical shipped `.so` for these harnesses — which additionally carry `-fcommon` and stub Ruby headers — to be *byte*-identical to; the stub headers are constant-time-irrelevant because the CT-critical functions operate only on `uint256_t` limb arrays and never touch a Ruby `VALUE`. **(ii)** Those per-user CFLAGS are not measured — a genuine unverified residual, not an argument to wave away: `mkmf` CFLAGS are not only additive hardening (where *adds instructions, does not remove a reconstructed branch* would hold) but can carry optimisation, target, and LTO flags, and the #25-class reconstruction is precisely optimisation- and flag-specific. `extconf.rb` appends `-O2` — normally decisive for the optimisation *level* on the `mkmf` command line, which bounds that specific reconstruction — but arch/tuning/LTO choices a user's Ruby carries are uncontrolled and could in principle alter codegen. The reference machine certifies the pinned-toolchain vanilla `-O2` build, not every per-user flag configuration. **(iii)** The objdump invariant covers the ladder and `jp_add_internal`; `jp_double_internal` and the field ops are not objdump-asserted and rest instead on ctgrind's symbol-agnostic secret-poisoning and the strict dudect on the composed `scalar_multiply_ct_internal`. Those checks are the security gate; the lenient bounds exist only to pin the benign diagnostic-op artefact per toolchain and flag gross regressions in the near-flat ops.

#### Bare-metal dudect is a pre-tag release gate

The GCC 15 finding makes the policy explicit: **passing the deterministic CT checks (the assembly-invariant in CI, ctgrind on the reference machine) is not sufficient on its own to ship a release.** A compiler upgrade — or a change in flags, target, or even an inlining decision — can silently reconstruct a branch from branchless source, and only the statistical, bare-metal dudect pass observes the *compiled* timing. The deterministic check would have caught this one (it did), but it runs against whatever toolchain CI happens to use; the timing that ships is the timing on the user's compiler. Therefore the bare-metal dudect run in the [runbook](timing-verification-runbook.md) is a **required gate before tagging a release**, re-run whenever the pinned/known-good compiler version changes — not a one-off for issue #25.

See [Releasing](RELEASING.md) for the literal pre-tag checklist that makes this an explicit gate rather than narrative prose.

### Variable-time paths

The wNAF scalar multiplication loop (`scalar_multiply_wnaf`, exposed as `Point#mul_vt`) branches on scalar bits and uses a precomputed table with data-dependent lookups. It is explicitly variable-time. This is acceptable for public scalars (signature verification) but must never be used with secret scalars.

## Thread safety

This gem has **no thread synchronisation**. The wNAF precomputed table cache (`WNAF_TABLE_CACHE`) is a mutable Hash at the module level with no mutex protection.

**Under MRI (CRuby):** The Global VM Lock (GVL) prevents truly concurrent Ruby execution, so cache corruption is unlikely in practice. However, the GVL is released during C extension calls, so concurrent `mul` calls could theoretically race on the cache.

**Under JRuby/TruffleRuby:** No GVL. Concurrent access to the cache would be unsafe without external synchronisation.

**Recommendation:** If using this gem from multiple threads, protect calls to `Point#mul_vt` with your own mutex. `Point#mul` (constant-time, Montgomery ladder) does not use the cache and is safe to call concurrently.

## Platform and runtime support

| Runtime | C extension | Pure Ruby | Status |
|---|---|---|---|
| MRI (CRuby) 2.7+ on macOS/Linux | Yes | Yes | Tested |
| MRI on Windows (MSVC) | No (skipped) | Yes | Untested |
| JRuby | No (no `__uint128_t`) | Yes | Untested |
| TruffleRuby | No (no `__uint128_t`) | Yes | Untested |

The gem's design rationale includes JRuby/TruffleRuby portability, but these runtimes are not currently tested. The pure-Ruby fallback should work, but the thread safety caveats above apply with greater force on runtimes without a GVL.

The C extension requires a C99 compiler with `__uint128_t` support (GCC or Clang on x86_64 and arm64). `extconf.rb` checks for this at configure time and generates a no-op Makefile if unavailable.
