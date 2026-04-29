# Security

Safe usage guide, constant-time properties, and threat model for this gem.

## API safety guide

The `Point` class exposes two scalar multiplication methods. Choosing the wrong one leaks secret key material via timing side channels.

| Method | Algorithm | Timing | Use for |
|---|---|---|---|
| `Point#mul(scalar)` | wNAF (window size 5) | **Variable-time** | Public scalars only: signature verification, computing known generator multiples |
| `Point#mul_ct(scalar)` | Montgomery ladder | **Constant-time** | Secret scalars: signing, key generation, ECDH shared-secret derivation |

**Rule of thumb:** if the scalar is derived from a private key or nonce, use `mul_ct`. If the scalar is a public value (e.g., a hash used in verification), `mul` is safe and faster.

```ruby
g = Secp256k1::Point.generator
pubkey = g.mul_ct(secret_key)       # secret key → constant-time
point = pubkey.mul(public_hash)     # public value → variable-time OK
```

### Pure-Ruby safety guard

`mul_ct` will raise `Secp256k1::InsecureOperationError` if the native C extension is not loaded. This prevents silent degradation to pure-Ruby arithmetic that cannot guarantee constant-time execution.

To check whether the extension is active:

```ruby
Secp256k1.native?  # => true if C extension is loaded
```

If you have evaluated the [risks](risks.md) and consciously accept the pure-Ruby implementation for your threat model, you can override the guard:

```ruby
# Option 1: environment variable
ENV['SECP256K1_ALLOW_PURE_RUBY_CT'] = '1'

# Option 2: explicit call (e.g., in an initialiser)
Secp256k1.allow_pure_ruby_ct!
```

Public-scalar operations (`mul`, field arithmetic, point operations) are unaffected and work in both modes without restriction.

## Constant-time discipline

### Field arithmetic

The field operations `fred`, `fsub`, `fneg`, and `fadd` use branchless conditional selection via bitwise masks derived from carry and borrow flags. Execution time does not depend on field values.

Inversion (`finv`) and square root (`fsqrt`) iterate over public constants (P-2 and (P+1)/4 respectively). Since the exponents are not secret, the variable iteration pattern is safe.

### Montgomery ladder

The C extension implements the Montgomery ladder with a branchless conditional swap (`cswap`) using bitwise masking — no branch on the scalar bit. This provides genuine constant-time scalar multiplication at the C level, with fixed 256 iterations regardless of scalar value.

### Pure-Ruby constant-time caveats

The Montgomery ladder algorithm is constant-time by design (fixed iteration count, no scalar-dependent branches). However, Ruby's interpreter introduces timing variability:

- Bignum arithmetic may have input-dependent timing at the VM level
- Garbage collection pauses are unpredictable
- No control over CPU cache behaviour

For production-grade side-channel resistance, use the native C extension. The pure-Ruby fallback provides algorithmic constant-time behaviour but cannot guarantee microarchitectural constant-time execution.

### Variable-time paths

The wNAF scalar multiplication loop (`scalar_multiply_wnaf`) branches on scalar bits and uses a precomputed table with data-dependent lookups. It is explicitly variable-time. This is acceptable for public scalars (signature verification) but must never be used with secret scalars.

## Thread safety

This gem has **no thread synchronisation**. The wNAF precomputed table cache (`WNAF_TABLE_CACHE`) is a mutable Hash at the module level with no mutex protection.

**Under MRI (CRuby):** The Global VM Lock (GVL) prevents truly concurrent Ruby execution, so cache corruption is unlikely in practice. However, the GVL is released during C extension calls, so concurrent `mul` calls could theoretically race on the cache.

**Under JRuby/TruffleRuby:** No GVL. Concurrent access to the cache would be unsafe without external synchronisation.

**Recommendation:** If using this gem from multiple threads, protect calls to `Point#mul` with your own mutex. `Point#mul_ct` does not use the cache and is safe to call concurrently (it has no mutable shared state).

## Platform and runtime support

| Runtime | C extension | Pure Ruby | Status |
|---|---|---|---|
| MRI (CRuby) 2.7+ on macOS/Linux | Yes | Yes | Tested |
| MRI on Windows (MSVC) | No (skipped) | Yes | Untested |
| JRuby | No (no `__uint128_t`) | Yes | Untested |
| TruffleRuby | No (no `__uint128_t`) | Yes | Untested |

The gem's design rationale includes JRuby/TruffleRuby portability, but these runtimes are not currently tested. The pure-Ruby fallback should work, but the thread safety caveats above apply with greater force on runtimes without a GVL.

The C extension requires a C99 compiler with `__uint128_t` support (GCC or Clang on x86_64 and arm64). `extconf.rb` checks for this at configure time and generates a no-op Makefile if unavailable.
