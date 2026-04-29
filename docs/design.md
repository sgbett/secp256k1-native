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

This gem deliberately provides only low-level elliptic curve primitives — no signing, no key derivation, no hashing. See the [scope table](architecture.md#scope) for the full breakdown.

This boundary exists because cryptographic protocol decisions (ECDSA vs Schnorr, RFC 6979 nonce generation, BIP-32 derivation paths) vary by application. Keeping the gem focused on curve arithmetic avoids embedding those choices and keeps the codebase small — which the evidence shows correlates with fewer vulnerabilities. Higher-level operations belong in consuming libraries (e.g., [bsv-ruby-sdk](https://github.com/sgbett/bsv-ruby-sdk)) that compose these primitives.

## The C extension: hardening, not just acceleration

The C extension exists primarily to provide constant-time guarantees that Ruby's interpreter cannot offer. The ~22x performance improvement is a welcome consequence of the same fixed-width arithmetic design, not the driving motivation.

The gem is architectured so that the C extension is optional — the pure-Ruby implementation works without it, the API is identical, and consuming code doesn't need to know which is active. This means the gem installs and runs everywhere Ruby does, but can be hardened with the C extension where the platform supports it (C99 compiler with `__uint128_t`).

For the security properties this enables, see [security](security.md). For the performance characteristics, see [performance](performance.md). For the broader question of whether a custom implementation is appropriate, see [evaluating the risks](risks.md).

## Why not wrap libsecp256k1?

FFI bindings to libsecp256k1 already exist. That gem occupies a different point in the trade-off space described in the [risk assessment](risks.md) — it accepts the dependency and supply chain risks in exchange for a battle-tested implementation. This gem makes the opposite choice.

The decision to implement from scratch rather than wrap an existing library follows from the same constraints that motivate the gem's existence:

- **The TypeScript and Go SDKs implement from scratch** — this gem matches that approach for Ruby, keeping the SDK ecosystem consistent
- **No dependencies means no supply chain risk** — `gem install` is the only setup step, with no system library, no pkg-config, no platform-specific build scripts
- **The C extension is tailored to the gem's internals** — it accelerates the exact operations the pure-Ruby layer defines, rather than adapting to libsecp256k1's API and data representations
- **Self-contained testing** — the gem validates against Wycheproof vectors rather than trusting that a system-installed library is the correct version or was compiled with the right flags

Whether this trade-off is right for a given project depends on the threat model. The [risk assessment](risks.md) lays out the evidence; users should evaluate it against their specific context.
