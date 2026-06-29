# Plan — #21 Scalar reduction carry (v1 blocker)

Fixes **H-1** (high), **I-2** (info, same root cause), **I-11** (low, same
function). Report: [`docs/security-review-v1.md`](../docs/security-review-v1.md)
§3. All changes are in `ext/secp256k1_native/scalar.c`.

## Root cause (one function)

`scalar_reduce_limbs` reduces a 512-bit value mod N by folding `c_N = 2^256 mod N`
twice, then folding a small residual carry. Two defects in the residual-fold +
final-reduction tail (current `scalar.c:186-210`):

1. **H-1/I-2:** the residual fold does `r->d[3] += (a2 >> 64)`, which can carry
   out of bit 255. That carry — the 257th bit of the true value — is **dropped**.
   Because `c_N == 2^256 − N`, a dropped `2^256` leaves the result short by
   exactly `c_N`, and the single conditional subtraction of N can't recover it.
   Result is wrong-by-`c_N` and still in `[0, N)`, so nothing flags it.
2. **I-11:** `if (h == 0) continue;` (`scalar.c:166`) and `if (carry3)`
   (`scalar.c:193`) are secret-dependent branches (fire on ~47% / ~57% of
   random inputs). Outside the documented CT scope (the ladder is clean) but
   zero-cost to remove.

### Why a single conditional subtraction is still sufficient after the fix

After two folds the pre-residual value is `< 2^256` and `carry3 ≤ 1`, so the
true value `V` after the residual fold is `< 2^257` — i.e. `topcarry ∈ {0,1}`.
`V < 2N` (since `2N ≈ 2^257`), so `V mod N` needs at most one subtraction of N.
And `V ≥ N` exactly when `topcarry == 1` **or** (`topcarry == 0` and the low
256 bits `≥ N`). When `topcarry == 1`, computing `r − N` as a 256-bit subtract
wraps to `low + (2^256 − N) = low + c_N`, which is the correct residue. So:
**keep `(r − N)` whenever `topcarry` is set OR `r ≥ N`.** (Verified in Python
over the whole `hi == N+1` band + 500k random inputs during the review.)

## The change

Replace the residual-fold + final-reduction tail (`scalar.c:186-210`) with:

```c
    r->d[0] = t[0]; r->d[1] = t[1]; r->d[2] = t[2]; r->d[3] = t[3];

    /* Residual fold — unconditional (I-11: no branch on the carry) and
     * capturing the carry OUT of the top limb (H-1: previously dropped at
     * bit 255). After two folds the value here is < 2^257, so topcarry is 0/1. */
    uint64_t carry3 = t[4];
    uint128_t a0 = (uint128_t)carry3 * CN_LO + r->d[0];
    r->d[0] = (uint64_t)a0;
    uint128_t a1 = (uint128_t)carry3 * CN_MID + r->d[1] + (a0 >> 64);
    r->d[1] = (uint64_t)a1;
    uint128_t a2 = (uint128_t)carry3 + r->d[2] + (a1 >> 64);
    r->d[2] = (uint64_t)a2;
    uint128_t a3 = (uint128_t)r->d[3] + (a2 >> 64);
    r->d[3] = (uint64_t)a3;
    uint64_t topcarry = (uint64_t)(a3 >> 64);     /* 0 or 1 — was silently dropped */

    /* Branchless final reduction: keep (r - N) when topcarry set OR r >= N.
     * c_N == 2^256 - N, so subtracting N once when topcarry is set converts the
     * lost 2^256 into the correct +c_N. */
    uint256_t reduced;
    uint64_t borrow = uint256_sub(&reduced, r, &CURVE_N);   /* borrow==0 <=> r >= N */
    uint64_t keep_reduced = topcarry | (uint64_t)(borrow == 0);
    uint64_t mask = -(uint64_t)(keep_reduced != 0);
    int j;
    for (j = 0; j < 4; j++) {
        r->d[j] = (reduced.d[j] & mask) | (r->d[j] & ~mask);
    }
```

Then remove the I-11 branch in the second fold: delete `if (h == 0) continue;`
at `scalar.c:166` (the loop body is a faithful no-op when `h == 0`, so removing
the guard changes no result, only the timing).

> The `if (carry3)` branch is removed by the rewrite above (the fold is now
> unconditional and is a no-op when `carry3 == 0`).

**Defence in depth (optional but recommended):** reduce both operands in
`rb_scalar_mul` (`scalar.c:358`) before multiplying, mirroring `rb_scalar_inv`
(`scalar.c:376-392`), so a non-canonical operand can never reach the primitive
from Ruby in the first place.

## Tests to add (`spec/secp256k1_native_spec.rb`)

Random tests provably cannot reach H-1's band (density ~2^-384) — these
structured vectors are load-bearing:

```ruby
it 'scalar_mul is correct for non-canonical operands (H-1)' do
  n = Secp256k1::ORDER            # or the literal N
  expect(Secp256k1Native.scalar_mul(2**256 - 1, n + 2)).to eq(((2**256 - 1) * (n + 2)) % n)
end

it 'scalar_reduce handles a non-zero high word (I-2)' do
  # drive whichever public entry exercises scalar_reduce with hi != 0,
  # or assert via scalar_mul above; the fix closes both.
end
```

## Verify

- `cd security && python3 dfuzz_ref.py` → `known-defect vectors reproducing=0/4`
  for the `smul`/`sreduce` cases, in-contract mismatches still 0.
- ctgrind clean: `security/run-checks.sh` reports ctgrind **PASS** (0 errors) —
  run via Docker on macOS (see [`docs/running-checks.md`](../docs/running-checks.md)).
- `bundle exec rspec` green, including the new vectors.
- Extend `rake timing:verify` to cover `scalar_mul`/`scalar_reduce` and update
  [`docs/security.md`](../docs/security.md) to record the scalar layer as
  branchless.

## Done when

- [ ] H-1 vectors pass; differential reports 0/4 reproducing.
- [ ] ctgrind reports 0 errors (I-11 branches gone).
- [ ] New rspec regression vectors committed and green.
- [ ] `security.md` / timing task updated for the now-branchless scalar layer.
