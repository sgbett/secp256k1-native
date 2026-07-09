# Plan — Reproducible timing-verification reference machine (single sweep-ISO)

Follow-on to **#25** (bare-metal dudect verification), tracked as **[HLR] #61**.

Codify the "quiet bare-metal box" that runs the dudect **pre-tag release gate** ([`security.md`](../docs/security.md#empirical-timing-verification), [`timing-verification-runbook.md`](../docs/timing-verification-runbook.md)) as declarative Nix. The #25 finding is the motivation: the leak was a `(source, compiler, flags)` artefact, so the gate's value depends on **pinning the compilers** and **quieting the machine** reproducibly — exactly what Nix is for. The config files double as documentation (drift-proof embeds), per the repo's docs-as-source habit.

> Context: #25 was verified on a *throwaway Ubuntu live install* (live GNOME, **no core isolation**), where individual dudect runs spiked above |t|=4.5 from desktop noise even though the aggregate and ctgrind were clean. This plan replaces that with a single reproducible, isolated **appliance** that sweeps every target compiler unattended.

## Core idea — one sweep-ISO, unattended

The reference machine is **one bootable NixOS ISO** built from a pinned flake, run from a **Ventoy USB** on quiet bare metal. Because the quiet-machine state (`isolcpus`, governor, boost/SMT off) is a **boot-level** property and the compiler is a **userspace** property, a single boot can sweep *every* compiler — rebooting per gcc buys nothing for measurement quality. This is exactly what the #25 bisection already did (GCC 9.5–15.1 from one nixpkgs).

The ISO bakes: the pinned `nixpkgs` (⇒ every `gccN`), the quiet-machine config, the harness, and a **specific source revision**. So the ISO is a self-contained, reproducible **certificate for one source rev across all compilers**.

**Unattended flow (boot → report → halt):**
1. Boot the box from Ventoy → quiet-machine state comes up (isolated core, pinned freq).
2. A systemd oneshot (`timing-gate.service`) runs the gate automatically — no login.
3. Gate **loops the compiler set**; per gcc: clean → build the extension at vanilla `-O2` with `gccN` → verify the build actually used `gccN` + vanilla codegen → rspec → ctgrind → dudect (N runs, pinned) → stamp. A failing compiler is recorded and skipped, not fatal.
4. Aggregate a single provenance-stamped report; write it to the **Ventoy partition** (live copy to serial/console); then **poweroff**.
5. Drop USB, boot, walk away → come back to a per-compiler report on the stick.

## The one non-negotiable: vanilla `gcc -O2`, not nix-wrapped

**The single most important correctness requirement.** The gem ships as *source* and is compiled on each user's machine by their gcc at `-O2` (`extconf.rb` appends it). The reference machine must certify *that* binary. But NixOS builds everything through nixpkgs' cc-wrapper, which injects hardening flags (`-fstack-protector-strong`, `-D_FORTIFY_SOURCE`, …). If the ISO builds with the *wrapped* gcc, we certify a **nix-specific** binary — and worse, nix hardening could *mask* a branch a stock build would emit, giving a **false pass** while a stock user still leaks.

- **Requirement:** the CT-critical functions' `-O2` codegen must be **branchless** (no secret-dependent `je`/`jne`/`cmov`) and a **stock `gcc -O2`** build of the same major must be too — not necessarily byte-identical (gcc *minor* bumps legitimately reshuffle instructions), but equivalent in the security property.
- **Mechanism:** build via the nix `gccN` wrapper with hardening disabled (`NIX_HARDENING_ENABLE=""` / `hardeningDisable = ["all"]`) + `-O2`. **Confirmed empirically necessary** (Phase 3, gcc 14.3.0): the nixos-25.05 default `NIX_HARDENING_ENABLE` (`bindnow format fortify fortify3 pic relro stackclashprotection stackprotector strictoverflow zerocallusedregs`) *does* alter CT-function codegen — `scalar_multiply_ct_internal` 80 insns hardened vs 73 vanilla; `jp_add_internal` 347 vs 323 (benign register-zeroing + stack probes, both still branchless). So the hardened nix build is **not** the stock user's binary; disabling hardening is what makes them equivalent. With hardening off, the wrapper's residual `-B`/`-idirafter` paths don't touch the pure-arithmetic CT codegen.
- **Proof (two checks) — mechanism DONE (`nix/vanilla-ext.sh`, `nix/codegen-equivalence.sh`):**
  - **Invariant (reuse existing tooling):** run `security/check-ct-assembly.rb` + ctgrind on the nix-built binary per compiler — no secret-dependent `je`/`jne`/`cmov` at the CT lines.
  - **Equivalence (invariant-result, not byte golden):** run the assembly-invariant under *both* the pinned nix `gccN` and a **stock distro `gccN`** of the same major (stock reference built in a `gcc:<major>` Debian container); both must pass — "passing on nix ⇒ passing on stock". A byte golden was rejected as brittle across minors (a minor-driven codegen change is *signal*, investigated ad hoc). *Validated: nix gcc 14.3.0, stock gcc 14.4.0, stock gcc 15.3.0 all PASS.*
- **Also verify the CC actually took:** the extension is built by Ruby's mkmf/RbConfig CC — the gate must confirm each build really used the intended `gccN` (from the emit compile line / the binary), not silently fell back to the ISO's ruby default. (The Phase-1 shellHook already prints RbConfig CC for exactly this trap.)

## Repo layout (all additive — zero impact on `gem install` / `bundle`)
```
flake.nix        # devShell (Phase 1, done) + nixosConfigurations.sweep → the ISO + apps.timing-gate
flake.lock       # THE pinned nixpkgs — provides every gccN AND is the "known-good compilers" record
nix/
  reference-machine.nix   # quiet-machine module (isolcpus/irqaffinity/governor/boost/SMT, no-net, autologin)
  iso.nix                 # installation-cd-minimal → live ISO; bakes source; runs the gate as a service
  vanilla-ext.sh          # DONE — build the CT object at vanilla gcc -O2 (hardening off) + CC-took + assembly-invariant
  codegen-equivalence.sh  # DONE — dev-time attestation: invariant holds under nix gccN AND stock distro gccN (same major)
  gate.sh                 # the gate: loop gccN → build+verify+rspec+ctgrind+dudect+stamp → report → halt
docs/reference-machine.md # philosophy + build/test logistics + embedded config (Jekyll {% include %})
```

## Phases

### Phase 1 — Toolchain devShell (DONE, needs landing)
Committed `c6bd59a` on `feat/reference-machine-nix`, **unmerged**. Pins the toolchain (`ruby_3_3`, bundler, gcc, gnumake, **binutils**, valgrind, util-linux); `flake.lock` is the known-good record. shellHook prints the extension's real compiler (**RbConfig CC**). `nixosModules`/`apps` deliberately omitted until their files exist.
- **Land it:** cherry-pick onto master + **fix the stale comment** `plans/reference-machine-nix.md` → `plans/61-reference-machine-nix.md` (the #61 carried-forward TODO).

### Phase 2 — Quiet-machine module (`nix/reference-machine.nix`)
Boot-level state, parameterised (isolated core, AMD/Intel), shared by the ISO (and a persistent box later if ever wanted):
- `boot.kernelParams`: `isolcpus`/`nohz_full`/`rcu_nocbs` on the isolated core, `nosmt`, and **`irqaffinity=<housekeeping cores>`** to steer IRQs off the isolated core.
- `performance` governor, per-core min=max, boost/turbo off (AMD `cpufreq/boost=0`, Intel `no_turbo=1`).
- **No network** (source is baked, results go to USB — kills DHCP/NTP noise and surface), no X, minimal services, autologin as fallback.
- `mitigations=` left at **default** (mirror what users run) — documented.

### Phase 3 — Vanilla-`gcc` extension build (`nix/vanilla-ext.sh` + `nix/codegen-equivalence.sh`) — load-bearing — **DONE (mechanism), validated in devShell**
Implement the non-negotiable: build with `gccN` at vanilla `-O2` (hardening off), the CC-actually-took check (`.comment` major via `readelf`), the assembly-invariant check (reuse `security/check-ct-assembly.rb`), and the stock-equivalence attestation (invariant under nix `gccN` *and* stock distro `gccN`). Proven in the devShell *before* wrapping it in an ISO — the difference between certifying the real binary and a false pass. **Validated: nix gcc 14.3.0 + stock gcc 14.4.0/15.3.0 all branchless.** Wiring into the gate (build the gem with hardening off) and widening the nix compiler set beyond the pinned `gcc` is Phase 4/5.

### Phase 4 — The gate (`nix/gate.sh`, `apps.timing-gate`) — the automation core
One script, two contexts — the devShell (dev iteration) and the ISO service (the authoritative bare-metal run). Loops the compiler set; **per gcc**:
1. `rake clobber`; build vanilla `-O2` with `gccN`; verify CC + codegen (Phase 3).
2. `bundle exec rspec` — functional (records pass/fail).
3. `make ctgrind` + `valgrind --error-exitcode=1 ./ctgrind_harness` — deterministic CT.
4. `cd timing && make`; **N=20** `taskset -c $core chrt -f 99 ./timing_harness`; parse the per-op t-stats, aggregate (mean|t|, max|t|, count > 4.5).
- **Fault-tolerant:** a compiler that fails to build/deps is recorded `SKIPPED` with the error and the sweep continues (best-effort back to 9.5). **Per-step timeout** so nothing hangs the unattended run.
- **Pass criteria** (operationalizes `security.md`): `scalar_multiply_ct` + `scalar_*` = **0/N over 4.5**; `fred`/`jp_add` operand-value artefacts allowed marginal single-run excursions, flagged if aggregate mean exceeds a higher bound.
- **Report:** provenance (CPU + microcode, kernel, nixpkgs rev, source rev, achieved freq to catch throttling, timestamp) + per-compiler rows (build, CC-verified, codegen-equiv, rspec, ctgrind, dudect figures, verdict). **Written incrementally** — each compiler's row is flushed to the USB as it completes, so an unplanned power loss mid-sweep loses only the in-flight compiler, not the whole run.
- **Release semantics (fail-closed):** every compiler that *builds* must pass — a CT leak on any building gcc reds the gate (principle 1). A build/dep failure is `SKIPPED` (not a CT result, doesn't block). Any exotic-compiler exception is a deliberate triage call at the time, not a pre-baked exemption.

### Phase 5 — The sweep-ISO (`nix/iso.nix`) — prototype gcc15-only first
`nixosConfigurations.sweep` importing `reference-machine.nix` + `<nixpkgs/.../installation-cd-minimal.nix>` → `config.system.build.isoImage`. Source **baked in**. `timing-gate.service` (After freq-pin, no-network target) runs the gate, writes results **incrementally to the Ventoy exFAT partition** (mount by label `Ventoy`; serial + tty1 live copy), then a **graceful `systemctl poweroff`** (syncs + unmounts, so the USB write is safe; done even on failure — never hangs). `nix build .#iso`.
- **Prototype with a one-element set {gcc15}** (where #25 lives) — prove boot→build→measure→report→halt end-to-end, then widen the set.

### Phase 6 — Docs (Jekyll, drift-proof embed)
`docs/reference-machine.md`: philosophy, the **vanilla-gcc requirement**, the unattended flow, build/test logistics, bump→re-run workflow. **Embed the real config** via a `rake docs` step that copies `flake.nix`/`nix/*` into `docs/_includes/` + `{% include %}` — **Jekyll/just-the-docs, NOT mkdocs `pymdownx.snippets`** (site migrated, HLR #33). Cross-link `timing-verification-runbook.md` (keeps its manual steps as the "without Nix" fallback) + `security.md`; nav; CHANGELOG.

### Phase 7 — Validate, then widen the compiler set
- **Automation in a VM:** `nix build .#iso` + boot under QEMU to prove boot→sweep→report→halt plumbing (VM timing is meaningless — plumbing only).
- **Timing on bare metal:** Ventoy → boot the box → unattended sweep → collect the report (expect **tighter |t|** than #25's desktop-noise figures). Update the `security.md` table with the per-compiler, provenance-stamped figures.
- **Widen:** add gcc14, 13, … toward 9.5 to the set (one-line change). Best-effort — a gcc that fights the dep closure is recorded `SKIPPED`, not a blocker.

### Phase 8 (later, optional) — CI unification
Two layers, both on GitHub's **native x86_64** runners (which also sidestep the ctgrind-under-emulation flakiness seen validating this in Docker-on-aarch64 — valgrind runs natively there):
- **Cheap config guard, every PR:** `nix build --dry-run .#iso` (≈ `nix eval .#…iso.drvPath`) proves the whole `nixosConfiguration` still *evaluates* — catches module/option/lockfile breakage (the class hit during Phase 5) in ~1 min, no closure download.
- **Deterministic gate, reproducibly:** expose the deterministic checks (rspec, ctgrind, ASan, dfuzz, the codegen-equiv check) as flake `checks` for `nix flake check`, and/or **add a `GATE_SKIP_DUDECT` mode to `gate.sh`** — a small change; today `GATE_DUDECT_RUNS=0` fails closed (0 runs ⇒ no output ⇒ FAIL) rather than skipping — so CI can run the "dry run": build → vanilla-codegen-cert → rspec → ctgrind across the compiler set, **dudect skipped**. dudect stays bare-metal-only. One toolchain definition serves CI and the ISO.
- Optionally a heavier real `nix build .#iso` (needs nix-store caching — Cachix / magic-nix-cache) on release/nightly to prove the image actually assembles.

## Build & test logistics
- **Build (from macOS/aarch64):** the ISO is `x86_64-linux` — **can't build natively**. Best→fallback: nix **`linux-builder`** (nix-darwin VM backend, cleanest); a **Linux box** as remote builder; **Docker** (nix-in-linux) — ISO assembly is squashfs+xorriso, **no KVM needed**. `nix build .#iso` → `result/iso/*.iso`.
- **Size/runtime:** one ISO with every `gccN` closure is larger than one gcc but smaller than N separate ISOs (shared base dedupes); a full sweep is ~(build+rspec+ctgrind+20×dudect) × compilers — minutes each, so a multi-compiler run is a "leave it running" job. Fine: infrequent, per-release.
- **Deploy:** copy the ISO to the Ventoy stick (`/Volumes/Ventoy`).
- **Test split:** VM validates the **automation**; bare metal validates the **timing**. The measurement is **always bare metal — never Docker/VM**.

## Decisions (locked)
- **Single sweep-ISO**, gate loops the compiler set — **yes** (rebooting per gcc buys nothing; the quiet-machine is boot-level).
- **Unattended** boot→build→measure→report→**poweroff**, results to the Ventoy stick — **yes**.
- Certify **vanilla `gcc -O2`** (hardeningDisable + invariant + objdump-equivalence) — **hard requirement**.
- **Full gate (incl. dudect) per compiler**, fault-tolerant, best-effort back to 9.5 — **yes**.
- **Prototype gcc15** (one-element set), then widen — **yes**.
- Source **baked into the ISO**; docs **embed** the real config (Jekyll) — **yes**.
- Pin via `flake.lock` (one nixpkgs → all gccN) — **yes**.
- Results **written to the Ventoy USB stick**, incrementally (portable — replug into the dev Mac for analysis) — **yes**.
- **Fail-closed release gate:** every *building* compiler must pass; no pre-declared informational tier — exotic exceptions triaged ad hoc — **yes**.
- Isolated core defaults to the **top core (15)**, `irqaffinity=0-14`, parameterised — **yes**.

## Resolved / deferred-ad-hoc
- **Codegen equivalence:** stock `gcc -O2` golden per gcc *major*. A *minor* bump that changes CT codegen is treated as **signal** — investigated ad hoc if it arises; no pre-emptive work.
- **Release gate:** fail-closed (above) — no pre-declared compiler tiers.
- **Results sink:** the Ventoy USB stick, incrementally.
- **Isolated core / IRQ mask:** default core 15, `irqaffinity=0-14`, parameterised.
- **UPS integration (optional, later):** the box is on an APC SmartUPS 1500. Incremental writes already make a mid-sweep power loss cheap (only the in-flight compiler is lost) and runs are reproducible, so UPS-triggered shutdown buys little here. If ever wanted, wire `apcupsd`/NUT over **USB/serial** (not the network card — preserves the no-net hygiene) to halt cleanly on battery-low. Not now (YAGNI).

## Risks / caveats
- **Vanilla-gcc fidelity is the whole ballgame** — divergent codegen ⇒ we certify the wrong binary or get a false pass. Hence the objdump-equivalence diff is a first-class gate (Phase 3), not a footnote.
- **Can't fully verify until the box exists** — VM proves plumbing; `isolcpus`/governor/ boot-via-Ventoy/USB-write only prove out on a real boot. NixOS-ISO-on-Ventoy can have boot quirks — validate early.
- **Older gcc (9–12) may break the dep closure** — recorded `SKIPPED`, revisited, never blocks the prototype.
- **`isolcpus` semi-deprecated** (vs cpuset cgroups) but simplest for a single-purpose appliance — noted in the doc.
- **Thermal throttling** could perturb long sweeps despite pinned freq — the report stamps achieved frequency so throttling is detectable, not silent.
- **Unplanned mains loss mid-sweep** — mitigated by incremental per-compiler writes (only the in-flight compiler is lost) plus run reproducibility; the APC SmartUPS 1500 is a physical backstop. UPS-comms integration is optional/later (see above).
- **Mitigations left at default** (mirror users); the differential |t| is unaffected by their absolute cost.
