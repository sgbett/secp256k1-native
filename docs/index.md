# secp256k1-native

Pure native C secp256k1 implementation for Ruby (no libsecp256k1 dependency).

Provides secp256k1 elliptic curve primitives — field arithmetic, scalar operations, Jacobian point arithmetic, and constant-time scalar multiplication — via an optional native C extension. The gem ships a pure-Ruby base layer that works out of the box on any Ruby 2.7+ platform, with the C extension providing constant-time guarantees and ~22x acceleration when available.

!!! warning "Custom cryptographic implementation"
    This gem implements secp256k1 from scratch rather than wrapping an established library.
    Before using it, read [Evaluating the risks](risks.md) — it examines what the empirical
    evidence says about rolling your own crypto and where this gem sits in that landscape.

## Quick start

Add to your Gemfile:

```ruby
gem 'secp256k1-native'
```

```ruby
require 'secp256k1'

# Generator point
g = Secp256k1::Point.generator

# Scalar multiplication (constant-time by default — safe for all scalars)
pubkey = g.mul(secret_key)

# Variable-time scalar multiplication (faster, for public scalars only)
point = g.mul_vt(0xdeadbeef)

# SEC1 encoding / decoding
compressed = pubkey.to_octet_string(:compressed)
decoded = Secp256k1::Point.from_bytes(compressed)
```

## Documentation

- [Evaluating the risks](risks.md) — the "don't roll your own crypto" question, examined empirically
- [Architecture](architecture.md) — internal implementation details for contributors
- [Security](security.md) — constant-time properties, API safety guide, thread safety
- [Performance](performance.md) — benchmarks and the security case for native acceleration
- [Design rationale](design.md) — why pure Ruby, why not FFI
- [API Reference](reference/index.md) — auto-generated from source

## Licence

MIT License. See [LICENSE](https://github.com/sgbett/secp256k1-native/blob/master/LICENSE).
