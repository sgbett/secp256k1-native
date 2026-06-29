# Security-review harnesses

These are the empirical harnesses from the pre-v1.0 security review
(see [`../docs/security-review-v1.md`](../docs/security-review-v1.md)). They are
preserved here so every check in that report can be re-run and wired into CI —
the review's threat model is "find what an opportunistic attacker with commodity
tooling would find, *first*", and that only holds if the checks keep running.

They compile the C extension's internal functions **standalone** — no Ruby
runtime — using the project's existing stub at `../timing/ruby_stubs.c`, exactly
like the `../timing/` dudect harness. gcc 13 needs `-fcommon` (the module global
is linked from two translation units); the Makefile sets it.

## Harnesses

| File | What it does |
|------|--------------|
| `dfuzz_harness.c` + `dfuzz_ref.py` | **Differential fuzzer.** `dfuzz_ref.py` is an *independent* secp256k1 reference written from scratch from the curve parameters (not the gem's own Ruby — so shared-mental-model bugs surface). The default driver runs a reproducible in-contract random pass over every field and scalar op (where the confirmed defects live) plus the load-bearing structured regression vectors for H-1/M-1/I-2. The module also carries an independent **geometric** point-op reference (de-projectivise via an independent modular inverse, compare against the true affine group law, so it can't merely mirror the C special-case selection) — used for the point-op coverage reported in the review and available to extend the driver. |
| `ctgrind_harness.c` | **Constant-time secret-poisoning.** Marks secret scalars/operands `UNDEFINED` via `valgrind/memcheck.h`, then runs the ops under valgrind; any secret-dependent branch or memory address is reported deterministically. This is the *primary* CT evidence (deterministic, robust to VM noise — unlike the statistical dudect harness in `../timing/`). |
| `asan_sweep.c` | **ASan + UBSan sweep.** Exercises every internal op over structured edge cases and millions of random inputs, including deliberately unreduced / off-curve / infinity / aliased inputs, under AddressSanitizer + UndefinedBehaviorSanitizer. |

## Running

```sh
make dfuzz   && python3 dfuzz_ref.py             # differential fuzz (ITERS / --iters, --seed)
make ctgrind && valgrind --tool=memcheck --error-exitcode=1 ./ctgrind_harness
make asan    && UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 ./asan_sweep
make check                                       # build + short smoke of all three
make clean
```

`dfuzz_ref.py` exits non-zero only if an *in-contract* case mismatches — that's
its CI-gate role. The four known-defect regression vectors are exercised on
every run and any divergence is printed for visibility; they do **not** affect
the exit code, so the gate is already green against the reviewed v1.0 tree.
When the H-1/M-1 fixes land, those divergence prints will simply disappear.

## Expected results (against the reviewed v1.0 tree)

- **`asan_sweep`** and the **differential fuzzer** are **clean** on in-contract
  inputs (the review found no memory-safety defect and no correctness mismatch
  on reduced inputs).
- **`ctgrind_harness`** currently reports a small number of errors — these are
  **exactly the documented finding I-11**: secret-dependent branches in
  `scalar_reduce_limbs` (`scalar.c:166`, `:193`), which are *outside* the
  documented constant-time scope (the Montgomery ladder behind `Point#mul` is
  clean). After the I-11 branchless fix lands, this harness should report
  `0 errors` and can become a release gate.
- The differential fuzzer reproduces **H-1** and **M-1** from a structured
  corner seed (`scalar_mul(2^256-1, N+2)`, `scalar_add(N, N)`); random inputs
  provably cannot reach H-1's failing band (density ~2^-384), so the structured
  regression vectors are load-bearing, not optional.

## Note

These harnesses establish empirical lower bounds on robustness. They are not a
substitute for a professional cryptographic audit (see the report's "Assurance
and residual risk").
