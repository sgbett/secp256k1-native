# Changelog

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
