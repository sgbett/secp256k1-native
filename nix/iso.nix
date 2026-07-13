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
{ config, lib, pkgs, modulesPath, refSource, gateGems, gccSet, gateTools, valgrindCFlags, ... }:

let
  isolatedCore = config.referenceMachine.isolatedCore;
  # Full paths to each compiler-under-test's gcc wrapper (the gate's CC list).
  compilerBins = lib.concatStringsSep " " (map (g: "${g}/bin/gcc") gccSet);
  # Source revision for the provenance report: the baked source is a store copy
  # with no .git, and `git` isn't in gateTools, so `git rev-parse` would yield
  # "unknown" on the ISO. Plumb it from the flake instead (rev when clean,
  # dirtyRev when the tree is dirty, else "unknown").
  srcRev = refSource.rev or refSource.dirtyRev or "unknown";
in
{
  # A minimal live ISO (installation-cd-minimal) as the base image.
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  # Turn on the quiet-machine boot state (isolcpus, freq pin, SMT off, …).
  # (It doesn't disable networking — the sweep service stops the network daemons
  # before measuring; see below.)
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
    # The ctgrind build needs <valgrind/memcheck.h> from valgrind's `dev` output,
    # which isn't on the default include path (see valgrindCFlags in flake.nix).
    # A systemd service gets a clean env, so set it here explicitly.
    environment.NIX_CFLAGS_COMPILE = valgrindCFlags;
    # gateTools already provides util-linux (mount/umount/blkid) and coreutils
    # (sync); no need to re-add them. Keep the PATH minimal (principle 3).
    path = gateTools;
    script = ''
      set -u
      # Power off only when we're sure the report is safe. If the operator
      # expected a USB report but it didn't persist (mount failed / read-only /
      # full), leave the box UP so the tmpfs copy can be recovered — an
      # unattended appliance that powers off having lost the evidence is worse
      # than one that waits.
      no_poweroff=""
      trap 'sync; umount /mnt 2>/dev/null || true; [ -n "$no_poweroff" ] || systemctl poweroff' EXIT
      warn() { echo "timing-gate: $*" | tee /dev/tty1 /dev/console 2>/dev/null || true; }

      # 0. Quiet: this is the UNATTENDED sweep, so stop the network + ssh daemons
      #    that the base image starts — DHCP/NTP/ssh activity is measurement noise.
      #    (The `debug` boot-menu entry skips the sweep and leaves them up for
      #    interactive SSH access instead.)
      systemctl stop sshd.service systemd-networkd.service systemd-timesyncd.service \
                     NetworkManager.service dhcpcd.service 'wpa_supplicant*' 2>/dev/null || true

      # 1. Writable copy of the baked source (store is read-only).
      work=/run/timing-gate/src
      rm -rf "$work"; mkdir -p "$work"
      cp -a /etc/secp256k1-native/source/. "$work/"
      chmod -R u+w "$work"
      cd "$work"

      # 2. Results sink: the Ventoy exFAT data partition (label "Ventoy"). No
      #    stick present ⇒ a bare VM run ⇒ tmpfs + poweroff is expected. Stick
      #    present but unmountable ⇒ operator error ⇒ tmpfs + STAY UP.
      stamp="$(date -u +%Y%m%d-%H%M%S)"
      out=/run/timing-gate/out-$stamp
      ventoy_expected=""
      if dev=$(blkid -L Ventoy 2>/dev/null); then
        ventoy_expected=1
        mkdir -p /mnt
        if mount "$dev" /mnt 2>/dev/null; then
          out=/mnt/secp256k1-timing-$stamp
        else
          warn "ERROR: Ventoy stick present but mount failed — results go to tmpfs; NOT powering off so they can be recovered."
          no_poweroff=1
        fi
      fi
      mkdir -p "$out"

      # 3. Run the sweep. Offline gems (GATE_RUBY_EXEC=""), pinned to the
      #    isolated core, results written incrementally to the stick.
      GATE_RUBY_EXEC="" \
      GATE_COMPILERS="${compilerBins}" \
      GATE_CORE="${toString isolatedCore}" \
      GATE_SOURCE_REV="${srcRev}" \
      GATE_OUT="$out" \
        bash nix/gate.sh
      gate_rc=$?

      # 4. Confirm the report actually landed before powering off. A Ventoy write
      #    can fail silently if the partition is read-only or full — verify the
      #    report exists and is non-empty on the intended sink; if not, stay up.
      sync
      if [ -n "$ventoy_expected" ] && [ -z "$no_poweroff" ] && [ ! -s "$out/timing-report.txt" ]; then
        warn "ERROR: expected the report on the Ventoy stick but $out/timing-report.txt is missing/empty (read-only or full?) — NOT powering off."
        no_poweroff=1
      fi

      # The EXIT trap syncs, unmounts, and (unless no_poweroff) powers off.
      # Exit with the gate's status (no `|| true`) so `systemctl status
      # timing-gate` / the journal reflect PASS/FAIL — a detected leak must not
      # read as a clean service success.
      exit "$gate_rc"
    '';
  };

  # --- Interactive debug boot entry (a specialisation ⇒ a second boot-menu
  # entry the nixpkgs ISO module generates for GRUB + isolinux). The ISO menu's
  # existing timeout auto-boots the default (unattended sweep); arrow to
  # "debug" + enter to get a networked shell instead. Build-time, so no runtime
  # tty-prompt fragility. Same quiet-machine kernel params (isolation stays on
  # so you can test its effect), but: the sweep does NOT run, networking + sshd
  # stay up, and the box does NOT power off — SSH in and drive `bash nix/gate.sh`
  # by hand, or tune sysfs and re-run.
  #
  # SSH access is KEY-ONLY (PermitRootLogin=prohibit-password): add your public
  # key(s) to nix/debug-ssh-authorized-keys and rebuild. Without a baked key,
  # log in on the autologin root console (grab the DHCP IP with `ip a`); to
  # enable SSH ad-hoc without a rebuild, append a key to
  # /root/.ssh/authorized_keys there. (Password SSH is off, so `passwd` only
  # helps the local console, not SSH.)
  specialisation.debug.configuration = {
    system.nixos.tags = [ "debug" ];
    # No unattended sweep on this entry.
    systemd.services.timing-gate.wantedBy = lib.mkForce [ ];
    # SSH in for interactive tuning.
    services.openssh = {
      enable = true;
      settings.PermitRootLogin = "prohibit-password"; # key-only root
    };
    users.users.root.openssh.authorizedKeys.keyFiles = [ ./debug-ssh-authorized-keys ];
    networking.hostName = lib.mkForce "secp256k1-debug";
    # Console hint. NB: the baked source is a READ-ONLY nix store copy, so the
    # gate (which clobbers + builds in-tree) must run from a WRITABLE copy.
    users.motd = ''
      secp256k1 reference machine — DEBUG boot: network + sshd up, sweep NOT run.
      Run the gate by hand from a writable copy of the read-only baked source:
        rm -rf /root/src && cp -aL /etc/secp256k1-native/source /root/src && chmod -R u+w /root/src && cd /root/src
        NIX_CFLAGS_COMPILE="${valgrindCFlags}" GATE_RUBY_EXEC="" GATE_CORE=${toString isolatedCore} GATE_OUT=/root/out bash nix/gate.sh
    '';
  };
}
