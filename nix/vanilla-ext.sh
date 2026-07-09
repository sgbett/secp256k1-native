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
# actually get. On a non-nix gcc the variable is simply ignored, so this same
# script is used to build the stock reference in a plain distro container.
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
command -v ruby      >/dev/null 2>&1 || { echo "vanilla-ext: FATAL — ruby not on PATH" >&2; exit 2; }
[ -f "$SRC" ]     || { echo "vanilla-ext: FATAL — source not found: $SRC" >&2; exit 2; }
[ -f "$CHECKER" ] || { echo "vanilla-ext: FATAL — checker not found: $CHECKER" >&2; exit 2; }

# Ruby header dirs — build against the REAL headers so codegen is shipping-shape.
RUBY_HDR="$(ruby -rrbconfig -e 'print RbConfig::CONFIG["rubyhdrdir"]' 2>/dev/null)"
RUBY_ARCH_HDR="$(ruby -rrbconfig -e 'print RbConfig::CONFIG["rubyarchhdrdir"]' 2>/dev/null)"
if [ -z "$RUBY_HDR" ] || [ -z "$RUBY_ARCH_HDR" ]; then
  echo "vanilla-ext: FATAL — Ruby header dirs not discoverable (rubyhdrdir/rubyarchhdrdir empty)" >&2
  exit 2
fi

OUT="${OUT:-$(mktemp -d)/jacobian.vanilla.o}"
mkdir -p "$(dirname "$OUT")"

# Flags mirror security/Makefile's jacobian_ct.o target (the single source of
# truth for the CT compile line): -O2 as shipped, -g for objdump -dl line info,
# -fno-stack-protector to strip the canary epilogue artefact from the invariant.
CFLAGS=(-O2 -g -Wall -std=c99 -fcommon -fno-stack-protector
        -I"$RUBY_HDR" -I"$RUBY_ARCH_HDR" -I"$ROOT/ext/secp256k1_native")

echo "== vanilla-ext: building CT object =="
echo "   CC   : $CC ($($CC --version 2>/dev/null | head -1))"
echo "   flags: -O2 vanilla (NIX_HARDENING_ENABLE=\"\")"
echo "   out  : $OUT"
if ! NIX_HARDENING_ENABLE="" "$CC" "${CFLAGS[@]}" -c "$SRC" -o "$OUT"; then
  echo "vanilla-ext: FAIL — compile failed" >&2
  exit 1
fi

rc=0

# --- 1. CC-actually-took -----------------------------------------------------
# Read the compiler stamp from the ELF .comment string table (readelf -p prints
# it cleanly; objdump -s interleaves a hex column that pollutes a naive grep).
# Debian stamps "GCC: (Debian 14.2.0-...) 14.2.0"; nix stamps "GCC: (GNU) 14.3.0"
# — take the first dotted version after "GCC:".
cc_major="$("$CC" -dumpversion 2>/dev/null | cut -d. -f1)"
obj_gcc="$(readelf -p .comment "$OUT" 2>/dev/null | grep -oE 'GCC:[^0-9]*[0-9]+\.[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
obj_major="${obj_gcc%%.*}"
if [ -n "$obj_major" ] && [ "$obj_major" = "$cc_major" ]; then
  echo "   [1] CC-took        PASS — .comment gcc $obj_gcc matches CC major $cc_major"
else
  echo "   [1] CC-took        FAIL — .comment gcc '$obj_gcc' (major '$obj_major') != CC major '$cc_major'" >&2
  rc=1
fi

# --- 2. Assembly-invariant (branchlessness) ----------------------------------
if ruby "$CHECKER" "$OUT"; then
  echo "   [2] CT-invariant   PASS — ladder + jp_add_internal branchless"
else
  echo "   [2] CT-invariant   FAIL — secret-dependent branch/cmov in CT codegen (see above)" >&2
  rc=1
fi

echo "== vanilla-ext: $([ $rc -eq 0 ] && echo PASS || echo FAIL) (CC=$CC) =="
exit $rc
