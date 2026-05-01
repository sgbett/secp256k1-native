# Evaluating the risks

This gem implements secp256k1 elliptic curve cryptography from scratch in Ruby and C. Before using it, you should understand what that means.

## "Don't roll your own crypto"

This is among the most frequently repeated maxims in software security. It originates from Schneier's (1998) observation that anyone can design a cipher they themselves cannot break — the hard part is designing one that nobody else can break either. The phrase has since expanded well beyond algorithm design to cover a spectrum of activities:

1. **Designing novel algorithms** — inventing new ciphers, hash functions, or protocols
2. **Implementing known algorithms from published specifications** — writing code that performs a well-understood mathematical operation
3. **Selecting algorithms and parameters** — choosing which cipher, key size, or mode to use
4. **Using library APIs** — calling existing cryptographic libraries correctly
5. **Composing cryptographic protocols** — assembling primitives into higher-level constructions

The evidence base supporting the maxim varies dramatically across these activities. Algorithm design has strong expert consensus against amateur attempts. API usage has extensive empirical data showing that most failures occur here. But custom implementation of known algorithms from specifications — activity (2), which is what this gem does — has almost no direct empirical data. No peer-reviewed study compares outcomes between custom and library-based implementations of the same algorithm.

This does not mean custom implementation is safe. It means the conventional wisdom rests on inference rather than measurement, and that inference is worth examining.

## What the evidence actually shows

The empirical literature on cryptographic software failures tells a more nuanced story than the maxim alone suggests. The findings below are drawn from peer-reviewed research; a full review with methodology and citations is available in Bettison (2026).

### Most failures are misuse, not primitive bugs

Three independent research programmes — Lazar et al. (2014) analysing CVEs, Egele et al. (2013) analysing Android applications, and Muslukhov et al. (2018) using source attribution — converge on the same finding: the dominant source of cryptographic failure is not bugs in the primitives but errors in how surrounding code uses them. Lazar et al. found that 83% of cryptographic CVEs were application-level misuse of libraries, with only 17% in the primitives or libraries themselves.

This finding cuts both ways. It means the majority of cryptographic risk lies outside the scope of what "rolling your own" addresses — the surrounding application code that handles keys, certificates, randomness, and protocol logic. Whether you use a library or a custom implementation, the dominant failure mode is the same.

### Within libraries, memory safety dominates

When failures do occur within cryptographic libraries themselves, the plurality are not cryptographic errors. Blessing, Specter, and Weitzner (2024), examining 312 CVEs across eight major open-source cryptographic libraries, found that approximately 37% were memory safety issues compared to approximately 27% that were cryptographic in nature. However, all eight libraries studied were written in C or C++. A cryptographic library written in a memory-safe language would eliminate the largest single class of vulnerability found in these libraries.

Ruby is a memory-safe language. This gem's pure-Ruby implementation is not susceptible to buffer overflows, use-after-free errors, or the other memory safety vulnerabilities that constitute the plurality of bugs in existing C/C++ cryptographic libraries. The C extension reintroduces this risk surface for the 16 accelerated functions, but the attack surface is substantially smaller than a full C library — approximately 1,200 lines of C implementing fixed-width arithmetic with no dynamic memory allocation.

### Hand-written cryptographic arithmetic is error-prone

The evidence documents a class of bugs in cryptographic arithmetic that are subtle, long-lived, and resistant to conventional testing. Steinbach, Grossschadl, and Ronne (2025) catalogue 53 real hard-to-find bugs from open-source cryptographic projects, including carry-propagation flaws, mismanagement of state, and timing vulnerabilities. A carry-propagation bug in OpenSSL's Karatsuba squaring persisted for 10 years. Erbsen et al. (2020) surveyed 26 bugs in hand-written implementations, including carry-handling errors and elliptic curve point validation errors. Mouha and Celi (2023) documented a buffer overflow in the SHA-3 reference implementation that went undetected for 11 years despite public scrutiny.

