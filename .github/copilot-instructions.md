# Copilot code review — secp256k1-native

Cryptographic primitives library. Pure-Ruby reference (`lib/secp256k1.rb`) + optional C extension in `ext/secp256k1_native/` for constant-time hardening of 16 hot-path methods. The C extension exists for security, not speed.

## Conventions to know

- `uint256_t` = 4 × `uint64_t` little-endian limbs; `d[0]` is least-significant.
- Field modulus `P = 2^256 − 2^32 − 977`. Curve order `N`. Distinct.
- `Point#mul` (alias `mul_ct`) — Montgomery ladder, constant-time, default; OK for secret scalars.
- `Point#mul_vt` — wNAF, variable-time, **public scalars only**.
- Jacobian repr `[X, Y, Z]`. Infinity = `[0, 1, 0]`.

## Carry propagation (in `field.c`)

- Carry/borrow must propagate through all four limbs after each add/sub/mul/reduce. Flag suppression, masking, or early termination of the chain.
- Fast-reduction folds the high half via `FRED_C = 0x1000003D1` (= `2^32 + 977`). The folded high-word carry must be re-propagated in a second pass.
- Flag any narrowing of `__uint128_t` to `uint64_t` that drops the high half without absorbing it into carry.

## Canonicalisation

- Field outputs must lie in `[0, P)`. Flag any path that can return a value in `[P, 2P)` — the final conditional subtraction is load-bearing.
- Scalar outputs from `scalar_*` must lie in `[0, N)`.
- SEC1: compressed = 33 B (`0x02`/`0x03` prefix); uncompressed = 65 B (`0x04` prefix). Reject anything else.

## Point validation

- Compressed-point parsing must verify `Y² ≡ X³ + 7 (mod P)` before accepting reconstructed `Y`.
- Reject off-curve points and `Y = 0` at boundaries that don't admit the identity.
- Zero/identity points in Jacobian form must be `[0, 1, 0]`, not `[0, 0, 0]`.
- `jp_add_internal` is fully branchless: `P == Q` and `P == −Q` are handled via mask-based `uint256_select` over an unconditional inline `jp_double`. Flag any regression to a branching implementation — the earlier branching version measured |t| = 875 timing leakage.

## Modulus confusion

- Field code is `mod P`. Scalar code is `mod N`. Flag `mod P` on scalar paths or `mod N` on field paths.
- Fermat inverse exponents: field uses `P − 2`, scalar uses `N − 2`.
- Reject `0` and `≥ N` scalars at API boundaries; do not silently reduce.

## Constant-time (secret-scalar paths)

Secret-scalar paths: `Point#mul`, `scalar_multiply_ct`, `scalar_mul`, `scalar_inv`. On these paths, flag:

- `if` / `switch` / `?:` / short-circuit `&&` `||` / early `return` `break` `continue` whose taken-ness depends on secret data.
- Variable-time C operators on secret data: `/`, `%`, variable-count shifts.
- Array/table indexing where the index is secret-derived (cache-timing leak).
- `memcmp` / `==` / `strcmp` on secret-derived buffers — require a constant-time compare.
- Loops whose iteration count depends on secret data. The Montgomery ladder is fixed at 256 iterations.
- Hand-rolled branchless code that ignores `cswap` (in `jacobian.c`) and `uint256_select` (in `secp256k1_native.h`).

Flag CT-critical changes (to `fred`, `fsub`, `fneg`, `fadd`, `scalar_multiply_ct`, `cswap`, `jp_add_internal`, `jp_double_internal`, or the Montgomery ladder body) that don't update timing-test coverage.

## API safety contract

- New secret-scalar code paths must call `mul`, not `mul_vt`.
- Variable-time methods must be `_vt`-suffixed with a doc comment stating the public-scalar precondition.
- No silent C→pure-Ruby fallback on secret-scalar paths. Bypassing both `SECP256K1_ALLOW_PURE_RUBY_CT` and `Secp256k1.allow_pure_ruby_ct!` is a regression.

## C extension memory safety

- `malloc`/`calloc`/`realloc`/`free` anywhere in `ext/secp256k1_native/` — there should be none.
- Manual byte shuffling instead of `rb_integer_pack` / `rb_integer_unpack`.
- Decoding `Integer` inputs without bounds-checking (> 256 bits, wrong sign) — must raise, not truncate.
- Plain `memset` of secret material in a stack buffer about to leave scope. Compiler may elide; use a volatile-cast write or explicit barrier.
- Compiler-specific intrinsics without an `extconf.rb` gate or fallback.

## State management

- New module-level mutable `Hash` / `Array` / `Set` without `mul_vt`-only confinement or a mutex. `WNAF_TABLE_CACHE` is the only one; it is confined to public-scalar paths.

## Tests

- Field / scalar / point changes without RSpec additions in `spec/`.
- Asymmetric edits to pure-Ruby vs C — `spec/secp256k1_cross_property_spec.rb` requires they agree.
- Invalid inputs (zero or out-of-range scalars, off-curve points, malformed SEC1) that don't raise the expected exception type.

## Do not flag

- Variable-time operations inside `mul_vt` / wNAF table code / wNAF cache. Explicitly public-scalar.
- Single-letter parameter names (`k`, `p`, `x`, `y`, `z`, `n`, `r`, `s`, `h`). Curve-notation convention.
- `__uint128_t`, GCC/Clang-specific intrinsics gated by `extconf.rb`, C99 features.
- `# frozen_string_literal: true`, Ruby 2.7 syntax. Rubocop enforces.
- Pure-Ruby's lack of constant-time guarantees. Documented and gated.
- `Point#mul_vt` and the `mul_ct` alias. Intentional.
- 16-method replacement at C extension load. Intentional architecture.
