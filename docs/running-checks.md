---
title: Running the checks
parent: Security Review (v1.0)
nav_order: 1
---

# Running the security checks (macOS / Docker)

The pre-v1.0 review ([`security-review-v1.md`](security-review-v1.md)) left four empirical checks behind. This page is the guide to re-running them off the cloud — in particular from a macOS workstation. The governing distinction is **deterministic vs statistical**:

| Check | Kind | Reproducible off bare metal? | How to run from a Mac |
|-------|------|------------------------------|-----------------------|
| Differential fuzz | deterministic (exact-match) | yes — platform-independent | native (clang) or Docker |
| ASan / UBSan sweep | deterministic (memory/UB) | yes — platform-independent | native (clang) or Docker |
| ctgrind secret-poisoning | deterministic (data-flow) | yes — platform-independent | **Docker** (valgrind has no native macOS support) |
| dudect timing | **statistical** (wall-clock) | **no — needs quiet bare metal** | not Docker — see the runbook |

The first three verify *data-flow facts* (does output match the reference? does a poisoned value reach a branch?), so a VM or container reproduces the cloud results exactly. dudect measures *cycle counts*; virtualization changes the counter and the noise floor and invalidates the t-test — so it is the one check Docker cannot stand in for. See [`timing-verification-runbook.md`](timing-verification-runbook.md) and issue #25.

## Option A — Docker (recommended; covers all three deterministic gates)

Docker is the cleanest path from macOS because it runs the three deterministic gates exactly as the review did, **including ctgrind** — valgrind does not run natively on macOS, but it does support arm64 Linux, so a native container runs it un-emulated.

```sh
# from the repo root
# Apple Silicon: build/run natively so valgrind is NOT under qemu emulation.
docker build --platform linux/arm64 -f security/Dockerfile -t secp-review .
docker run --rm --platform linux/arm64 secp-review

# Intel Mac / Linux: omit --platform (amd64 is native).
docker build -f security/Dockerfile -t secp-review .
docker run --rm secp-review
```

The container runs `security/run-checks.sh`, which builds and runs all three and prints PASS/FAIL. On the reviewed tree expect: differential **PASS**, ASan/UBSan **PASS**, ctgrind **KNOWN** (it reports the I-11 `scalar_reduce_limbs` branches until #21 lands — *not* a failure). Crank coverage with `-e ITERS=2000000`.

> **Apple Silicon caveat:** run the container **native arm64**, not `linux/amd64` under qemu. valgrind works on arm64 Linux but not when it is itself being emulated by qemu — an amd64 image on an M-series Mac will make the ctgrind gate hang or misreport. The differential and ASan gates work either way (amd64-under-qemu is just slower).

## Option B — Native macOS (differential + ASan only)

The differential fuzzer and the ASan/UBSan sweep build with clang and run natively. ctgrind does not (no native valgrind) — use Docker for that gate.

```sh
cd security
make dfuzz   && python3 dfuzz_ref.py            # differential
make asan    && UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 ./asan_sweep
# make ctgrind / valgrind  -> not available natively on macOS; use Docker
```

The `security/Makefile` uses `cc` (clang on macOS) and `-fcommon`, both fine on Apple Silicon; `__uint128_t` is supported by clang on arm64.

## The Ruby test suite

Separate from the standalone harnesses, the gem's own suite runs natively on macOS with no special tooling:

```sh
bundle install
bundle exec rake compile        # builds lib/secp256k1_native.bundle on macOS (.so on Linux)
bundle exec rspec               # 416 examples
```

(The binstub-not-on-PATH and `-fcommon` quirks noted in the harness builds were specific to the review's CI container; a normal rbenv + bundler setup on macOS does not need them.)

## dudect timing (issue #25) — bare metal only

Do **not** run this in Docker or a VM. Follow [`timing-verification-runbook.md`](timing-verification-runbook.md) on a quiet, frequency-pinned physical machine, and record the |t| figures with hardware provenance. An Apple Silicon Mac can serve as the quiet machine, but the runbook's knobs (`intel_pstate`, `cpupower`, `isolcpus`) are Linux/x86-specific — on macOS quiesce the machine, run on a performance core, and treat the numbers with the P/E-core caveat; a dedicated quiet Linux box remains the gold standard.
