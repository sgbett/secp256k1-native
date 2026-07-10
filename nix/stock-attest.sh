#!/usr/bin/env bash
#
# stock-attest.sh — dev-time defence-in-depth for the "nix ⇒ stock" equivalence
# (the reference machine's one non-negotiable; see plans/61-reference-machine-nix.md).
#
# For each given gcc MAJOR, spin a stock `gcc:<major>` Debian container and run
# the SAME two constant-time checks the nix gate runs, but against a STOCK
# (non-nix) gcc build:
#   (1) assembly-invariant — security/check-ct-assembly.rb on jacobian_ct.o
#                            (inspects the ladder + jp_add_internal symbols)
#   (2) ctgrind            — valgrind secret-poisoning on the ctgrind harness
#                            (WHOLE-BINARY, symbol-agnostic)
# The invariant checks two named symbols; ctgrind tracks secret data-flow to a
# conditional branch/address ANYWHERE in the binary — so together they catch a
# secret-dependent branch a stock gcc might emit even in a compiler-OUTLINED
# mask routine the two-symbol invariant would miss. That closes the coverage
# gap left by dropping the objdump byte-golden (which was brittle across gcc
# minors) while keeping the robustness of an invariant-under-both-toolchains.
#
# This is a DEV-TIME attestation (needs docker), run per toolchain bump — NOT
# the per-boot ISO sweep, which certifies the nix side (gate runs ctgrind per
# compiler on the actual shipped binary). Both build the CT object via
# security/Makefile's targets, the single source of truth for the compile line.
#
# Usage:  nix/stock-attest.sh [MAJOR ...]          (default: 14 15)
# Exit:   0 all pass · 1 any check failed · 2 docker missing
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v docker >/dev/null 2>&1 || { echo "stock-attest: FATAL — docker not found" >&2; exit 2; }

majors=("$@")
[ ${#majors[@]} -eq 0 ] && majors=(14 15)
rc=0

for m in "${majors[@]}"; do
  echo "======================================================================"
  echo "== stock gcc:$m attestation — assembly-invariant + ctgrind =="
  if docker run --rm --platform linux/amd64 -v "$ROOT":/src -w /src "gcc:$m" bash -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get update >/dev/null && apt-get install -y --no-install-recommends ruby ruby-dev valgrind >/dev/null
      echo "  gcc     : $(gcc --version | head -1)"
      echo "  valgrind: $(valgrind --version)"
      # (1) assembly-invariant on the stock CT object — same Makefile target the
      #     nix side uses, so the CT compile line stays in lock-step.
      make -s -C security jacobian_ct.o CC=gcc
      ruby security/check-ct-assembly.rb security/jacobian_ct.o
      # (2) ctgrind — whole-binary secret-flow on the stock build.
      make -s -C security ctgrind CC=gcc
      valgrind --error-exitcode=1 -q ./security/ctgrind_harness >/dev/null && echo "  ctgrind : CLEAN"
      rm -f security/jacobian_ct.o security/ctgrind_harness
  '; then
    echo "  => gcc:$m PASS (invariant + ctgrind)"
  else
    echo "  => gcc:$m FAIL"; rc=1
  fi
done

echo "======================================================================"
echo "== stock-attest: $([ $rc -eq 0 ] && echo ALL PASS || echo FAIL) =="
exit $rc
