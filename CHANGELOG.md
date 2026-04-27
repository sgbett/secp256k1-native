# Changelog

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
