# Performance

## Summary

The primary purpose of the C extension is **security, not performance**. It provides hardware-level constant-time arithmetic that Ruby's variable-width `Integer` internals cannot guarantee. The performance improvement is a welcome secondary benefit.

**Security consideration:** The pure-Ruby implementation is constant-time at the algorithm level (no secret-dependent branching) but relies on Ruby's arbitrary-precision `Integer` for the underlying arithmetic, which is variable-width and may leak timing information proportional to value magnitude. Users handling secret key material (signing, key derivation) should evaluate whether this is acceptable for their threat model. The C extension eliminates this concern by operating on fixed-width 4x64-bit limbs with branchless conditional selection throughout.

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

## Constant-time properties

The C extension provides constant-time arithmetic at the hardware level. This is distinct from the pure-Ruby implementation, which is constant-time at the algorithm level (no secret-dependent branching) but cannot guarantee constant-time at the machine level because Ruby's `Integer` uses variable-width bignum internals.

In the C extension:

- **Field reduction** (`fred`) uses branchless conditional selection via bitwise masking — the final conditional subtraction compiles to a mask-and-select, not a branch.
- **Field subtraction** (`fsub`) and **negation** (`fneg`) use the same branchless pattern.
- **Montgomery ladder** (`scalar_multiply_ct`) uses branchless `cswap` — the conditional swap of two points compiles to XOR-and-mask operations with no data-dependent branches.
- All field and scalar operations work on fixed-width `uint256_t` values, so execution time is independent of the value being operated on.

The constant-time properties are most critical for `scalar_multiply_ct`, which is used for signing and key derivation where the scalar is a secret (private key or nonce). The wNAF path (`scalar_multiply`) is variable-time by design and used only for public scalars (verification).

## Platform requirements

The C extension requires:

- C99 compiler with `__uint128_t` support (GCC or Clang)
- Supported: macOS (Apple Silicon, x86_64), Linux (x86_64, aarch64)
- Not supported: MSVC on Windows (no `__uint128_t`)

On unsupported platforms, `extconf.rb` generates a no-op Makefile. The gem installs and functions using the pure-Ruby implementation with no error. The API is identical regardless of which implementation is active — consuming code does not need to know or care.

## Reproducing these measurements

The benchmark figures were measured during initial development ([sgbett/bsv-ruby-sdk#626](https://github.com/sgbett/bsv-ruby-sdk/issues/626)) on Apple Silicon. Your results will vary by hardware, Ruby version, and workload.

```ruby
require 'benchmark'
require 'secp256k1'

g = Secp256k1::Point.generator
k = SecureRandom.random_number(Secp256k1::N - 1) + 1

n = 100
time = Benchmark.realtime { n.times { g.mul_ct(k) } }
puts "#{(n / time).round(1)} scalar_multiply_ct ops/sec"
```
