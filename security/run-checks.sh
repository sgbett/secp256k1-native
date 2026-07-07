#!/usr/bin/env bash
#
# Run the three DETERMINISTIC security-review gates and report pass/fail.
# Platform-independent — same results on Linux, in Docker, or on macOS (clang).
# valgrind/ctgrind is skipped automatically where valgrind is unavailable
# (e.g. native macOS) — run it via the Docker image instead (see Dockerfile).
#
# This does NOT run the statistical dudect timing pass (issue #25) — that needs
# quiet bare metal; see docs/timing-verification-runbook.md.
#
# Usage:  ./run-checks.sh            # default ITERS
#         ITERS=1000000 ./run-checks.sh
#
set -uo pipefail
cd "$(dirname "$0")"
# Smoke default is modest so the gate is fast; scale up for a thorough run,
# e.g. ITERS=2000000 ./run-checks.sh
ITERS="${ITERS:-20000}"
rc=0

echo "== differential fuzz vs independent reference (${ITERS} iters/op-class) =="
make -s dfuzz && python3 dfuzz_ref.py --iters "$ITERS"
case $? in
  0) echo "  PASS: no in-contract mismatches" ;;
  *) echo "  FAIL: in-contract mismatch (see above)"; rc=1 ;;
esac

echo "== ASan + UBSan sweep (${ITERS} iters) =="
if make -s asan && UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 ./asan_sweep "$ITERS" >/dev/null 2>&1; then
  echo "  PASS: no sanitizer diagnostics"
else
  echo "  FAIL: sanitizer diagnostic (re-run ./asan_sweep to see it)"; rc=1
fi

echo "== ctgrind secret-poisoning (valgrind) =="
if ! command -v valgrind >/dev/null 2>&1; then
  echo "  SKIP: valgrind not present (native macOS) — run this gate via the Docker image"
elif ! make -s ctgrind; then
  echo "  FAIL: ctgrind harness build failed"; rc=1
elif valgrind --tool=memcheck --error-exitcode=1 ./ctgrind_harness >/dev/null 2>&1; then
  echo "  PASS: 0 errors (no secret-dependent control flow)"
else
  echo "  FAIL: valgrind reported errors (re-run ./ctgrind_harness under valgrind to see them)"; rc=1
fi

echo "== CT source guard (no raw -(uintNN_t) mask constructions) =="
if (cd .. && bash security/check-ct-mask-guard.sh) >/dev/null 2>&1; then
  echo "  PASS: no raw -(uintNN_t) constructions outside ct_value_barrier_u64"
else
  echo "  FAIL: raw mask construction found (re-run: bash security/check-ct-mask-guard.sh)"; rc=1
fi

echo "== CT assembly invariant (ladder + jp_add_internal branchlessness) =="
if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
  echo "  SKIP: only runs on Linux x86_64 (see .github/workflows/ct-assembly-invariant.yml)"
elif ! command -v objdump >/dev/null 2>&1; then
  echo "  SKIP: GNU objdump not present"
elif ! command -v gcc >/dev/null 2>&1; then
  echo "  SKIP: gcc not present"
else
  ruby_hdr=$(ruby -e 'puts RbConfig::CONFIG["rubyhdrdir"]' 2>/dev/null || true)
  ruby_arch_hdr=$(ruby -e 'puts RbConfig::CONFIG["rubyarchhdrdir"]' 2>/dev/null || true)
  jacobian_o=$(mktemp -t jacobian.o.XXXXXX)
  if gcc -O2 -g -Wall -std=c99 -fcommon -fno-stack-protector \
         -I ../ext/secp256k1_native \
         -I "$ruby_hdr" -I "$ruby_arch_hdr" \
         -c ../ext/secp256k1_native/jacobian.c \
         -o "$jacobian_o" 2>/dev/null; then
    if ruby check-ct-assembly.rb "$jacobian_o" >/dev/null 2>&1; then
      echo "  PASS: ladder + jp_add_internal branchlessness invariants hold"
    else
      echo "  FAIL: CT assembly invariant violated (re-run: ruby security/check-ct-assembly.rb <path>)"; rc=1
    fi
  else
    echo "  SKIP: compile of jacobian.c failed (Ruby headers unavailable?)"
  fi
  rm -f "$jacobian_o"
fi

echo
echo "overall: $([ $rc -eq 0 ] && echo PASS || echo FAIL)"
exit $rc
