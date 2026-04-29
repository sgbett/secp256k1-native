# Changelog

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
