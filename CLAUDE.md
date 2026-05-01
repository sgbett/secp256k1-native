# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

secp256k1-native is a self-contained Ruby gem implementing secp256k1 elliptic curve cryptography. It has a pure-Ruby implementation with an optional C extension that provides hardware-level constant-time guarantees and ~22x speedup on hot paths. The C extension's primary purpose is security (constant-time field arithmetic on fixed-width limbs); performance is secondary. No external dependencies (no libsecp256k1).

## Cryptographic Development Principles

This is a cryptographic library. These principles govern all development decisions — they are not aspirational but describe how this project operates. When a trade-off arises, these principles resolve the ambiguity.

### 1. Fail closed, not open

Operations that cannot guarantee their security properties must raise, not silently degrade. A user who unknowingly runs secret-scalar multiplication without constant-time guarantees has a worse outcome than a user who gets an exception.

*In this codebase:* `Point#mul` raises `InsecureOperationError` when the C extension is not loaded. Pure-Ruby fallback requires explicit opt-in via `SECP256K1_ALLOW_PURE_RUBY_CT=1` or `Secp256k1.allow_pure_ruby_ct!`.

### 2. Empirical over inspected

Security claims must be empirically verified where tooling exists. Code inspection is necessary but insufficient — the evidence shows that subtle bugs (carry-propagation errors, canonicalisation failures) persist in expert-reviewed code for years (Steinbach, Grossschadl & Ronne, 2025; Mouha & Celi, 2023).

*In this codebase:* Wycheproof test vectors validate functional correctness (474 ECDSA cases). All constant-time claims are empirically verified via a dudect-based timing harness: field arithmetic (`fred`, `fsub`, `fneg`, `fadd`) and scalar multiplication (`scalar_multiply_ct`) pass Welch's t-test (|t| < 4.5). An earlier timing leakage in the Montgomery ladder (|t| = 875, caused by branching infinity checks in `jp_add`) was found by dudect, fixed with a branchless implementation, and re-verified — a concrete demonstration of this principle.

### 3. Minimal attack surface

Complexity is vulnerability surface. Keep the API small, the scope narrow, and remove what isn't needed. The correlation between code complexity and vulnerability rate is empirically supported (Blessing, Specter & Weitzner, 2024). Resist feature accretion — higher-level constructions belong in consuming libraries.

*In this codebase:* Primitives only — no ECDSA, no Schnorr, no key derivation, no hashing. Two scalar multiplication strategies, not five. Approximately 1,200 lines of C implementing fixed-width arithmetic with no dynamic memory allocation.

### 4. Safe by default

The default API path must be the secure path. Unsafe operations require explicit, documented opt-in. Users who don't read the documentation should fall into the safe path, not the fast path.

*In this codebase:* `Point#mul` (constant-time Montgomery ladder) is the default. `Point#mul_vt` (variable-time wNAF) exists for public-scalar workloads but must be chosen deliberately.

### 5. Rigorous over convenient

When trade-offs exist between implementation rigour and developer or performance convenience, choose rigour. The inline C harness over the Ruby-driven approach. The branchless implementation over the branching one. The slower but verified path over the faster but unverified one. Always.

*In this codebase:* The C extension exists for security (constant-time guarantees), not performance. The ~22x speedup is a consequence of fixed-width arithmetic, not the motivation.

### 6. Document what you don't know

Honest assessment of limitations over false assurance. Unverified claims are labelled as such. The absence of evidence is not evidence of absence — if a security property hasn't been empirically verified, say so.

*In this codebase:* [risks.md](docs/risks.md) explicitly catalogues what works in the gem's favour and what works against it, grounded in peer-reviewed evidence. Constant-time claims are empirically verified via dudect. The `jp_add_internal` isolation test shows a marginal |t| of 7.5 from microarchitectural timing variation in field multiplication operand values (Z=1 vs non-trivial Z), not from any branch — this is documented as a known measurement artefact rather than claimed to be absent.

### 7. Self-verifying

The library should verify its own correctness — through test vectors, compliance suites, and empirical measurement. Don't trust the build; verify the output.

*In this codebase:* Wycheproof ECDSA vectors (474 cases), field arithmetic law verification, scalar arithmetic compliance, and known generator multiple checks. Empirical timing verification via a dudect-based harness (`rake timing:verify`) validates constant-time properties of the C extension.

