# Plan — Reproducible timing-verification reference machine (NixOS)

Follow-on to **#25** (bare-metal dudect verification), tracked as **[HLR] #61**.

Codify the "quiet bare-metal box" that the dudect **pre-tag release gate**
([`security.md`](../docs/security.md#empirical-timing-verification),
[`timing-verification-runbook.md`](../docs/timing-verification-runbook.md)) runs
on, as declarative NixOS config that lives in this repo. The motivation is the
#25 finding itself: the leak was a `(source, compiler, flags)` artifact, so the
gate's value depends on **pinning** the compiler and **quieting** the machine
reproducibly — exactly what Nix is for. The config files double as the
documentation (drift-proof embeds), per the repo's existing
docs-as-source-of-truth habit.

> Context this plan is picked up from: #25 was verified on a *throwaway Ubuntu
> live install* (live GNOME session, **no core isolation**), where individual
> dudect runs spiked above |t|=4.5 from desktop noise even though the aggregate
> and ctgrind were clean. This plan replaces that with a dedicated, isolated,
> reproducible box.

## Core idea — two layers, two jobs

| Layer | Pins | Job |
|---|---|---|
| **`flake.nix` devShell** (`flake.lock`) | gcc / libc / valgrind / ruby / make | Reproducible **toolchain**. The `flake.lock` nixpkgs revision *is* the "known-good compiler" record. Bumping it is the deliberate trigger to re-run the gate. |
| **`nix/reference-machine.nix`** (NixOS module) | kernel cmdline, governor, boost/SMT, core isolation | Reproducible **quiet machine**. Replaces the manual `echo`/`cpupower`/`taskset` dance with `nixos-rebuild switch`. |

**Non-obvious correctness rule (must be loud in the docs):** build **and**
measure inside `nix develop` (or via the gate app). Otherwise you pin one GCC in
the flake and silently measure the system's *other* GCC — defeating the whole
exercise. Nix pins the software (compiler/libc/valgrind/kernel); the gate run
still stamps the *hardware* facts (CPU model, microcode) because those are
physical, not in the closure.

## Repo layout (all additive — zero impact on `gem install` / `bundle`)

```
flake.nix                    # devShell + apps.timing-gate + nixosModules.reference-machine
flake.lock                   # THE pinned-compiler record (version-controlled)
nix/
  reference-machine.nix      # parameterized NixOS module (isolated core, AMD/Intel boost path)
  configuration.example.nix  # how a host imports the module
docs/reference-machine.md    # philosophy + embedded annotated config + bump→re-run workflow
```

## Phase 1 — Reproducible toolchain (`flake.nix` devShell + `flake.lock`)

```nix
{
  description = "secp256k1-native — reproducible timing toolchain & reference machine";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";   # exact rev pinned by flake.lock
  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      toolchain = with pkgs; [ ruby_3_3 bundler gcc gnumake valgrind cpupower util-linux ];
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = toolchain;
        shellHook = ''export BUNDLE_PATH="$PWD/.bundle"
                      echo "timing toolchain: $(gcc --version | head -1)"'';
      };
      nixosModules.reference-machine = import ./nix/reference-machine.nix;
      # apps.timing-gate added in Phase 3
    };
}
```

**Validate (inside `nix develop`):** `bundle exec rake compile && bundle exec
rspec`; `cd timing && make`; `cd security && make ctgrind`. Deliverable: the
compiler is now pinned and the whole measurement is reproducible.

## Phase 2 — Quiet-machine module (`nix/reference-machine.nix`)

Parameterized so it isn't hardcoded to the #25 box:

```nix
{ config, lib, pkgs, ... }:
let cfg = config.timing.referenceMachine; in {
  options.timing.referenceMachine = {
    enable      = lib.mkEnableOption "secp256k1-native dudect reference machine";
    isolatedCpu = lib.mkOption { type = lib.types.int;  default = 15; };
    cpuVendor   = lib.mkOption { type = lib.types.enum [ "amd" "intel" ]; default = "amd"; };
  };
  config = lib.mkIf cfg.enable {
    boot.kernelParams = [          # core isolation — the biggest upgrade over the live box
      "isolcpus=${toString cfg.isolatedCpu}"
      "nohz_full=${toString cfg.isolatedCpu}"
      "rcu_nocbs=${toString cfg.isolatedCpu}"
      "nosmt"
    ];
    powerManagement.cpuFreqGovernor = "performance";
    systemd.services.timing-pin-frequency = {       # boost off + per-core min=max at boot
      wantedBy = [ "multi-user.target" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        ${if cfg.cpuVendor == "amd"
            then "echo 0 > /sys/devices/system/cpu/cpufreq/boost"
            else "echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo"}
        for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
          cat "$c/scaling_max_freq" > "$c/scaling_min_freq"; done
      '';
    };
    services.xserver.enable = false;     # text boot (multi-user.target) — no desktop noise
    services.openssh.enable = true;
  };
}
```

`nix/configuration.example.nix` imports `nixosModules.reference-machine`, sets
`timing.referenceMachine.enable = true;` and the host's hardware specifics.
**Validate on the real box:** `nixos-rebuild build`, then `switch`; confirm
`cat /sys/devices/system/cpu/isolated` shows the core, governor is `performance`,
`boost` is `0`, SMT off.

## Phase 3 — The gate as a command (`nix run .#timing-gate`)

A `pkgs.writeShellScript` wired as `apps.timing-gate`. Encodes the **documented
pass criteria** (not a flaky single run):

1. `rake compile && rspec` — functional gate (hard fail).
2. `make ctgrind && valgrind --error-exitcode=1 ./ctgrind_harness` — deterministic
   CT gate (**hard fail** on any secret-dependent branch).
3. `cd timing && make`; run **N=20** passes `taskset -c $ISOLCPU chrt -f 99
   ./timing_harness`, parse the `dudect:` lines, aggregate per op
   (mean|t|, max|t|, count > 4.5).
4. **PASS criteria** (operationalizes the triage already in `security.md`):
   `scalar_multiply_ct` + `scalar_*` must be **0/N over 4.5**; the
   `fred`/`jp_add` operand-value artefacts are allowed marginal single-run
   excursions but flagged if their *aggregate mean* exceeds a higher bound.
5. **Provenance stamp** → write a run record (`timing/runs/<date>.md`): CPU model
   + microcode (`/proc/cpuinfo`), kernel (`uname -r`), `gcc --version` (from the
   pinned shell), nixpkgs rev (`nix flake metadata`). Exit non-zero ⇒ real leak.

This *is* the pre-tag gate, runnable and reproducible.

## Phase 4 — Make the config integral to the docs

- Add `pymdownx.snippets` to `mkdocs.yml` `markdown_extensions` (currently absent;
  Material supports it). Enables `--8<--` file embeds.
- New `docs/reference-machine.md`: philosophy, the bump→re-run workflow, and the
  **real** `flake.nix` / `reference-machine.nix` **embedded** via snippets so docs
  cannot drift from the files.
- Cross-link: `timing-verification-runbook.md` points here as the canonical
  reproducible setup and **keeps its manual steps as the "without Nix" fallback**;
  `security.md`'s gate section references the pinned-toolchain flake.
- `mkdocs.yml` nav entry; CHANGELOG.

## Phase 5 — Validate on the real NixOS box (when it exists)

`nixos-rebuild build` → `switch`; `nix flake check`; `nix develop`; `nix run
.#timing-gate`. Expect **tighter |t|** than #25's numbers (the isolated core kills
the desktop-noise single-run spikes — e.g. the `scalar_mul` 8.02 transient seen
this session). Update the `security.md` table with the isolated-core figures and
their provenance stamp.

