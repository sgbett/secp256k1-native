# nix/iso.nix
#
# The sweep-ISO (Phase 5 of plans/61-reference-machine-nix.md). A live NixOS ISO
# that, on boot, runs the timing gate unattended across the compiler set, writes
# a provenance-stamped report to the Ventoy USB stick, and powers off. Composed
# with installation-cd-minimal + the quiet-machine module (nix/reference-machine.nix)
# in flake.nix's nixosConfigurations.sweep.
#
# Prototype: gcc15 only (gccSet in flake.nix). Widen the set once it boots on
# bare metal (Phase 7). The measurement is meaningful ONLY on quiet bare metal —
# a VM/Docker run validates the boot→sweep→report→halt AUTOMATION, not timing.
{ config, lib, pkgs, modulesPath, refSource, gateGems, gccSet, gateTools, ... }:

let
  isolatedCore = config.referenceMachine.isolatedCore;
  # Full paths to each compiler-under-test's gcc wrapper (the gate's CC list).
  compilerBins = lib.concatStringsSep " " (map (g: "${g}/bin/gcc") gccSet);
in
{
  # A minimal live ISO (installation-cd-minimal) as the base image.
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  # Turn on the quiet-machine boot state (isolcpus, freq pin, no network, …).
  referenceMachine.enable = true;
  # referenceMachine.isolatedCore / .cpuVendor default to 15 / amd — override per
  # box here when the real hardware is known.

  # Smaller image + faster boot: the sweep is CPU/RAM only, no GUI.
  isoImage.isoName = lib.mkForce "secp256k1-timing-sweep.iso";

  # Bake the source (this flake's clean git tree) read-only into the store; the
  # gate copies it to a writable tmpfs before building.
  environment.etc."secp256k1-native/source".source = refSource;

  # Tools available on the live console too (for manual poking if a run wedges).
  environment.systemPackages = gateTools;

  # The unattended gate. Ordered after the frequency pin so the sweep runs on the
  # locked, isolated core; runs even with no network (source is baked).
  systemd.services.timing-gate = {
    description = "secp256k1-native unattended timing-verification sweep";
    wantedBy = [ "multi-user.target" ];
    after = [ "reference-machine-freq-pin.service" "local-fs.target" ];
    wants = [ "reference-machine-freq-pin.service" ];
    # The gate itself is fail-closed; the SERVICE must always reach poweroff so
    # an unattended box never hangs powered-on. Hence the trap + oneshot.
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "tty";
      StandardError = "tty";
      TTYPath = "/dev/tty1";
    };
    path = gateTools ++ [ pkgs.util-linux pkgs.e2fsprogs pkgs.mount ];
    script = ''
      set -u
      trap 'sync; umount /mnt 2>/dev/null || true; systemctl poweroff' EXIT

      # 1. Writable copy of the baked source (store is read-only).
      work=/run/timing-gate/src
      rm -rf "$work"; mkdir -p "$work"
      cp -a /etc/secp256k1-native/source/. "$work/"
      chmod -R u+w "$work"
      cd "$work"

      # 2. Results sink: the Ventoy exFAT data partition (label "Ventoy"). Fall
      #    back to the tmpfs if the stick isn't present (a bare VM run) — the
      #    report still prints to tty1/serial either way.
      stamp="$(date -u +%Y%m%d-%H%M%S)"
      out=/run/timing-gate/out-$stamp
      if dev=$(blkid -L Ventoy 2>/dev/null); then
        mkdir -p /mnt && mount "$dev" /mnt 2>/dev/null && out=/mnt/secp256k1-timing-$stamp
      fi
      mkdir -p "$out"

      # 3. Run the sweep. Offline gems (GATE_RUBY_EXEC=""), pinned to the
      #    isolated core, results written incrementally to the stick.
      GATE_RUBY_EXEC="" \
      GATE_COMPILERS="${compilerBins}" \
      GATE_CORE="${toString isolatedCore}" \
      GATE_OUT="$out" \
        bash nix/gate.sh || true

      # EXIT trap syncs, unmounts, powers off.
    '';
  };
}
