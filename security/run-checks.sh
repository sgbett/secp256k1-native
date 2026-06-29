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

echo
echo "overall: $([ $rc -eq 0 ] && echo PASS || echo FAIL)"
exit $rc
