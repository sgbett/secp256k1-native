#!/usr/bin/env bash
#
# codegen-equivalence.sh — dev-time attestation that the CT-critical codegen is
# branchless under BOTH the pinned nix gcc and a STOCK distro gcc of the same
# major. This operationalises the reference machine's one non-negotiable
# (Phase 3 of plans/61-reference-machine-nix.md): certifying the nix-built
# binary must imply the stock `gem install` binary is also safe —
# "passing on nix ⇒ passing on stock".
#
# Equivalence as invariant-result, not a byte golden
# --------------------------------------------------
# The plan's first sketch was "objdump-diff the CT functions against a committed
# stock golden". In practice a byte-for-byte golden is brittle: gcc *minor*
# bumps legitimately reshuffle instructions without changing the security
# property, and the plan already classifies a minor-driven codegen change as
# "signal, investigated ad hoc". So the durable, low-noise equivalence check is:
# run the assembly-invariant (security/check-ct-assembly.rb — 0 secret-dependent
# branch/cmov in the ladder + jp_add_internal) under both toolchains and require
# BOTH to pass. That captures exactly the load-bearing claim and survives minor
# drift. nix/vanilla-ext.sh is the per-toolchain check; this script drives it
# across a compiler set.
#
# How the stock reference is produced
# -----------------------------------
# The stock leg is automated in `nix/stock-attest.sh`: it spins an official
# `gcc:<major>` Debian image (x86_64, so the codegen is the real thing) and runs
# BOTH the assembly-invariant AND whole-binary ctgrind against the stock build —
# ctgrind is symbol-agnostic, so it catches a secret branch a stock gcc might
# outline into a new symbol that the two-symbol invariant would miss.
#
#   nix/stock-attest.sh 14 15      # attest stock gcc:14 and gcc:15
#
# Attested results (nixos-25.05 pin, x86_64)
# ------------------------------------------
#   nix   gcc 14.3.0  : PASS
#   stock gcc 14.4.0  : PASS
#   stock gcc 15.3.0  : PASS   <- the family where advisory 0001 (#25) leaked
#                                 PRE-fix; branchless post-ct_value_barrier.
#
# Usage
# -----
#   nix/codegen-equivalence.sh                 # checks `gcc` on PATH
#   nix/codegen-equivalence.sh gcc gcc-15      # checks each CC on PATH
#   # or point it at pre-built objects to just re-run the invariant:
#   OBJECTS="tmp/jacobian.stock-gcc14.o tmp/jacobian.stock-gcc15.o" \
#     nix/codegen-equivalence.sh
#
# Exit codes: 0 all pass · 1 any fail · 2 environment/usage error
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKER="$ROOT/security/check-ct-assembly.rb"
VANILLA="$ROOT/nix/vanilla-ext.sh"
rc=0

# Mode B: re-run the invariant on already-built objects (e.g. stock objects
# produced in a distro container earlier).
if [ -n "${OBJECTS:-}" ]; then
  for o in $OBJECTS; do
    echo "== invariant on object: $o =="
    if ruby "$CHECKER" "$o"; then echo "  => PASS"; else echo "  => FAIL"; rc=1; fi
  done
  echo "== codegen-equivalence: $([ $rc -eq 0 ] && echo PASS || echo FAIL) =="
  exit $rc
fi

# Mode A: build + check per CC on PATH (each CC must be a gcc/clang binary).
CCS=("$@")
[ ${#CCS[@]} -eq 0 ] && CCS=("gcc")
for cc in "${CCS[@]}"; do
  echo "== codegen-equivalence: $cc =="
  # vanilla-ext.sh builds + cleans its own object (security/jacobian_ct.o).
  if "$VANILLA" "$cc"; then :; else rc=1; fi
  echo
done
echo "== codegen-equivalence: $([ $rc -eq 0 ] && echo ALL PASS || echo FAIL) =="
exit $rc
