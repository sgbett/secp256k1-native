#!/usr/bin/env bash
#
# vanilla-ext.sh — build the CT-critical object at VANILLA gcc -O2 and prove the
# shipped codegen is what a stock `gem install` produces, then that it is
# branchless. This is the load-bearing check of the reference machine (Phase 3
# of plans/61-reference-machine-nix.md): certify the REAL binary, not a
# nix-specific one.
#
# Why "vanilla" is non-negotiable
# -------------------------------
# The gem ships as source and is compiled on each user's machine by their gcc at
# -O2 (extconf.rb appends it). NixOS builds everything through nixpkgs' cc-wrapper,
# which injects a hardening set (empirically, on nixos-25.05: bindnow format
# fortify fortify3 pic relro stackclashprotection stackprotector strictoverflow
# zerocallusedregs). That set DOES change the CT-function codegen — measured on
# gcc 14.3.0, jacobian.o:
#     scalar_multiply_ct_internal : 80 insns hardened  vs  73 vanilla
#     jp_add_internal             : 347 insns hardened  vs 323 vanilla
# The extra instructions are register-zeroing (zerocallusedregs) and stack probes
# (stackclashprotection) — benign (both builds pass the assembly-invariant), but
# they mean the hardened nix build is NOT the binary a stock user runs. Worse in
# principle, hardening could mask a branch a stock build would emit. So we build
# with hardening OFF (NIX_HARDENING_ENABLE="") to certify the binary users
# actually get. (On a non-nix gcc, NIX_HARDENING_ENABLE is simply ignored.)
#
# This script needs ruby + the REAL Ruby headers (RbConfig rubyhdrdir), so it
# runs where those exist — the nix devShell and the on-ISO gate. The STOCK
# reference for the codegen-equivalence check is built SEPARATELY, with the
# timing/ruby.h stubs (no ruby-dev), in a plain gcc:<major> container — see
# nix/codegen-equivalence.sh.
#
# What this checks (all must pass; exit 1 on any failure)
# -------------------------------------------------------
#   1. CC-actually-took — the object's .comment records the compiler; its major
#      must match `$CC --version`. Guards the mkmf/RbConfig trap where the build
#      silently falls back to a different compiler than intended.
#   2. Assembly-invariant — security/check-ct-assembly.rb: the ladder and
#      jp_add_internal contain no secret-dependent branch or cmov. This is the
#      actual constant-time property; it is deterministic and is the on-ISO gate.
#
# The dev-time codegen-equivalence check (nix vanilla gccN vs a stock distro gccN
# of the same major — "passing on nix ⇒ passing on stock") is a separate driver
# that runs THIS script under both toolchains; see nix/codegen-equivalence.sh.
#
# Usage
# -----
#   nix/vanilla-ext.sh [CC]            # CC defaults to $CC or `gcc`
#   OUT=/path/jacobian.o nix/vanilla-ext.sh gcc-15   # keep the object for diffing
#
# Exit codes: 0 pass · 1 a check failed · 2 environment/usage error
set -uo pipefail

CC="${1:-${CC:-gcc}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/ext/secp256k1_native/jacobian.c"
CHECKER="$ROOT/security/check-ct-assembly.rb"

command -v "$CC"     >/dev/null 2>&1 || { echo "vanilla-ext: FATAL — CC '$CC' not on PATH" >&2; exit 2; }
command -v objdump   >/dev/null 2>&1 || { echo "vanilla-ext: FATAL — objdump not on PATH (need binutils)" >&2; exit 2; }
command -v readelf   >/dev/null 2>&1 || { echo "vanilla-ext: FATAL — readelf not on PATH (need binutils; used for the CC-took check)" >&2; exit 2; }
command -v ruby      >/dev/null 2>&1 || { echo "vanilla-ext: FATAL — ruby not on PATH" >&2; exit 2; }
[ -f "$SRC" ]     || { echo "vanilla-ext: FATAL — source not found: $SRC" >&2; exit 2; }
[ -f "$CHECKER" ] || { echo "vanilla-ext: FATAL — checker not found: $CHECKER" >&2; exit 2; }

# Build the CT object via security/Makefile's `jacobian_ct.o` target — the
# single source of truth for the CT compile line (flags + real Ruby headers).
# Reusing it means a CT-relevant flag change there propagates here (and stays in
# lock-step with CI / run-checks.sh) rather than drifting from a hand-copied
# CFLAGS. NIX_HARDENING_ENABLE="" certifies the vanilla, stock-shaped binary.
OBJ="$ROOT/security/jacobian_ct.o"
trap 'rm -f "$OBJ"' EXIT

echo "== vanilla-ext: building CT object =="
echo "   CC  : $CC ($($CC --version 2>/dev/null | head -1))"
echo "   via : make -C security jacobian_ct.o (vanilla, NIX_HARDENING_ENABLE=\"\")"
if ! NIX_HARDENING_ENABLE="" make -C "$ROOT/security" jacobian_ct.o CC="$CC" >/dev/null; then
  echo "vanilla-ext: FAIL — compile failed (make -C security jacobian_ct.o CC=$CC)" >&2
  exit 1
fi

rc=0

# --- 1. CC-actually-took -----------------------------------------------------
# Read the compiler stamp from the ELF .comment string table (readelf -p prints
# it cleanly). gcc stamps "GCC: (…) X.Y.Z"; clang stamps "clang version X.Y.Z" —
# match either so a clang compiler-under-test isn't reported as a spurious FAIL.
cc_major="$("$CC" -dumpversion 2>/dev/null | cut -d. -f1)"
obj_ver="$(readelf -p .comment "$OBJ" 2>/dev/null | grep -oE '(GCC:|clang version)[^0-9]*[0-9]+\.[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
obj_major="${obj_ver%%.*}"
if [ -n "$obj_major" ] && [ "$obj_major" = "$cc_major" ]; then
  echo "   [1] CC-took        PASS — .comment $obj_ver matches CC major $cc_major"
else
  echo "   [1] CC-took        FAIL — .comment '$obj_ver' (major '$obj_major') != CC major '$cc_major'" >&2
  rc=1
fi

# --- 2. Assembly-invariant (branchlessness) ----------------------------------
if ruby "$CHECKER" "$OBJ"; then
  echo "   [2] CT-invariant   PASS — ladder + jp_add_internal branchless"
else
  echo "   [2] CT-invariant   FAIL — secret-dependent branch/cmov in CT codegen (see above)" >&2
  rc=1
fi

echo "== vanilla-ext: $([ $rc -eq 0 ] && echo PASS || echo FAIL) (CC=$CC) =="
exit $rc
