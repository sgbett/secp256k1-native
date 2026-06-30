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

The C extension's constant-time claims are empirically tested using a dudect-based timing harness (`rake timing:verify`). The approach follows Reparaz, Balasch, and Verbauwhede (2017): for each function under test, two classes of input are constructed that exercise different sides of a branchless conditional. Timing measurements are collected for both classes, and Welch's t-test determines whether the distributions are distinguishable. A |t| value below 4.5 indicates no detectable timing leakage.

**Field arithmetic — verified constant-time:**

| Function | |t| range | Measurements | Result |
|---|---|---|---|
| `fred_internal` | 0.5–4.0 | 1,500,000 | PASS |
| `fsub_internal` | 0.1–1.0 | 1,500,000 | PASS |
| `fneg_internal` | 0.1–1.3 | 1,500,000 | PASS |
| `fadd_internal` | 0.1–3.4 | 1,500,000 | PASS |

**Scalar arithmetic — verified constant-time (#21):**

| Function | |t| | Measurements | Result |
|---|---|---|---|
| `scalar_mul_internal` | 1.0 | 1,000,000 | PASS |
| `scalar_reduce` | 0.7 | 1,000,000 | PASS |
| `scalar_inv_internal` | 0.2 | 1,000 | PASS |

After the #21 fix, `scalar_reduce_limbs` is fully branchless. The previous I-11 finding (secret-dependent branches on `h == 0` and `carry3` in the residual fold) is closed; ctgrind reports `0 errors` on the scalar layer. The dudect tests above empirically corroborate this on the dev hardware used to verify the fix.

**Point operations — verified constant-time:**

| Function | |t| | Measurements | Result |
|---|---|---|---|
| `scalar_multiply_ct_internal` | 1.0 | 10,000 | PASS |
| `jp_add_internal` (isolation) | 7.5 | 1,000,000 | marginal |

`scalar_multiply_ct_internal` passes dudect verification, confirming that the full Montgomery ladder — including `cswap`, `jp_add_internal`, and `jp_double_internal` — executes in constant time with respect to the scalar value. An earlier version failed dramatically (|t| = 875) due to early-return branches in `jp_add_internal` on infinity checks. The fix replaced all input-dependent branches with mask-based `uint256_select`, making `jp_add_internal` fully branchless.

The `jp_add_internal` isolation test shows a marginal |t| of 7.5 when comparing points with Z=1 (affine embedding) against points with non-trivial Z coordinates. This reflects microarchitectural timing variation in field multiplication operands (multiplying by 1 vs a large value), not any branch in the function itself. Within the Montgomery ladder, both accumulators acquire non-trivial Z coordinates after the first iteration, and scalar bits do not correlate with Z values — hence `scalar_multiply_ct_internal` passes cleanly.

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
