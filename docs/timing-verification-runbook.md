# Timing verification runbook (bare-metal)

This is a checklist for re-running the **statistical** constant-time verification
(`dudect` / Welch's t-test) on a quiet, isolated machine. It exists because the
cloud/CI environment where the automated security review runs is a shared VM, and
shared VMs are the wrong place to make a *timing* claim.

## Why this can't be trusted in the cloud

The `ctgrind` / valgrind secret-poisoning check (run in CI) is **deterministic**:
it flags any machine instruction that branches or addresses memory based on a
secret, regardless of how noisy the host is. That result is trustworthy anywhere.

The `dudect` check is **statistical**: it runs the operation tens of thousands of
times on two input classes and asks whether the timing distributions differ
(|t| < 4.5 ⇒ no detectable leak). On a shared VM, three things corrupt that
measurement:

- **Neighbour noise** — other tenants' load perturbs your timings unpredictably,
  inflating variance. This can *hide* a real leak (false pass) or *invent* one
  (false fail).
- **Frequency scaling / turbo** — the CPU changing clock mid-run adds timing
  variation uncorrelated with the secret, again polluting the t-statistic.
- **No `rdtsc`/PMU stability guarantees** — the cycle counter may be virtualised.

So: treat the cloud `dudect` numbers as a smoke test, and treat the bare-metal
run below as the number you actually cite for v1.

## What you need

- A physical Linux x86_64 machine you control (not a VM, not a laptop on battery).
- Root (for the CPU-pinning / frequency steps).
- The repo checked out and the C extension compiling (`bundle exec rake compile`).

## Procedure

### 1. Quiet the machine

```bash
# Close everything noisy: browsers, Docker, syncthing, indexers, etc.
# Disable turbo so the clock can't change mid-measurement:
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo        # Intel
# (AMD: echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost)

# Pin every core to a fixed governor:
sudo cpupower frequency-set -g performance

# Optional but best: isolate a core at boot (add to kernel cmdline) and run on it.
#   isolcpus=3 nohz_full=3 rcu_nocbs=3
# Then run the harness pinned to that core with `taskset -c 3 ...`.
```

### 2. Run the deterministic check first (it's the foundation)

```bash
cd timing
# ctgrind/valgrind secret-poisoning — must exit 0 with no
# "Conditional jump or move depends on uninitialised value" on a secret.
# (The exact target is in the security-review harnesses; see Reproducibility
#  in docs/security-review-v1.md.)
```

If this fails anywhere, stop — a deterministic secret-dependent branch is a real
leak and no amount of statistical massaging changes that. Fix it first.

### 3. Run dudect, pinned, for a long time

```bash
cd timing
make clean && make
# Pin to the isolated core and let it accumulate measurements. Longer = tighter
# bound. Run each at least a few minutes; ideally until |t| stabilises.
taskset -c 3 ./timing_harness
```

Record the |t| for each measured op (`fred`, `fsub`, `fneg`, `fadd`,
`scalar_multiply_ct`, and any others the harness covers).

### 4. Interpret

- **|t| < 4.5** across a long run ⇒ no timing leak detectable at this sample size.
  This is the pass condition the project already uses.
- **|t| ≥ 4.5** ⇒ investigate. First rule out measurement artefacts: re-run,
  confirm the machine is quiet, confirm turbo is off. A *persistent*,
  reproducible high |t| that survives a quiet bare-metal run is a real finding —
  triage it per the "Security findings" process in `CLAUDE.md`.
- Note the known marginal artefact already documented in `risks.md`
  (`jp_add_internal` isolation, |t| ≈ 7.5 from operand-value microarchitectural
  variation, not a branch) — don't re-flag that as new.

### 5. Record it

Capture the machine (CPU model, microcode, kernel), the run duration, the sample
count, and the final |t| per op. Drop those numbers into `risks.md` /
`security-review-v1.md` so the v1 timing claim is backed by a reproducible,
quiet-hardware measurement rather than a cloud smoke test.

## One-line summary

The cloud run tells you **whether the code has a secret-dependent branch**
(deterministic, trustworthy anywhere). The bare-metal run tells you **whether the
compiled timing is actually flat** (statistical, only trustworthy on quiet
hardware). v1 wants both, and only step 3–5 here need your workstation.
