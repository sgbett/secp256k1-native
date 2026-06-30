# Changelog

## [0.18.0] - 2026-06-30

### Security

- **Compiler-reconstructed timing side-channel in `Point#mul` (the secret-scalar Montgomery ladder).** Bare-metal dudect verification (issue #25; AMD Ryzen 9 9950X, GCC 15.2, `-O2`) found that GCC 15.2 reconstructs the branchless `(a & ~mask) | (b & mask)` select idiom in `uint256_select` into a secret-dependent conditional jump, leaking the scalar at dudect |t| ≈ 21. This silently undid the 0.17.0 |t|=875 fix, which relied on that select being branchless. Fixed with a value barrier (`ct_value_barrier_u64`) applied via a single `ct_mask_u64` helper to **every** constant-time select mask in the extension (`uint256_select`, `fred`/`fadd`/`fsub`/`fneg`, `scalar_reduce`/`scalar_add`, the `jp_double` infinity select, and the ladder `cswap`). Re-verified: disassembly shows no branch/`cmov` at any select line, ctgrind clean, dudect `scalar_multiply_ct` |t| → 0.68 mean (0/20 runs over 4.5). See [advisory 0001](docs/advisories/0001-compiler-reconstructed-ct-branch.md). Only `uint256_select` actively branchified under this compiler; the other sites are hardened as defence-in-depth.

### Changed

- Bare-metal dudect timing verification is now a **required pre-tag release gate** (not a one-off): a constant-time *source* is not a constant-time *binary*, and a compiler upgrade can silently reintroduce a branch that only a statistical run on the shipping compiler observes. Documented in [`docs/security.md`](docs/security.md#empirical-timing-verification) and [`docs/timing-verification-runbook.md`](docs/timing-verification-runbook.md).

### Build

- Timing harness (`timing/`) now builds on modern GCC/glibc toolchains: define `_POSIX_C_SOURCE` for `clock_gettime` under `-std=c99`, and add `-fcommon` for the `rb_mSecp256k1Native` tentative definition under GCC 10+ `-fno-common`.

## [0.17.0] - 2026-05-01

### Added

- Dudect-based constant-time verification harness (`rake timing:verify`) — empirical timing leakage detection using Welch's t-test for all constant-time C extension functions
- Cryptographic development principles codified in CLAUDE.md — seven principles governing all development decisions
- Property-based testing suite (field arithmetic, scalar arithmetic, point operations, cross-implementation parity)
- GitHub Actions CI workflow for Ruby 2.7–3.4 matrix
- Security findings disclosure process

### Fixed

- **Timing side-channel in `scalar_multiply_ct`** — `jp_add_internal` had early-return branches on infinity checks that leaked timing information about the secret scalar inside the Montgomery ladder (dudect t = -875). Made `jp_add_internal` fully branchless with mask-based conditional selection. Verified fix via dudect (t = 1.0)

### Changed

- Field arithmetic (`fred`, `fsub`, `fneg`, `fadd`) constant-time properties now empirically verified via dudect, not just code inspection

## [0.16.0] - 2026-04-29

### Breaking Changes

- `Point#mul` is now constant-time (Montgomery ladder) by default, matching OpenSSL behaviour. The previous variable-time wNAF implementation is available as `Point#mul_vt`
- `Point#mul` raises `InsecureOperationError` without the native C extension unless explicitly allowed via `SECP256K1_ALLOW_PURE_RUBY_CT=1` or `Secp256k1.allow_pure_ruby_ct!`

### Added

- `Point#mul_vt` for explicit variable-time scalar multiplication (public scalars only)
- `Secp256k1.native?` to check whether the C extension is loaded
- `Secp256k1.allow_pure_ruby_ct!` and `SECP256K1_ALLOW_PURE_RUBY_CT` env var for opting in to pure-Ruby constant-time operations
- Evidence-based risk assessment documentation (`docs/risks.md`)
- MkDocs site with GitHub Pages automation
- YARD-generated API reference

### Changed

- `Point#mul_ct` is now a deprecated alias for `Point#mul`
- Licence changed from Open BSV License to MIT
- Documentation reorganised into focused documents (architecture, security, performance, design rationale)

## [0.15.0] - 2026-04-27

### Added

- Pure-Ruby secp256k1 field, scalar, and point arithmetic
- Native C extension for accelerated operations (~22× speedup)
- Montgomery ladder with constant-time branchless cswap
- wNAF scalar multiplication
- Comprehensive test suite (303 examples):
  - Wycheproof ECDSA vectors
  - Field, scalar, and Jacobian compliance vectors
  - Pure-Ruby vs native cross-validation
