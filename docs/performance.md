---
title: Performance
nav_order: 6
---

# Performance

## Summary

The primary purpose of the C extension is **security, not performance**. It provides hardware-level constant-time arithmetic that Ruby's variable-width `Integer` internals cannot guarantee. The performance improvement is a welcome secondary benefit.

See [security](security.md) for constant-time properties and safe API usage guidance.

The C extension provides approximately **37x speedup for constant-time multiplication** (signing) and **17x speedup for variable-time multiplication** (verification) compared to the pure-Ruby implementation. All measurements on Apple Silicon (M4), Ruby 3.4, median of 5 trials.

| Mode | Constant-time mul (ops/sec) | Variable-time mul (ops/sec) |
|------|----------------------------|----------------------------|
| Pure Ruby | 105 | 209 |
| C extension (field + point ops) | 3,934 | 3,621 |

For context, libsecp256k1 (bitcoin-core's optimised C with hand-tuned assembly) achieves approximately 58,800 sign and 41,500 verify ops/sec. It is not a dependency and never will be — this figure is included only to calibrate expectations against the theoretical ceiling for fully optimised C.

## What the C extension accelerates

The C extension replaces 16 methods across three layers:

| Layer | Methods | Purpose |
|-------|---------|---------|
| Field arithmetic (mod p) | `fmul`, `fsqr`, `fadd`, `fsub`, `fneg`, `finv`, `fsqrt`, `fred` | 256-bit modular arithmetic over the secp256k1 field prime |
| Scalar arithmetic (mod n) | `scalar_mod`, `scalar_mul`, `scalar_inv`, `scalar_add` | Arithmetic modulo the curve order |
| Jacobian point ops | `jp_double`, `jp_add`, `jp_neg` | Elliptic curve point arithmetic in projective coordinates |
| Scalar multiplication | `scalar_multiply_ct` | Montgomery ladder with branchless cswap |

Everything above these layers — wNAF scalar multiplication, ECDSA, Schnorr, key derivation, point serialisation — remains in Ruby, calling down into C for the hot-path arithmetic.

## Why the speedup is ~37x and not more

### Where the time goes

A single scalar multiplication (the dominant cost in signing and verification) performs approximately 256 iterations of the Montgomery ladder. Each iteration calls `jp_double` and `jp_add`, and each of those calls approximately 14 field operations (`fmul`, `fsqr`, `fadd`, `fsub`). That is roughly 7,000 field operations per scalar multiplication.

In pure Ruby, each of those 7,000 operations involves:
- Ruby `Integer` arbitrary-precision arithmetic (variable-width, heap-allocated)
- Object allocation and garbage collection pressure
- Method dispatch overhead

The C extension eliminates all of this by representing 256-bit values as a fixed `uint256_t` struct of 4 x `uint64_t` limbs, using `__uint128_t` for intermediate products. No heap allocation, no GC, no variable-width overhead.

### The Ruby-C boundary

A critical design decision is _where_ the C boundary sits. Three options were evaluated:

| Approach | Est. ops/sec | Ruby-C calls per scalar mul | Notes |
|----------|-------------|----------------------------|-------|
| Field ops only in C | ~1,500–2,000 | ~4,500 | Dispatch overhead (~675us) dominates arithmetic (~90us) |
| **Field + point ops in C** | **~3,900** | **~320** | Each `jp_double`/`jp_add` call does ~14 field ops internally in C |
| Full C (incl. wNAF/Montgomery) | ~8,000–10,000 | ~1 | All control flow in C |

Moving from field-only to field + point ops roughly doubles throughput for ~150 additional lines of C. This is because each `jp_double` call that crosses the Ruby-C boundary once instead of 14 times eliminates ~13 dispatches worth of overhead.

Moving the scalar multiplication loops themselves into C (the "full C" approach) would yield another ~4x, but keeps the wNAF and Montgomery ladder control flow in C where it is harder to audit and reason about. The current boundary is a deliberate trade-off: the scalar multiplication strategy (wNAF for public scalars, Montgomery ladder for secret scalars) is expressed in readable Ruby, calling down to C only for the arithmetic it orchestrates.

### The remaining gap to libsecp256k1

libsecp256k1 is approximately 15x faster than this implementation's C extension. The gap is attributable to:

- **Hand-tuned assembly** for field multiplication on specific architectures
- **Full C control flow** — no Ruby-C boundary crossings in the hot path
- **Specialised field representation** (5x52-bit limbs on 64-bit platforms) optimised for each target architecture
- **Endomorphism-based decomposition** of scalar multiplication (GLV method) which reduces the number of point operations by ~40%
- **Batch inversion** and other algorithmic optimisations accumulated over years of development

This gem intentionally does not pursue these optimisations. The goal is a self-contained, auditable implementation with no external dependencies — not to compete with a decade of dedicated C/assembly engineering.

## Reproducing these measurements

The benchmark figures in the summary table above were produced by the checked-in `bench:scalar` rake task, on Apple Silicon (M4) with Ruby 3.4, median of 5 trials with warm-up. Your results will vary by hardware, Ruby version, and workload.

```
$ bundle exec rake bench:scalar
# bench:scalar (point_iters=100, scalar_iters=10000, trials=5)
Point#mul (constant-time): 3934.0 ops/s
Point#mul_vt (variable-time): 3621.0 ops/s
Secp256k1Native.scalar_mul: ... ops/s
Secp256k1Native.scalar_inv: ... ops/s
```

The `Point#mul` and `Point#mul_vt` rates correspond to the "Constant-time mul" and "Variable-time mul" columns in the summary table. The two scalar-layer rows are additional coverage of the raw C boundary.

Tune iteration counts with `BENCH_ITERS` (default `100` for point ops; scalar ops run at `100 × BENCH_ITERS` internally because they complete in ~1 μs each):

```
$ BENCH_ITERS=1000 bundle exec rake bench:scalar   # tighter estimates
```
