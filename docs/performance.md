# Performance

## Summary

The primary purpose of the C extension is **security, not performance**. It provides hardware-level constant-time arithmetic that Ruby's variable-width `Integer` internals cannot guarantee. The performance improvement is a welcome secondary benefit.

See [security](security.md) for constant-time properties and safe API usage guidance.

The C extension provides approximately **23x speedup for signing** and **19x speedup for verification** compared to the pure-Ruby implementation. All measurements on Apple Silicon (M-series).

| Mode | Sign (ops/sec) | Verify (ops/sec) |
|------|---------------|-----------------|
| Pure Ruby | 100 | 97 |
| C extension (field + point ops) | 2,302 | 1,826 |

For context, libsecp256k1 (bitcoin-core's optimised C with hand-tuned assembly) achieves 58,800 sign and 41,500 verify ops/sec on the same hardware. It is not a dependency and never will be — this figure is included only to calibrate expectations against the theoretical ceiling for fully optimised C.

## What the C extension accelerates

The C extension replaces 16 methods across three layers:

| Layer | Methods | Purpose |
|-------|---------|---------|
| Field arithmetic (mod p) | `fmul`, `fsqr`, `fadd`, `fsub`, `fneg`, `finv`, `fsqrt`, `fred` | 256-bit modular arithmetic over the secp256k1 field prime |
| Scalar arithmetic (mod n) | `scalar_mod`, `scalar_mul`, `scalar_inv`, `scalar_add` | Arithmetic modulo the curve order |
| Jacobian point ops | `jp_double`, `jp_add`, `jp_neg` | Elliptic curve point arithmetic in projective coordinates |
| Scalar multiplication | `scalar_multiply_ct` | Montgomery ladder with branchless cswap |

Everything above these layers — wNAF scalar multiplication, ECDSA, Schnorr, key derivation, point serialisation — remains in Ruby, calling down into C for the hot-path arithmetic.

## Why the speedup is ~22x and not more

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
| **Field + point ops in C** | **~2,300** | **~320** | Each `jp_double`/`jp_add` call does ~14 field ops internally in C |
| Full C (incl. wNAF/Montgomery) | ~8,000–10,000 | ~1 | All control flow in C |

Moving from field-only to field + point ops roughly doubles throughput for ~150 additional lines of C. This is because each `jp_double` call that crosses the Ruby-C boundary once instead of 14 times eliminates ~13 dispatches worth of overhead.

Moving the scalar multiplication loops themselves into C (the "full C" approach) would yield another ~4x, but keeps the wNAF and Montgomery ladder control flow in C where it is harder to audit and reason about. The current boundary is a deliberate trade-off: the scalar multiplication strategy (wNAF for public scalars, Montgomery ladder for secret scalars) is expressed in readable Ruby, calling down to C only for the arithmetic it orchestrates.

### The remaining gap to libsecp256k1

libsecp256k1 is approximately 25x faster than this implementation's C extension. The gap is attributable to:

- **Hand-tuned assembly** for field multiplication on specific architectures
- **Full C control flow** — no Ruby-C boundary crossings in the hot path
- **Specialised field representation** (5x52-bit limbs on 64-bit platforms) optimised for each target architecture
- **Endomorphism-based decomposition** of scalar multiplication (GLV method) which reduces the number of point operations by ~40%
- **Batch inversion** and other algorithmic optimisations accumulated over years of development

This gem intentionally does not pursue these optimisations. The goal is a self-contained, auditable implementation with no external dependencies — not to compete with a decade of dedicated C/assembly engineering.

## Reproducing these measurements

The benchmark figures were measured during initial development ([sgbett/bsv-ruby-sdk#626](https://github.com/sgbett/bsv-ruby-sdk/issues/626)) on Apple Silicon. Your results will vary by hardware, Ruby version, and workload.

```ruby
require 'benchmark'
require 'secp256k1'

g = Secp256k1::Point.generator
k = SecureRandom.random_number(Secp256k1::N - 1) + 1

n = 100
time = Benchmark.realtime { n.times { g.mul(k) } }
puts "#{(n / time).round(1)} mul ops/sec (constant-time)"
```
