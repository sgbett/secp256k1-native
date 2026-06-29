# Plan — #22 Boundary input-contract hardening

Fixes **M-1** (medium), **L-3** (low), **I-3** (info), **L-4** (low), **L-1**
(low), **L-2** (low). Report:
[`docs/security-review-v1.md`](../docs/security-review-v1.md) §3.

One theme: the raw C primitives assume reduced / in-range / Integer inputs but
the Ruby↔C wrappers don't enforce it, so a consumer calling the primitives
directly gets silently-wrong or non-canonical results. None is reachable through
the gem's own `Point`/SEC1 API. The clean fix is **reduce / validate at the
wrapper**, mirroring `rb_scalar_inv` (which already reduces).

Optional split into two PRs: **B1 canonicalize** (M-1, L-3, I-3, L-4) and **B2
type-validate** (L-1, L-2).

## B1 — canonicalize / reduce inputs

### M-1 — `rb_scalar_add` under-reduces (`scalar.c:401`)
`scalar_add_internal` (`scalar.c:273`) subtracts N at most once — correct only
for `a,b < N`. `scalar_add(N, N)` → non-canonical `N` instead of `0`.
**Fix:** reduce `ua`, `ub` mod N in `rb_scalar_add` before the call, exactly as
`rb_scalar_inv` does:
```c
uint256_t zero = {{0,0,0,0}};
scalar_reduce(&ua, &zero, &ua);
scalar_reduce(&ub, &zero, &ub);
```
(After reduction `sum < 2N`, so the single conditional subtraction is correct.)

### L-3 / I-3 — `fadd`/`fsub`/`fneg` don't reduce ≥ P inputs (`field.c`)
`rb_fadd` (517), `rb_fsub` (533), `rb_fneg` (549) pass operands straight to the
internals, which assume `< P`; `fadd(P-1, P+1)` returns exactly `P`. I-3 is the
`fneg` case of the same bug. **Fix:** `fred` each operand in the wrapper before
calling the internal (mirror `rb_finv`/`rb_fsqrt`, which already `fred` first).
Also canonicalize the **pure-Ruby** `fsub`/`fneg` so the two backends agree.

### L-4 — `rb_scalar_mod` rejects positive ≥ 2^256 (`scalar.c:328`)
It pre-reduces only when the input is negative, so a large positive value hits
`rb_to_uint256`'s "exceeds 256 bits" raise while its negative counterpart
succeeds. **Fix:** apply the Ruby `%` pre-reduction unconditionally — drop the
`if (negative)` and always `a_norm = rb_funcall(a, '%', n_rb)`.

## B2 — reject non-Integer inputs

### L-1 — `rb_to_uint256` truncates Floats / coerces `#to_int` (`field.c:27`)
`rb_integer_pack` calls `rb_to_int`, so `fmul(1.5, 2)` silently becomes
`fmul(1, 2)`. Affects all 16 wrappers. **Fix (one line, covers all):** at the
top of `rb_to_uint256`,
```c
if (!RB_INTEGER_TYPE_P(rb_int)) rb_raise(rb_eTypeError, "expected Integer");
```

### L-2 — `Point#mul` truncates non-Integer scalars (`lib/secp256k1.rb:554`)
A Float passes `zero?`/`%` and is truncated in the native marshal. **Fix:**
`raise ArgumentError, 'scalar must be an Integer' unless scalar.is_a?(Integer)`
at the top of `Point#mul` and `Point#mul_vt`. (Hardening `rb_to_uint256` per L-1
also closes this for the native path, but the explicit Ruby guard gives a clean
error and matches the pure-Ruby backend.)

## Tests

- Differential: extend `security/dfuzz_ref.py` with operand vectors ≥ P (field)
  and ≥ N (scalar); the `sadd(N,N)` and `sadd(2^256-1, 2^256-1)` regression
  cases turn green. In-contract pass stays 0 mismatches.
- rspec (`spec/secp256k1_native_spec.rb`): operands ≥ P / ≥ N asserting
  `(a op b) mod P|N` matches pure Ruby; non-Integer inputs assert `TypeError`
  (C boundary) / `ArgumentError` (`Point#mul`); `scalar_mod(2**600)` no longer
  raises and matches `2**600 % N`.

## Done when

- [ ] Every wrapper's documented `(… mod P)` / `(… mod N)` contract holds for any
      256-bit input, matching the pure-Ruby reference (differential green on a
      ≥P/≥N sweep).
- [ ] Non-Integer inputs raise rather than truncate, on both backends.
- [ ] `scalar_mod` accepts large positive inputs.
- [ ] New rspec specs committed and green.