These bugs appear in expert-written, extensively reviewed code — in OpenSSL, in Go's standard library, in NIST reference implementations. A custom implementation without comparable review infrastructure should expect to face the same classes of risk, arguably with higher probability.

### Side-channel attacks are practical, but verification is confined to compiled code

Timing attacks on cryptographic implementations are practical over networks. Brumley and Boneh (2005) extracted a 1024-bit RSA private key from an OpenSSL server with approximately 1.4 million queries. The defensive engineering response — constant-time programming discipline — requires that execution time, memory access patterns, and branching behaviour are all independent of secret values.

A critical gap runs through the side-channel evidence: every verification tool (ct-verif, Binsec/Rel, ct-grind, MicroWalk, dudect) operates on compiled code — LLVM IR, x86 assembly, or native binaries. No source in the evidence base addresses constant-time guarantees in interpreted or JIT-compiled languages such as Ruby. For a full custom implementation in an interpreted language, the entire cryptographic computation is subject to interpreter-introduced variability across all three side-channel dimensions: execution timing, cache behaviour, and memory access patterns.

This is not a gap in tooling — it is a gap in the evidence about what side-channel resistance even means in environments where the runtime, garbage collector, and JIT compiler introduce timing variability outside the programmer's control.

### Formal verification works but remains inaccessible

Formally verified cryptographic implementations have reached production deployment. HACL\* primitives are integrated into Firefox's NSS library. Fiat-Crypto generates verified field arithmetic adopted by BoringSSL (which handles about half of HTTPS connections worldwide). EveryCrypt's analysis of 24 OpenSSL CVEs found that 23 of 24 would have been prevented by their verification methodology.

However, all of these achievements come from world-class formal methods groups (Inria, Microsoft Research, MIT, MPI, Galois). No source evaluates whether non-specialist teams can produce verified cryptographic code. The gap between "verification is possible" and "verification is accessible" is acknowledged but not measured.

### Supply chain risk is real but asymmetric

The dependency model carries documented risks: upstream vulnerabilities (Heartbleed affected 24-55% of HTTPS servers), maintainer compromise (the XZ Utils attack was a 2.6-year social engineering campaign), ecosystem monoculture, and chronic underfunding (at the time of Heartbleed, OpenSSL had one full-time developer and never received more than $2,000 in annual donations).

Custom implementation eliminates these specific risks but introduces different ones: reliance on a single maintainer's expertise, loss of access to community-discovered bug reports, and forgoing the test infrastructure that accumulates around established libraries. The evidence base does not establish that one set of risks is greater than the other — expert consensus favours library use for most contexts, but no source empirically compares the magnitude of the two risk vectors.

## Where this implementation sits

Given the evidence above, here is an honest assessment of where this gem's specific characteristics intersect with the known risk factors.

### What works in this gem's favour

**Memory-safe language.** The pure-Ruby implementation eliminates the largest single class of vulnerability (~37%) found in existing C/C++ cryptographic libraries. This is directly relevant: the Blessing, Specter, and Weitzner data documents what happens in C/C++; Ruby is not susceptible to those failure modes.

**Narrow scope.** This gem implements elliptic curve primitives only — field arithmetic, scalar arithmetic, point operations, and scalar multiplication. It does not implement ECDSA, Schnorr signatures, key derivation, or any protocol-level constructions. The smaller the codebase, the less there is to go wrong. The correlation between code complexity and vulnerability rate is empirically supported (Blessing, Specter, and Weitzner, 2024).

**Known algorithm, not novel design.** The secp256k1 curve parameters and operations are standardised and well-understood. This is activity (2) in the taxonomy — implementing from a specification — not activity (1). No novel cryptographic design decisions are made.

**Comprehensive test vectors.** The implementation is validated against 474 Wycheproof ECDSA test cases and field/scalar/point compliance vectors. Known-answer testing cannot find all bugs, but it establishes basic functional correctness.

