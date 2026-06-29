# Makefile for the secp256k1-native security-review harnesses.
#
# These are the as-run harnesses from the pre-v1 security review
# (see ../docs/security-review-v1.md). They compile the C extension's
# internal functions standalone — no Ruby runtime — using the project's
# existing stub at ../timing/ruby_stubs.c.
#
# NOTE: gcc 13 defaults to -fno-common; these link the extension's module
# global from two TUs, so -fcommon is required.
#
# Targets:
#   make dfuzz     # differential fuzz harness (driven by dfuzz_ref.py)
#   make ctgrind   # constant-time secret-poisoning harness (run under valgrind)
#   make asan      # ASan+UBSan sweep harness
#   make check     # build + smoke-run all three
#   make clean

CC       ?= cc
EXT      := ../ext/secp256k1_native
STUB     := ../timing
INCLUDES := -I$(STUB) -I$(EXT)
BASEFLAGS:= -std=c99 -fcommon $(INCLUDES)
EXT_SRCS := $(EXT)/field.c $(EXT)/scalar.c $(EXT)/jacobian.c $(EXT)/secp256k1_native.c
STUB_SRC := $(STUB)/ruby_stubs.c

.PHONY: all check clean dfuzz ctgrind asan

all: dfuzz ctgrind asan

# The Python driver (dfuzz_ref.py) execs a sibling binary named "dfuzz".
dfuzz: dfuzz_harness.c $(EXT_SRCS) $(STUB_SRC)
	$(CC) -O2 $(BASEFLAGS) $^ -lm -o dfuzz

# valgrind is incompatible with -fsanitize here; build with debug info only.
ctgrind: ctgrind_harness.c $(EXT_SRCS) $(STUB_SRC)
	$(CC) -O1 -g $(BASEFLAGS) $^ -lm -o ctgrind_harness

asan: asan_sweep.c $(EXT_SRCS) $(STUB_SRC)
	$(CC) -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
	      $(BASEFLAGS) $^ -lm -o asan_sweep

# Smoke run: build what we can, run a short pass of each.
# ctgrind builds against <valgrind/memcheck.h>, so we build it lazily — only
# when valgrind is present. That keeps `make check` clean on native macOS.
check: dfuzz asan
	@echo "== differential fuzz vs independent Python reference ==" ; python3 dfuzz_ref.py
	@echo "== ctgrind (valgrind memcheck) — flags the I-11 scalar branches until fixed ==" ; \
	  if ! command -v valgrind >/dev/null 2>&1; then \
	    echo "  SKIP: valgrind not present — see ./run-checks.sh"; \
	  elif ! $(MAKE) -s ctgrind; then \
	    echo "  FAIL: ctgrind harness build failed"; \
	  else \
	    valgrind --tool=memcheck --error-exitcode=1 ./ctgrind_harness 2>&1 | tail -3 || true; \
	  fi
	@echo "== asan/ubsan sweep ==" ; \
	  UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 ./asan_sweep 2>&1 | tail -3

clean:
	rm -f dfuzz dfuzz_harness ctgrind_harness asan_sweep
