{
  description =
    "secp256k1-native — reproducible timing-verification toolchain & reference machine";

  # Pinned via flake.lock. The locked nixpkgs revision IS the gate's
  # "known-good compiler" record: bumping this input is the deliberate trigger
  # to re-run the bare-metal dudect gate (see plans/61-reference-machine-nix.md and
  # docs/security.md#empirical-timing-verification).
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Offline gem set for the on-ISO gate — rake (clobber), rake-compiler (the
      # Rakefile requires it), rspec. Baked via bundlerEnv from nix/reference-gems
      # (Gemfile + Gemfile.lock + gemset.nix; regen: bundle lock && bundix). Kept
      # minimal so the ISO closure and attack surface stay small (principle 3).
      gateGems = pkgs.bundlerEnv {
        name = "secp256k1-refmachine-gems";
        ruby = pkgs.ruby_3_3;
        gemdir = ./nix/reference-gems;
      };

      # Prototype compiler set — gcc15 (15.1.0), the family where advisory 0001
      # (#25) leaked. Widen backward (gcc14, gcc13, … best-effort) once the
      # prototype boots on bare metal (Phase 7): just add to this list.
      gccSet = [ pkgs.gcc15 ];

      # Runtime tools the gate needs, offline. gateGems provides rake/rspec;
      # ruby_3_3 provides `ruby` for extconf (bundlerEnv doesn't export it). The
      # coreutils/sed/grep/awk are the gate's text plumbing (a minimal ISO PATH
      # otherwise lacks them).
      gateTools = [ gateGems pkgs.ruby_3_3 pkgs.gnumake pkgs.binutils pkgs.valgrind pkgs.util-linux pkgs.bash pkgs.coreutils pkgs.gnused pkgs.gnugrep pkgs.gawk ] ++ gccSet;
    in
    {
      # Reproducible toolchain — `nix develop`.
      #
      # This shell both COMPILES and MEASURES the C extension, so the gem's
      # timing-sensitive codegen is reproducible. Important nuance: the
      # extension is built by Ruby's configured CC (RbConfig CC), printed by the
      # shellHook — pinning *that* compiler is what the gate certifies, not the
      # bare `gcc` on PATH. (Refinement for the real box: pin the CC explicitly,
      # e.g. to gcc15 to match where issue #25 was found.)
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          ruby_3_3
          bundler
          gcc # compiler under test
          gnumake # builds the timing/ and security/ harnesses
          binutils # objdump, for the disassembly branch-check
          valgrind # ctgrind deterministic constant-time gate
          util-linux # taskset / chrt for pinned dudect runs
          pkg-config # lets native gems (psych) locate libyaml
          libyaml # psych's C dependency — pulled in via yard-markdown -> rdoc
        ];

        shellHook = ''
          # Keep gem installs local and out of the git tree.
          export BUNDLE_PATH="$PWD/.bundle"
          echo "secp256k1-native timing toolchain (flake-pinned):"
          echo "  gcc      : $(gcc --version | head -1)"
          echo "  ruby     : $(ruby --version)"
          echo "  ext CC   : $(ruby -rrbconfig -e 'print RbConfig::CONFIG["CC"]')   <- compiles the C extension"
          echo "  valgrind : $(valgrind --version)"
        '';
      };

      packages.${system} = {
        # The offline gem environment (inspect with `nix build .#gate-gems`).
        gate-gems = gateGems;
        # The sweep-ISO — `nix build .#iso` → result/iso/*.iso.
        iso = self.nixosConfigurations.sweep.config.system.build.isoImage;
      };

      # `nix run .#timing-gate` — the gate with the pinned toolchain, run against
      # the current checkout ($PWD). Uses the offline gems (GATE_RUBY_EXEC="")
      # exactly as the ISO does, so dev iteration matches the appliance.
      apps.${system}.timing-gate = {
        type = "app";
        program = toString (pkgs.writeShellScript "timing-gate" ''
          export PATH=${pkgs.lib.makeBinPath gateTools}:$PATH
          export GATE_RUBY_EXEC=""
          exec ${pkgs.bash}/bin/bash nix/gate.sh "$@"
        '');
      };

      # The unattended sweep-ISO system.
      nixosConfigurations.sweep = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          refSource = self; # the flake source, baked into the image
          inherit gateGems gccSet gateTools;
        };
        modules = [
          ./nix/reference-machine.nix
          ./nix/iso.nix
        ];
      };
    };
}