**No external dependencies.** No libsecp256k1, no OpenSSL EC, no FFI bindings. `gem install` is the only setup step. This eliminates the supply chain risks documented in the evidence — at the cost of accepting the implementation risks.

### What works against it

**Hard-to-find bugs.** The evidence shows that hand-written cryptographic arithmetic is error-prone regardless of the implementer's expertise. Carry-propagation errors, canonicalisation failures, and point validation bugs appear in OpenSSL, Go's standard library, and independent implementations alike. This gem faces these risks without the accumulated fuzzing infrastructure, known-answer test suites, and community review that established libraries build over years.

**Side-channel leakage in pure-Ruby mode.** The pure-Ruby Montgomery ladder is algorithmically constant-time (fixed 256 iterations, no scalar-dependent branches), but Ruby's interpreter introduces timing variability through garbage collection, bignum arithmetic, and cache behaviour. No existing tool can verify side-channel resistance in interpreted code. The C extension provides genuine constant-time field arithmetic and branchless `cswap` for the Montgomery ladder — but only when compiled and loaded. To prevent silent degradation, `mul_ct` raises `InsecureOperationError` when the C extension is not loaded, requiring an explicit opt-in to pure-Ruby mode (see [security](security.md#pure-ruby-safety-guard)).

**Single maintainer, limited review.** Established libraries accumulate bug reports, security audits, and community scrutiny over years. This gem has none of that infrastructure. The same structural vulnerability that the XZ Utils case identifies as systemic for libraries — single-maintainer risk — applies here too.

**No formal verification.** The formal verification tools that have reached production (HACL\*, Fiat-Crypto, EveryCrypt) do not target Ruby or this C extension. This gem cannot be formally verified using existing tooling, and must rely on testing methodologies that the evidence shows are insufficient to catch the most dangerous classes of bugs.

**Empirical constant-time verification.** The C extension's constant-time properties are empirically tested using a dudect-based timing harness (Welch's t-test, |t| < 4.5 threshold). Field arithmetic operations (`fred`, `fsub`, `fneg`, `fadd`) pass — their branchless conditional selection produces no detectable timing variation across 1.5 million measurements per function. The Montgomery ladder (`scalar_multiply_ct_internal`) passes at 10,000 measurements (|t| = 1.0). An earlier version had a measured timing leakage (|t| = 875) caused by early-return branches in `jp_add_internal` on `uint256_is_zero(&p[2])` (infinity checks). Inside the ladder, the accumulators start at infinity (Z=0), and how quickly they escaped this state depended on the scalar's bit pattern — undoing the constant-time property that the branchless `cswap` provided. The fix replaced branching `jp_add_internal` with a fully branchless implementation using mask-based `uint256_select` for all input-dependent special cases (infinity, equal points, negated points). The leakage was found by dudect, the root cause identified by code inspection, and the fix verified by dudect — a concrete demonstration of Principle 2 (empirical over inspected).

## When to use this gem

You need secp256k1 primitives in Ruby and:

- You want a self-contained gem with no system library dependencies
- You value an auditable, readable implementation over battle-tested opacity
- You're building on a memory-safe stack and accept the trade-off of implementation risk for reduced dependency risk
- You understand that the C extension should be used for any secret-scalar operations
- You have evaluated the risks above against your specific threat model

## When not to use this gem

- You need formally verified cryptographic primitives
- Your threat model includes sophisticated side-channel attackers and you cannot use the C extension
- You would be more comfortable with a binding to libsecp256k1, which has been battle-tested across the Bitcoin ecosystem
- You are not in a position to evaluate the trade-offs described above

## References

- Bettison, S. G. (Apr. 2026). “Cryptographic Implementation Security: A Review of the
Empirical Evidence”. [DOI: 10.13140/RG.2.2.25788.60802](https://doi.org/10.13140/RG.2.2.25788.60802).
