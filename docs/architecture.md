# Architecture

Internal implementation details for contributors and auditors. For installation and usage, see the [home page](index.md).

## Dual-implementation pattern

All curve operations are implemented twice: once in pure Ruby (`lib/secp256k1.rb`), once in C (`ext/secp256k1_native/`). The Ruby implementation is the canonical source — readable, auditable, and portable. The C extension is an optional accelerator that replaces hot-path methods at load time.

When `require 'secp256k1_native'` succeeds, 16 methods are replaced on the module's singleton class:

```ruby
%i[fmul fsqr fadd fsub fneg finv fsqrt fred
   scalar_mod scalar_mul scalar_inv scalar_add
   jp_double jp_add jp_neg scalar_multiply_ct].each do |m|
  singleton_class.define_method(m, Secp256k1Native.method(m).to_proc)
end
```

`method(m).to_proc` converts each C singleton method from `Secp256k1Native` to a Proc, stripping the receiver binding so it can be attached to `Secp256k1`. The replacement targets the singleton class directly — `module_function` is not called again, which would re-copy the private Ruby instance method back over the new definition.

If the extension fails to load (`rescue LoadError`), the pure-Ruby implementations run silently with no configuration required.

## Internal representation (C extension)

The extension uses a `uint256_t` type: a struct of 4 x `uint64_t` limbs in little-endian order (`d[0]` is the least-significant 64-bit word). Values are marshalled between Ruby `Integer` and this struct via `rb_integer_pack` / `rb_integer_unpack`.

Field arithmetic uses a two-fold fast-reduction technique exploiting P = 2^256 - c where c = `0x1000003D1`. This avoids expensive generic modular reduction.

Jacobian point operations call field primitives directly in C without crossing the Ruby/C boundary per intermediate step: `jp_double` executes approximately 14 field operations and `jp_add` approximately 18, all in C. This eliminates the overhead of Ruby method dispatch on each intermediate field operation.

## Scalar multiplication strategies

Two strategies, chosen by security context (see [security](security.md) for safe usage guidance):

**wNAF (windowed Non-Adjacent Form)** — variable-time, for public scalars. Window size 5, with a precomputed table cache. Used by `Point#mul`. Suitable for signature verification and other operations where the scalar is not secret.

**Montgomery ladder** — constant-time, for secret scalars. Fixed 256 iterations with branchless conditional swap (`cswap`). Used by `Point#mul_ct`. Suitable for signing, key generation, and ECDH shared-secret derivation.

## wNAF precomputed table cache

`WNAF_TABLE_CACHE` is a plain Hash storing precomputed wNAF tables keyed by `"window:x:y"` strings. Maximum 512 entries, evicted FIFO (oldest entry deleted when full).

Each table for window size 5 contains 16 Jacobian points (3 coordinates each). With 512 entries, worst-case memory is approximately 128 KB.

The cache has no synchronisation. See [security.md](security.md) for thread safety implications.

## Scope

| Concern | Implementation |
|---|---|
| Field arithmetic (mod P) | C extension (with pure-Ruby fallback) |
| Scalar arithmetic (mod N) | C extension (with pure-Ruby fallback) |
| Jacobian point operations | C extension (with pure-Ruby fallback) |
| Montgomery ladder (constant-time) | C extension (branchless cswap) |
| Scalar multiplication (wNAF) | Ruby, calling native primitives |
| ECDSA, Schnorr, BIP-32/39 | Not included — provided by consuming SDKs |
| SHA-256, RIPEMD-160, HMAC, AES | Not included — delegated to OpenSSL in consuming code |

This gem provides elliptic curve primitives only — see [design rationale](design.md#primitives-not-protocols) for why this boundary exists.

## File structure

```
lib/
  secp256k1.rb                  # Pure-Ruby module + native extension loader
  secp256k1/
    version.rb
ext/
  secp256k1_native/
    extconf.rb                  # Build configuration (__uint128_t detection)
    secp256k1_native.c          # Extension entry point, Init_ registration
    secp256k1_native.h          # Shared macros and uint256_t type definition
    field.c                     # Field arithmetic (mod P)
    scalar.c                    # Scalar arithmetic (mod N)
    jacobian.c                  # Jacobian point ops + Montgomery ladder (cswap)
spec/
  secp256k1_spec.rb             # Pure-Ruby unit tests
  secp256k1_native_spec.rb      # Native extension tests
  secp256k1_compliance_spec.rb  # Wycheproof / compliance vectors
  vectors/                      # Test vector files (Wycheproof ECDSA, 474 cases)
```
