# nix/reference-machine.nix
#
# Quiet-machine NixOS module for the timing-verification reference machine
# (Phase 2 of plans/61-reference-machine-nix.md). Boot-level state that makes
# the dudect pre-tag gate reproducible: one isolated CPU core with no scheduler
# / IRQ / RCU noise, pinned frequency (no DVFS/turbo jitter), and SMT off.
# Imported by nix/iso.nix; also usable for a persistent box later.
#
# NB: this module does NOT disable networking — network *quiet during the
# measurement* is the sweep service's job (it stops the network daemons right
# before measuring; see nix/iso.nix), which lets the debug boot entry keep the
# network up for SSH without fighting an mkForce here.
#
# Why boot-level: the quiet state is a property of the kernel command line and
# early sysfs, NOT of userspace. That is exactly why one boot can sweep every
# target compiler (the plan's core idea) — the compiler is userspace, the quiet
# machine is the boot.
#
# mitigations= is deliberately LEFT AT THE KERNEL DEFAULT to mirror what users
# run; the *differential* |t| the gate measures is unaffected by the absolute
# cost of mitigations. Do not add `mitigations=off`.
{ config, lib, pkgs, ... }:

let
  cfg = config.referenceMachine;
in
{
  options.referenceMachine = {
    enable = lib.mkEnableOption "quiet-machine timing-verification boot state";

    isolatedCore = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 15;
      description = ''
        CPU core to isolate for pinned dudect runs. The gate pins its
        measurement process here (`taskset -c <isolatedCore> chrt -f 99 …`).
        Default 15 = the top core on a 16-thread box; override per machine.
      '';
    };

    housekeepingCores = lib.mkOption {
      type = lib.types.str;
      default = "0-14";
      example = "0-6";
      description = ''
        The cores that carry the OS load and hardware IRQs (everything except
        the isolated core), as an `irqaffinity=` CPU list. Must be the
        complement of isolatedCore for the isolation to hold.
      '';
    };

    cpuVendor = lib.mkOption {
      type = lib.types.enum [ "amd" "intel" ];
      default = "amd";
      description = "Selects the correct turbo/boost-disable sysfs knob.";
    };
  };

  config = lib.mkIf cfg.enable {
    # --- Boot-level isolation of the measurement core ------------------------
    boot.kernelParams = [
      # No scheduler load-balancing, no managed-IRQ steering, no unbound
      # workqueues on the isolated core.
      "isolcpus=domain,managed_irq,${toString cfg.isolatedCore}"
      # Tickless + RCU callbacks offloaded → no timer/RCU softirq jitter in the
      # measurement window.
      "nohz_full=${toString cfg.isolatedCore}"
      "rcu_nocbs=${toString cfg.isolatedCore}"
      # Steer all unbound IRQs onto the housekeeping cores.
      "irqaffinity=${cfg.housekeepingCores}"
      # SMT off: a sibling hyperthread sharing execution units is a first-order
      # source of timing variance.
      "nosmt"
    ];

    # --- Frequency pinning ---------------------------------------------------
    # Governor to performance so the isolated core does not scale down.
    powerManagement.cpuFreqGovernor = lib.mkForce "performance";

    # Lock min=max frequency and kill turbo/boost so DVFS transitions don't
    # perturb the measurement. Ordered before the gate so the sweep runs pinned;
    # the report stamps the achieved frequency so residual throttling is visible.
    systemd.services.reference-machine-freq-pin = {
      description = "Pin CPU frequency and disable turbo/boost for timing stability";
      wantedBy = [ "multi-user.target" ];
      before = [ "timing-gate.service" ];
      after = [ "sysinit.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.coreutils ];
      script = ''
        set -u
        # min=max on every policy so no core scales.
        for p in /sys/devices/system/cpu/cpufreq/policy*; do
          [ -r "$p/cpuinfo_max_freq" ] || continue
          max=$(cat "$p/cpuinfo_max_freq")
          echo "$max" > "$p/scaling_min_freq" 2>/dev/null || true
          echo "$max" > "$p/scaling_max_freq" 2>/dev/null || true
        done
      '' + lib.optionalString (cfg.cpuVendor == "amd") ''
        # AMD: global boost knob (acpi-cpufreq / amd-pstate).
        [ -w /sys/devices/system/cpu/cpufreq/boost ] && echo 0 > /sys/devices/system/cpu/cpufreq/boost || true
      '' + lib.optionalString (cfg.cpuVendor == "intel") ''
        # Intel: pstate turbo knob.
        [ -w /sys/devices/system/cpu/intel_pstate/no_turbo ] && echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo || true
      '';
    };

    # --- Network quiet is the SWEEP's job, not a hard module policy -----------
    # DHCP/NTP/etc. are measurement noise, so the sweep stops the network daemons
    # (incl. wpa_supplicant) right before it measures (see nix/iso.nix). This
    # module deliberately does NOT touch networking, so a `debug` boot
    # specialisation can leave it up for SSH without fighting an mkForce here.

    # --- Console-only + autologin fallback -----------------------------------
    # No display manager / X. Autologin root so an operator can intervene on the
    # live console if an unattended run needs poking.
    services.xserver.enable = lib.mkForce false;
    services.getty.autologinUser = lib.mkDefault "root";
  };
}
