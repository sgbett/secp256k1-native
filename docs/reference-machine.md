---
title: Reference machine
parent: Security Review (v1.0)
nav_order: 3
---

# Timing-verification reference machine (NixOS sweep-ISO)

This is the **reproducible, unattended** form of the [bare-metal timing runbook](timing-verification-runbook.md). The runbook is a manual checklist — `echo`/`cpupower`/`taskset` to quiet a machine, then run `dudect` by hand with whatever GCC happens to be installed. That is fine once, but the [`dudect` statistical pass is a required pre-tag release gate](security.md#empirical-timing-verification) — it is the check that caught the compiler-reconstructed leak recorded in [advisory 0001](advisories/0001-compiler-reconstructed-ct-branch.md) (issue #25), which source review and CI `ctgrind` both missed — and a gate that depends on hand-configuration and a single ambient compiler is not one you can trust release after release.

The reference machine fixes that by codifying the whole measurement environment as declarative Nix: **one bootable NixOS ISO that sweeps every target compiler in a single unattended boot**, run from a Ventoy USB stick on quiet bare metal. Drop the stick in, boot, walk away; come back to a provenance-stamped, per-compiler report.

> **Scope.** The plan of record with full design detail is [`plans/61-reference-machine-nix.md`](https://github.com/sgbett/secp256k1-native/blob/master/plans/61-reference-machine-nix.md) (tracked as HLR #61). This page is the operator- and reviewer-facing summary.

## Why one ISO sweeps every compiler

The #25 finding is that the leak was a `(source, compiler, flags)` artefact: GCC 14/15 at `-O2` reconstructed the branchless select into a secret-dependent branch, while GCC ≤13 did not. So the gate's value depends on **pinning the compilers** and testing across them, not just quieting the machine.

The insight that makes this one image rather than N: the quiet-machine state — core isolation, pinned frequency, boost and SMT off — is a **boot-level** property, whereas the compiler is a **userspace** property. A single boot can therefore sweep *every* `gccN`, exactly as the #25 bisection did across GCC 9.5–15.1 from one pinned `nixpkgs`. Rebooting per compiler buys nothing for measurement quality.

The ISO bakes the pinned `nixpkgs` (⇒ every `gccN`), the quiet-machine configuration, the harness, and a **specific source revision** — so it is a self-contained, reproducible certificate for one source revision across all compilers. Bumping the `flake.lock` `nixpkgs` revision is the deliberate trigger to re-run the gate.

## The one non-negotiable: vanilla `gcc -O2`

The gem ships as *source* and is compiled on each user's machine by their `gcc` at `-O2` (`extconf.rb` appends it). The reference machine must certify **that** binary. But NixOS builds everything through nixpkgs' `cc-wrapper`, which injects a hardening set. This is not hypothetical: measured on GCC 14.3.0, the nixos-25.05 default hardening (`… stackclashprotection stackprotector zerocallusedregs …`) *changes* the CT-function codegen —

| CT function | hardened | vanilla (`NIX_HARDENING_ENABLE=""`) |
|---|---|---|
| `scalar_multiply_ct_internal` | 80 insns | 73 insns |
| `jp_add_internal` | 347 insns | 323 insns |

— extra register-zeroing and stack probes. Both happen to stay branchless here, but a hardened build is **not** the binary a stock `gem install` produces, and in principle hardening could *mask* a branch a stock build would emit (a false pass). So the gate builds with hardening **off** (`NIX_HARDENING_ENABLE=""`, explicit `make CC=`), and proves the result two ways:

- **Assembly-invariant** — [`security/check-ct-assembly.rb`](https://github.com/sgbett/secp256k1-native/blob/master/security/check-ct-assembly.rb): no secret-dependent `je`/`jne`/`cmov` in the ladder or `jp_add_internal`.
- **Stock equivalence** — the invariant is run under both the pinned nix `gccN` *and* a stock distro `gccN` of the same major (`nix/stock-attest.sh`, in a `gcc:<major>` Debian container); both must pass. This is checked as an invariant-result rather than a byte-for-byte golden, because GCC *minor* bumps legitimately reshuffle instructions without changing the security property. For defence in depth against a stock gcc outlining a leak into a *new* symbol the two-symbol invariant wouldn't inspect, the stock build is *also* run through **whole-binary ctgrind**. This is a dev-time attestation (per toolchain bump); the per-boot ISO sweep certifies the nix side. Validated for nix 14.3.0 and stock gcc:15 (invariant + ctgrind).

## The unattended flow

1. Boot the box from the Ventoy stick → the quiet-machine state comes up (isolated core, pinned frequency, boost/SMT off, no network).
2. A systemd oneshot (`timing-gate.service`) runs the gate automatically — no login.
3. For each compiler in the set: `rake clobber` → build the extension at vanilla `-O2` with `gccN` → verify the compiler took + the assembly-invariant → `rspec` → `ctgrind` → `dudect` (N runs, pinned to the isolated core with `taskset`/`chrt`) → aggregate per operation.
4. A single provenance-stamped report (CPU + microcode, kernel, per-compiler `gcc --version`, `nixpkgs` rev, source rev, achieved frequency) is written **incrementally** to the Ventoy partition, so an unplanned power loss loses only the in-flight compiler.
5. `systemctl poweroff`.

**Pass criteria (fail-closed).** Every compiler that *builds* must pass; a leak on any building `gcc` reds the gate. The secret-scalar operations (`scalar_multiply_ct`, `scalar_*`) must be 0-over-4.5 across all runs; the operand-value-artefact operations (field ops, `jp_add`) tolerate marginal single-run excursions and are flagged only if the aggregate **mean** |t| exceeds its **per-tier bound** — the elevated ops (`jp_add`, `fsub`) get a wider mean bound than the near-flat field ops (`fadd`, `fred`, `fneg`), so a flat op can't regress up to the widest bound unnoticed — **calibrated per pinned toolchain** from the authoritative sweep (the per-run max is noisy for these fast ops, so it is only a loose backstop; the operand-value artefact is toolchain-dependent — `jp_add_internal` ≈ 7.5 on GCC 15.2, ~22 on GCC 15.1 — see [security.md](security.md#empirical-timing-verification) and issue #74). A compiler that fails to build is `SKIPPED`, not fatal — but an all-`SKIPPED` sweep is reported as *inconclusive*, never a clean pass.

## Build & test logistics

The ISO is `x86_64-linux`, so it cannot be built natively on an aarch64 Mac. In order of preference:

- **`nix build .#iso`** on any x86_64 Linux host → `result/iso/*.iso`.
- **Docker** (nix-in-Linux) from macOS — ISO assembly is squashfs + xorriso, **no KVM needed**. This is how the pipeline is validated:

```bash
docker run -d --name nix --platform linux/amd64 \
  -v "$PWD":/work -w /work nixos/nix:latest sleep infinity
# nested Docker needs the nix build sandbox relaxed:
docker exec nix bash -c 'printf "experimental-features = nix-command flakes\nsandbox = false\nfilter-syscalls = false\n" >> /etc/nix/nix.conf'
docker exec nix bash -lc 'cd /work && nix build .#iso'
```

- **`nix build .#linux-builder`** (nix-darwin VM backend) is the cleanest native-mac option once configured.

Iterate on the automation without an ISO using **`nix run .#timing-gate`** (the same gate, offline gems, run against your checkout) or, in `nix develop`, `bash nix/gate.sh`. **The measurement is only ever meaningful on quiet bare metal** — a VM or Docker run validates the *automation* (boot → sweep → report → halt), never the timing.

Deploy by copying the ISO to the Ventoy stick (`/Volumes/Ventoy`); results land back on the same stick, replug into any machine to read them.

## The configuration (drift-proof)

These are the *actual* files baked into the ISO, embedded here at docs-build time (`rake docs`) so they cannot drift from what ships.

### `flake.nix`

```nix
{% include reference-machine/flake.nix %}
```

### `nix/reference-machine.nix` — the quiet-machine module

```nix
{% include reference-machine/reference-machine.nix %}
```

### `nix/iso.nix` — the sweep-ISO

```nix
{% include reference-machine/iso.nix %}
```

### `nix/gate.sh` — the gate

```bash
{% include reference-machine/gate.sh %}
```

### `nix/vanilla-ext.sh` — the vanilla-`gcc` codegen certification

```bash
{% include reference-machine/vanilla-ext.sh %}
```

## Bump → re-run workflow

1. Update `inputs.nixpkgs.url` / `nix flake update` — this changes the pinned compiler set. `flake.lock` is the release's "known-good compilers" record.
2. Rebuild: `nix build .#iso`, copy to the Ventoy stick.
3. Boot the reference machine, let the sweep run, collect the report from the stick.
4. Update the [`security.md` timing table](security.md#empirical-timing-verification) with the per-compiler, provenance-stamped figures.

## Relationship to the manual runbook

The [bare-metal timing runbook](timing-verification-runbook.md) remains the **"without Nix" fallback** — the same measurement performed by hand on any quiet machine. The reference machine is the automated, pinned, multi-compiler version of exactly that procedure; use the runbook when you cannot boot the ISO, and the ISO when you can.
