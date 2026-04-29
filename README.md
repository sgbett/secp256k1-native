# secp256k1-native

> **Before using a custom cryptographic implementation, read the [Introduction](https://sgbett.github.io/secp256k1-native/introduction/) — it examines what the empirical evidence says about rolling your own crypto and where this gem sits in that landscape.**

Pure native C secp256k1 implementation for Ruby (no libsecp256k1 dependency).

Provides secp256k1 elliptic curve cryptography for Ruby — field arithmetic, scalar operations, Jacobian point arithmetic, and constant-time scalar multiplication — via an optional native C extension. The gem ships a pure-Ruby base layer that works out of the box on any Ruby 2.7+ platform, with the C extension as an optional accelerator (~22× speedup) that is silently skipped when unavailable.

Used by the [bsv-ruby-sdk](https://github.com/sgbett/bsv-ruby-sdk) and suitable for any Ruby project requiring secp256k1 operations.

## Installation

Add to your Gemfile:

```ruby
gem 'secp256k1-native'
```

Or install directly:

```bash
gem install secp256k1-native
```

The gem installs and works without the native extension. To build the extension for maximum performance:

```bash
gem install secp256k1-native -- --with-extension
# or from source:
bundle exec rake compile
```

## Usage

```ruby
require 'secp256k1'

# Generator point
g = Secp256k1::Point.generator

# Scalar multiplication (variable-time, for public scalars)
scalar = 0xdeadbeef
point = g.mul(scalar)
puts point.x.to_s(16)

# Constant-time scalar multiplication (for secret scalars)
secret = 0xcafebabe
pubkey = g.mul_ct(secret)

# SEC1 encoding / decoding
compressed = pubkey.to_octet_string(:compressed)    # 33 bytes
uncompressed = pubkey.to_octet_string(:uncompressed) # 65 bytes
decoded = Secp256k1::Point.from_bytes(compressed)

# Field arithmetic
a = Secp256k1::P - 1
b = Secp256k1.fmul(a, a)      # modular multiplication
c = Secp256k1.fadd(a, b)      # modular addition
d = Secp256k1.finv(a)         # modular inverse (Fermat)

# Scalar arithmetic (mod N)
k = Secp256k1.scalar_inv(42)  # scalar inverse
```

## Architecture

```
secp256k1-native
├── lib/secp256k1.rb           # Pure-Ruby module: field, scalar, point ops, wNAF, Montgomery ladder
├── lib/secp256k1/version.rb
└── ext/secp256k1_native/      # Optional C extension: accelerates field, scalar, Jacobian ops
```

### Pure-Ruby base layer

`Secp256k1` is a pure Ruby module providing:

- **Field arithmetic** over the secp256k1 prime (modular multiplication, squaring, inversion, square root)
- **Scalar arithmetic** modulo the curve order N
- **Jacobian point operations** (addition, doubling, negation) using projective coordinates for performance
- **Windowed-NAF scalar multiplication** (window size 5) with precomputed table caching — variable-time, suitable for public scalars
- **Montgomery ladder scalar multiplication** — constant-time at the algorithm level, suitable for secret scalars
- **SEC 1 encoding** — compressed (33-byte) and uncompressed (65-byte) point serialisation

### Native C extension (optional)

`Secp256k1Native` is an optional C extension that replaces hot-path field, scalar, and Jacobian point operations with fixed-width C implementations. When compiled, `secp256k1.rb` automatically delegates to the extension at load time.

The extension accelerates:

- All field arithmetic (`fmul`, `fsqr`, `fadd`, `fsub`, `fneg`, `finv`, `fsqrt`, `fred`)
- All scalar arithmetic (`scalar_mul`, `scalar_add`, `scalar_inv`, `scalar_mod`)
- Jacobian point operations (`jp_double`, `jp_add`, `jp_neg`)
- Montgomery ladder (`scalar_multiply_ct`) — fully branchless cswap in C

The wNAF loop and ECDSA/Schnorr logic remain in Ruby, calling native primitives per step.

### Performance

| Mode | Sign (ops/sec) | Verify (ops/sec) |
|------|---------------|-----------------|
| Pure Ruby | 100 | 97 |
| C extension | 2,302 | 1,826 |

The C extension provides ~23× speedup for signing and ~19× for verification — but performance is secondary to security. The primary purpose of the C extension is to provide **hardware-level constant-time guarantees** that Ruby's variable-width `Integer` internals cannot offer. Users handling secret key material should evaluate whether the pure-Ruby implementation is appropriate for their threat model. See [docs/performance.md](docs/performance.md) for detailed analysis.

## Building the native extension

Requirements:

- C99 compiler with `__uint128_t` support (GCC or Clang on macOS and Linux)
- Ruby development headers (included with RVM builds)
- **Not supported** on MSVC (Windows) — falls back to pure Ruby automatically

```bash
bundle exec rake compile
```

The compiled bundle is placed at `lib/secp256k1_native.bundle` (macOS) or `lib/secp256k1_native.so` (Linux).

`extconf.rb` checks for `__uint128_t` availability at configure time. If the type is absent, a no-op Makefile is generated and the extension is silently skipped. At runtime, `secp256k1.rb` wraps the `require` in a `rescue LoadError` — if the bundle is absent, the pure-Ruby implementation is used without any error.

## Running tests

```bash
bundle exec rspec
```

The test suite has 303 examples covering:

- Wycheproof ECDSA compliance vectors
- Field, scalar, and Jacobian compliance vectors
- Pure-Ruby vs native cross-validation (ensures both implementations agree on every operation)

## Ruby version compatibility

Ruby 2.7 and above. No Ruby 3.0+ features are used.

## Licence

MIT License. See [LICENSE](LICENSE).
