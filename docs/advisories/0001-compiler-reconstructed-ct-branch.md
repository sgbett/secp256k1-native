# Security Advisory 0001 — Compiler-reconstructed timing side-channel in `Point#mul`

> Draft for a GitHub Security Advisory (GHSA). Fill the GHSA form from the
> fields below; the technical sections are the supporting writeup.

| | |
|---|---|
| **Package** | `secp256k1-native` (RubyGems) |
| **Affected component** | C extension — `uint256_select` in the Montgomery-ladder secret-scalar path |
| **Severity** | High (timing side-channel on the secret scalar) |
| **CVSS v3.1** | `AV:N/AC:H/PR:N/UI:N/S:U/C:H/I:N/A:N` (5.9) — confidentiality-only; attack complexity High (statistical timing recovery). The score is *consumer-dependent*: this gem ships no network surface of its own. |
| **CWE** | CWE-208 (Observable Timing Discrepancy); CWE-1255 (compiler removal of a security-relevant code construct) |
| **Affected versions** | Builds containing the branchless `uint256_select` (introduced with the 0.17.0 `jp_add_internal` |t|=875 fix) **when compiled by a C compiler that reconstructs the select into a branch.** Observed reconstructing into a secret-dependent branch at `-O2` on **GCC 14.3.0, 15.1.0, and 15.2.0**; GCC 13.3.0 compiled it to a constant-time `cmov` and GCC ≤ 12.4.0 to pure bitwise ops, so the reconstruction first appears in the 13→14 range. Not exhaustively bisected across point releases, targets, or flag sets; GCC 16 and clang untested. Treat as compiler-and-flags-dependent, not a fixed version range (see *Affected configurations*). |
| **Patched in** | `0.18.0` — value barrier on all constant-time select masks. |
| **Found by** | Bare-metal dudect verification (issue #25). |

## Summary

`Point#mul` — the default, constant-time scalar multiplication and the library's
headline secret-scalar operation — could leak timing information about the secret
scalar (a private key or ECDSA-style nonce in a downstream consumer) **not because
of a source-level bug, but because the compiler reconstructed a branch from
branchless source.**

The Montgomery ladder selects between point candidates with `uint256_select`,
written deliberately branchlessly as `r = (a & ~mask) | (b & mask)` with a mask
that is all-ones or all-zeros. GCC 15.2 at `-O2` recognises this select idiom,
reconstructs the original boolean condition, and emits a secret-dependent
conditional jump (`je`/`jne`). The branch's taken/not-taken timing correlates with
the secret scalar bits flowing through the ladder.

This silently undid the 0.17.0 fix for the historical |t|=875 infinity-branch
leak, which had relied on `uint256_select` compiling to branchless code.

## Impact

A timing side-channel on the secret scalar in constant-time scalar
multiplication. For a consumer that calls `Point#mul` (or the native
`scalar_multiply_ct`) on a secret key or nonce and exposes timing to an attacker
(e.g. an online signing oracle), repeated measurements can statistically recover
scalar bits — the classic ECC private-key/nonce timing-attack setting
(cf. Brumley–Boneh). The leak is in the *compiled binary*; the source is correct,
so source review and the deterministic ctgrind check on a *non-reconstructing*
toolchain do not reveal it.

Pre-1.0 with no published RubyGems dependents, so this is handled as
fix-publish-and-document: full GHSA + CVE record, without a coordinated
downstream-notification timeline (no dependency graph to coordinate with).
The CVE is filed for citability and so the empirical record (paper → review →
compiler regression → fix) is permanent and searchable.

## Affected configurations

The defect is a property of the (source, compiler, flags) triple, not the source
alone.

**Compiler — where the reconstruction happens.** A reproducible sweep of the same
pre-fix source under GCC 9.5–15.1 (all from one pinned `nixpkgs`, `-O2`, see the
flake in `flake.nix`) locates the regression at the 13→14 boundary:

| GCC | pre-fix `uint256_select` codegen | leak? |
|---|---|---|
| ≤ 12.4.0 | pure bitwise ops (intended branchless) | no |
| 13.3.0 | constant-time `cmov` (recognises the select) | no — benign |
| 14.3.0 / 15.1.0 / 15.2.0 | secret-dependent `je`/`jne` | **yes** |

The extension ships with `-O2` (`extconf.rb` appends it), so a binary built by an
affected GCC (14/15) is affected. GCC 16 and clang are untested, and this is not
exhaustively bisected across point releases, targets, or flag sets — treat as
compiler-and-flags-dependent, not a fixed version range.

- **Source:** any build with the branchless `uint256_select` (0.17.0 onward).
- **Not affected:** the pure-Ruby path (different code; separately not claimed
  constant-time); GCC ≤ 13 (pre-fix it emits bitwise ops or a constant-time
  `cmov`, not a branch — note that `cmov`-on-secret still trips ctgrind but is not
  a timing leak); and **any** compiler once the value-barrier patch is applied —
  the fixed source compiles to pure bitwise ops on all of GCC 9.5–15.1 (0 `je`/`jne`,
  0 `cmov`).

## Patch

Introduce a value barrier and route every constant-time select mask through it:

```c
/* empty volatile asm — makes x opaque to the optimiser (libsecp256k1/BoringSSL) */
static inline uint64_t ct_value_barrier_u64(uint64_t x) {
#if defined(__GNUC__) || defined(__clang__)
    __asm__ volatile("" : "+r"(x));
#endif
    return x;
}

/* the ONLY way a constant-time mask is constructed in this extension */
static inline uint64_t ct_mask_u64(uint64_t flag) {
    return ct_value_barrier_u64(-(uint64_t)(flag != 0));
}
```

Applied to all nine mask-select sites: `uint256_select`; `fred`, `fadd`, `fsub`,
`fneg`; `scalar_reduce`, `scalar_add`; the `jp_double` infinity select; and the
ladder `cswap`. Only `uint256_select` actively branchified under GCC 15.2/`-O2`;
the rest are hardened as defence-in-depth so a future compiler/flag/target change
cannot reconstruct them either.

## Workarounds (for unpatched users)

- Compile the extension at `-O0`/`-O1`, or with a compiler that does not
  reconstruct the select (verify with the disassembly check below) — fragile,
  not recommended.
- Do not call `Point#mul` on secret scalars from a timing-observable context
  until patched.

## Verification (reproducible)

Reference machine: AMD Ryzen 9 9950X (Zen 5), microcode `0xb404023`,
Ubuntu 26.04 / Linux 7.0.0-14, GCC 15.2.0; `systemd-detect-virt = none`; turbo
off, `performance` governor (min=max), SMT off, harness pinned with
`taskset -c <core>` under `chrt -f`. See
[`docs/timing-verification-runbook.md`](../timing-verification-runbook.md).

**Deterministic (ctgrind / valgrind):**
```
cd security && make ctgrind && valgrind -q --error-exitcode=1 ./ctgrind_harness
```
- Before: "Conditional jump or move depends on uninitialised value" at the
  `uint256_select` source lines, via `jp_add_internal` → `scalar_multiply_ct_internal`.
- After: clean, exit 0.

**Disassembly (root cause):**
```
cc -O2 -g -std=c99 -fcommon -I timing -I ext/secp256k1_native \
   -c ext/secp256k1_native/jacobian.c -o /tmp/jac.o
objdump -dl /tmp/jac.o   # before: je/jne attributed to the select lines; after: none
```

**Statistical (dudect, bare metal):**
```
cd timing && make && taskset -c <core> ./timing_harness
```
- Before: `scalar_multiply_ct_internal` |t| ≈ 21 (stable across runs).
- After: mean |t| = 0.68, max 1.57, 0/20 runs over the 4.5 threshold.

**Functional:** `bundle exec rspec` → 416 examples, 0 failures.

## Lasting control

Bare-metal dudect is now a **required pre-tag release gate**, re-run whenever the
known-good compiler version changes. The deterministic ctgrind check remains the
primary CT evidence but runs against CI's compiler; only the statistical
bare-metal run observes the timing of the binary that actually ships. A
constant-time *source* is not a constant-time *binary*.

## References

- [`docs/security.md` — Empirical timing verification](../security.md#empirical-timing-verification)
- [`docs/risks.md` — What works against it](../risks.md#what-works-against-it)
- [`docs/security-review-v1.md` — Finding H-2](../security-review-v1.md)
- [`docs/timing-verification-runbook.md`](../timing-verification-runbook.md)
- Reparaz, Balasch, Verbauwhede (2017), *dudect: dynamic detection of constant-time code*.
- Brumley, Boneh (2005), *Remote timing attacks are practical*.
