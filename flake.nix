{
  description =
    "secp256k1-native — reproducible timing-verification toolchain & reference machine";

  # Pinned via flake.lock. The locked nixpkgs revision IS the gate's
  # "known-good compiler" record: bumping this input is the deliberate trigger
  # to re-run the bare-metal dudect gate (see plans/reference-machine-nix.md and
  # docs/security.md#empirical-timing-verification).
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
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
    };
}