## Phase 6 (optional, later) — CI unification

Expose the **deterministic** gates (rspec, ctgrind, ASan, dfuzz) as flake
`checks` so GitHub Actions runs them reproducibly via `nix flake check`; dudect
stays bare-metal-only (documented). One toolchain definition serves both CI and
the gate box.

## Decisions (recommendations in **bold**)

- Root `flake.nix` (doubles as a contributor `nix develop` dev env) — **yes**, additive.
- Scope now: **Phases 1–4**; 5 when the box is up; 6 later.
- Embed real files in docs via snippets — **yes** (drift-proof; matches the "config integral to docs" intent).
- Pin via flake lockfile (not channels) — **yes** (the lockfile is the gate's compiler record).
- Issue: filed as **[HLR] #61** (follow-on to #25); this plan renumbered to match.

## Risks / caveats

- **Can't fully verify until the NixOS box exists.** Author + syntax-check now;
  `nixos-rebuild`/`isolcpus`/governor only prove out on the real install.
- **Nix's gcc wrapper injects its own hardening flags** (as Ubuntu's did:
  `-fstack-protector`, `-D_FORTIFY_SOURCE`, …). Phase 5 must check the in-shell
  `-O2` codegen/flags match what users actually ship, so we certify the real
  binary, not a Nix-specific one.
- **`isolcpus` is semi-deprecated** in favour of cpuset cgroups, but is the
  simplest robust choice for a single-purpose appliance — note it in the doc.
- **Mitigations left at default** (mirror what users run); the differential |t|
  is unaffected by their absolute cost. Document the choice.
