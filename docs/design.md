# Design rationale

Why this gem exists, what it does and doesn't do, and the trade-offs behind its architecture.

## Why pure Ruby as the base

Several secp256k1 SDKs exist across languages. They take different approaches:

| SDK | Approach |
|---|---|
| TypeScript (ts-sdk) | Pure TypeScript implementation |
| Go (go-sdk) | Pure Go implementation |
| Python (coincurve) | Wrapper around libsecp256k1 (C library) |

This gem adopts the TypeScript and Go approach — implementing the curve from scratch rather than wrapping libsecp256k1:

- **Auditability** — all curve operations are in readable Ruby or reviewed C, not a black box. The pure-Ruby layer serves as a reference implementation that can be read alongside the C extension.
- **Portability** — works on any Ruby runtime (MRI, JRuby, TruffleRuby) without requiring a system library. OpenSSL EC support varies across runtimes; this gem avoids that dependency entirely.
- **No system dependency** — no libsecp256k1 installation, no pkg-config, no platform-specific build scripts. `gem install` works without prerequisites beyond a C compiler (and even that is optional).
- **Self-contained testing** — the gem's test suite validates its own implementation against Wycheproof vectors. No need to trust that a system-installed libsecp256k1 is the correct version or was compiled with the right flags.

## Primitives, not protocols

This gem provides low-level elliptic curve primitives only:

- Field arithmetic (mod P)
- Scalar arithmetic (mod N)
- Point operations (addition, doubling, negation, serialisation)
- Scalar multiplication (variable-time and constant-time)
- SEC 1 point encoding/decoding

It does **not** implement:

- ECDSA signing or verification
- Schnorr signatures (BIP-340)
- HD key derivation (BIP-32)
- Mnemonic generation (BIP-39)
- Hashing (SHA-256, RIPEMD-160) or HMAC
- AES encryption

These higher-level operations belong in consuming libraries (e.g., [bsv-ruby-sdk](https://github.com/sgbett/bsv-ruby-sdk)) that compose the primitives this gem provides. This separation keeps the gem focused and avoids pulling in cryptographic protocol decisions that vary by application.

## The acceleration trade-off

The pure-Ruby implementation runs at approximately 100 scalar multiplications per second. The C extension raises this to approximately 2,277 — a 22x speedup. This makes the difference between "too slow for production" and "fast enough for signing-heavy workloads".

The trade-off: the C extension requires a C99 compiler with `__uint128_t` support, which excludes MSVC on Windows. Rather than making the C extension mandatory (and losing Windows/JRuby/TruffleRuby), the gem treats it as an optional accelerator. The API is identical regardless of which implementation is active — consuming code doesn't need to know or care.

## Why not FFI?

An alternative to a C extension would be FFI bindings to libsecp256k1. This was rejected because:

- FFI adds a runtime dependency and still requires the system library to be installed
- The self-contained approach means `bundle install` is the only setup step
- The C extension can be tailored to the gem's internal representation rather than adapting to libsecp256k1's API
- Testing is simpler — the gem validates against known vectors rather than trusting a third-party library's correctness