### Security findings

When testing or development reveals a security issue (side-channel leakage, arithmetic bug, validation failure):

1. **Triage** — classify severity and exploitability. A timing side-channel is different from a key-leaking bug.
2. **Fix first** — develop the fix before public disclosure where possible (GitHub security advisories support private forks).
3. **Disclose proportionally** — pre-1.0 with no known users: fix, document, note in changelog. Published gem with dependents: GitHub security advisory + CVE + coordinated disclosure timeline.
4. **Always document** — regardless of whether a CVE is filed, the finding and fix go into [risks.md](docs/risks.md) and the changelog.

## Build & Test Commands

```bash
bundle install                        # Install dependencies
bundle exec rake compile              # Compile C extension
bundle exec rspec                     # Run full test suite (368 examples)
bundle exec rspec spec/secp256k1_spec.rb           # Pure-Ruby tests only
bundle exec rspec spec/secp256k1_native_spec.rb    # C extension tests only
bundle exec rspec spec/secp256k1_compliance_spec.rb # Wycheproof compliance
bundle exec rspec spec/secp256k1_spec.rb:42        # Single test by line number
bundle exec rubocop                   # Lint (excludes ext/ directory)
bundle exec rake clobber              # Clean all build artifacts
bundle exec rake timing:verify        # dudect constant-time verification (not in default task — slow)
```

Default rake task runs `compile` then `spec`.

## Architecture

### Dual-implementation pattern

The core design: all curve operations are implemented in pure Ruby (`lib/secp256k1.rb`), then selectively replaced by C equivalents at load time.

`Secp256k1` module (public API) defines all methods in Ruby. When `require 'secp256k1_native'` succeeds, 16 hot-path methods are replaced via `singleton_class.define_method` with C implementations from the `Secp256k1Native` module. If the extension fails to load, pure Ruby runs for public-scalar operations. `mul_ct` raises `InsecureOperationError` unless explicitly allowed via `SECP256K1_ALLOW_PURE_RUBY_CT=1` or `Secp256k1.allow_pure_ruby_ct!`.

**Replaced methods:** `fmul`, `fsqr`, `fadd`, `fsub`, `fneg`, `finv`, `fsqrt`, `fred`, `scalar_mod`, `scalar_mul`, `scalar_inv`, `scalar_add`, `jp_double`, `jp_add`, `jp_neg`, `scalar_multiply_ct`.

### C extension (`ext/secp256k1_native/`)

- Requires C99 compiler with `__uint128_t` support (GCC/Clang on x86_64/arm64)
- On unsupported platforms (MSVC/Windows): generates no-op Makefile, gem still installs
- Internal representation: `uint256_t` struct of 4 x `uint64_t` limbs (little-endian)
- Marshals Ruby Integers via `rb_integer_pack`/`rb_integer_unpack`
- Compiled output: `lib/secp256k1_native.bundle` (macOS) or `lib/secp256k1_native.so` (Linux)

### Scalar multiplication strategies

Two strategies, with the safe one as default:
- **`Point#mul`** (default): Montgomery ladder. Constant-time, fixed 256 iterations, branchless `cswap` in C. Safe for all scalars. `mul_ct` is a deprecated alias.
- **`Point#mul_vt`**: wNAF with window size 5, LRU cache (512 entries). Variable-time — for public scalars only (verification).

### Constant-time discipline

Field ops (`fred`, `fsub`, `fneg`) use branchless conditional selection. Montgomery ladder uses branchless `cswap` via bitwise masking. Inversion/sqrt iterate over public constants so are safe.

### Key types

- Jacobian points: `[X, Y, Z]` integer arrays. Infinity = `[0, 1, 0]`.
- `Secp256k1::Point`: Affine point class with SEC1 compressed/uncompressed encoding.

## Code Conventions

- Rubocop enforced: single quotes, frozen string literal, target Ruby 2.7
- Mathematical single-letter params (`k`, `p`, `x`, `y`) matching curve notation
- C extension files use `secp256k1_native.h` for shared macros and type definitions
- Each C file registers its own methods via `Init_*` helpers called from `secp256k1_native.c`

## Test Vectors

Wycheproof ECDSA vectors in `spec/vectors/wycheproof_ecdsa_secp256k1.json` (474 test cases). The compliance spec validates field arithmetic laws, scalar arithmetic, point operations, and known generator multiples.
