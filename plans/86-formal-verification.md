# Plan — #86 Formal verification of the core modular arithmetic

Status: **draft, post-v1, not a release blocker.** Prompted by the safegcd
verification paper (O'Connor & Poelstra 2025, cited in `risks.md` via #85) and by
**H-1** — the dropped-carry bug in `scalar_reduce_limbs` that a functional-correctness
proof of the reduction would have made impossible.

## The idea in one line

Don't try to "prove Fermat inversion." **Prove the field/scalar reductions and the
multiply; Fermat inversion then follows as a near-corollary** — and the multiply/reduce
proof underwrites the *entire* library (every field op, every point op, the ladder).

`finv(a)·a ≡ 1 (mod p)` decomposes into:
- (i) the square-and-multiply loop computes `a^(p-2)` over a **public constant** exponent
  — an easy induction over the loop; and
- (ii) `fmul`/`fred` implement multiplication mod P — the hard, shared part.

Prove (ii) and (i) is short. Skip (ii) and you've proved nothing load-bearing.

## Scope & honesty (state these up front in any artifact)

- **Functional correctness only** (right math). *Not* constant-time — CT stays the
  separate deterministic story (`security/ctgrind_harness` + the CT assembly-invariant
  in `nix/`). Don't let a correctness proof be mis-sold as a timing proof.
- **Source-level.** The gem compiles per-user via `mkmf`, so there is no canonical `.so`.
  The honest claim is "verified source + the existing codegen-identity checks", never
  "verified binary" — identical caveat to the timing story (`security.md`).
- **Target = the pure-C `*_internal` functions** (`ext/secp256k1_native/{field,scalar}.c`),
  which take `uint256_t*` and touch zero Ruby. The standalone harnesses
  (`security/`, `timing/ruby_stubs.c`) already prove these link without the Ruby runtime —
  reuse that isolation.

## Approach ladder (pick per milestone)

1. **SAW / SMT — primary, most accessible.** Galois's Software Analysis Workbench over
   LLVM bitcode; specs in Cryptol/bitvectors; discharged by SMT (Z3/Yices/Bitwuzla). Runs
   on the *actual* C, no interactive proof.
   - Key advantage over the Coq route: **LLVM has native `i128`** (clang lowers
     `__uint128_t` to `i128`), so the SAW path likely needs **no `umul128` refactor**.
     *Confirm early* that SAW/Crucible handles `i128` operations in our bitcode.
2. **Fiat-Crypto as oracle / transplant — alternative / cross-check.** Prove our field
   arithmetic equivalent to Fiat-Crypto's proven secp256k1 output, or adopt its field
   layer wholesale and inherit the proof (BoringSSL's route). Cost: erodes the
   hand-written / self-contained character the project values. Keep as a fallback for M3.
3. **Coq / VST — the trophy (O'Connor–Poelstra pedigree).** `clightgen` → Verifiable C.
   Prerequisite: factor the `__uint128_t` multiplies into a `secp256k1_umul128`-style
   64×64→(hi,lo) helper with a spec — **CompCert lacks 128-bit ints**, which is exactly
   why libsecp256k1 uses `umul128` (their Figure 5 spec is for it). Months of Coq; do only
   if SAW stalls or the pedigree is wanted for its own sake.

## Milestones (SAW-first)

- **M0 — environment.** Install SAW + a solver (start Z3; add Bitwuzla for the multiply).
  Emit LLVM bitcode from the internal sources: `clang -emit-llvm -c -O1 -I ext/... -I timing
  ext/secp256k1_native/scalar.c` (link against `timing/ruby_stubs.c`-style stubs so no Ruby
  symbols are needed, mirroring `security/Makefile`). Add SAW + solvers to the Nix flake so
  the proof env is pinned like everything else.
- **M1 — `scalar_reduce_limbs ≡ (hi·2²⁵⁶ + lo) mod N`.** The **H-1 killer** and the
  best first target: the reduction is add/sub/compare-heavy (no big multiply), so it is
  SMT-tractable, and a passing proof *is* the regression guarantee for the whole H-1/I-2
  class that random testing cannot reach. Prove it against a `Z`-valued Cryptol spec.
- **M2 — `fred_internal ≡ (hi·2²⁵⁶ + lo) mod P`.** Same shape; the fold constant is
  small (~33 bits) so even easier than M1.
- **M3 — `fmul_internal ≡ (a·b) mod P`.** The risk item: 256×256→512 multiply is hard for
  SMT (nonlinear). Strategy: prove the schoolbook product `= a·b` compositionally (let the
  solver handle 64×64 limb products + accumulation; if it times out, spell out the limb
  structure or prove per-limb lemmas), then compose with M2's reduction. Bitwuzla/ABC
  bit-blasting is the best bet; a Coq lemma for just this multiply is the escape hatch.
- **M4 — `finv_internal` / `scalar_inv_internal`.** Assuming M2/M3 correct, prove the
  square-and-multiply loop computes `a^(p-2)` / `a^(N-2)` for the exact exponent schedule
  (induction over the fixed public exponent bits), then Fermat's little theorem gives the
  inverse. Short, given the multiply.
- **M5 — CI (optional, non-blocking).** A `make verify` / Nix gate step that re-runs the
  discharged proofs. Start advisory; promote to required once M1–M2 are stable.

## First spikes for the main machine

1. Reproduce the standalone bitcode build (M0) and confirm SAW loads it and sees
   `scalar_reduce_limbs` with `i128` locals intact.
2. Write the M1 SAW script + Cryptol spec for `scalar_reduce_limbs`; discharge with Z3.
   This is the smallest end-to-end proof and validates the whole toolchain choice before
   any refactor is contemplated.
3. Only if M3 resists SMT: prototype the `umul128` factoring and re-evaluate SAW vs the
   Coq/VST route.

## Open questions / risks

- SAW's handling of `i128` in our bitcode (M0 gate). If poor, the `umul128` refactor moves
  earlier and applies to the SAW path too.
- SMT scalability on the 256×256 multiply (M3) — the main technical risk; M1/M2/M4 are low-risk.
- Whether to keep the proof over gcc-dialect source (SAW/LLVM) or migrate to
  CompCert-compilable source (Coq/VST) — the latter buys binary-semantics alignment at the
  cost of the `umul128` refactor and dropping `__uint128_t`.

## Relationship to existing work

Complements — does not replace — the empirical stack (differential fuzzing, sanitizers,
ctgrind, dudect). Those are inductive evidence over sampled inputs; this is deductive over
*all* inputs for the proved functions. No shipped behaviour changes unless the `umul128`
refactor (Coq route only) is taken, which would be its own PR with the differential + ctgrind
gates re-run.
