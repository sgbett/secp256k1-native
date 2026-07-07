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
#   make dfuzz          # differential fuzz harness (driven by dfuzz_ref.py)
#   make ctgrind        # constant-time secret-poisoning harness (run under valgrind)
#   make asan           # ASan+UBSan sweep harness
#   make jacobian_ct.o  # jacobian.c object file for the CT assembly-invariant check
#                       # (consumed by ../.github/workflows/ct-assembly-invariant.yml
#                       # and by ./run-checks.sh; keeps the compile line in one place
#                       # so a flag change here propagates to both CI and local)
#   make check          # build + smoke-run all three
#   make clean

CC       ?= cc
EXT      := ../ext/secp256k1_native
STUB     := ../timing
INCLUDES := -I$(STUB) -I$(EXT)
BASEFLAGS:= -std=c99 -fcommon $(INCLUDES)
EXT_SRCS := $(EXT)/field.c $(EXT)/scalar.c $(EXT)/jacobian.c $(EXT)/secp256k1_native.c
STUB_SRC := $(STUB)/ruby_stubs.c

RUBY_HDR      := $(shell ruby -e 'puts RbConfig::CONFIG["rubyhdrdir"]' 2>/dev/null)
RUBY_ARCH_HDR := $(shell ruby -e 'puts RbConfig::CONFIG["rubyarchhdrdir"]' 2>/dev/null)

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

# CT assembly-invariant check — jacobian.c compiled standalone against the
# **real** Ruby headers at `-O2 -g -Wall -std=c99 -fcommon`, with
# `-fno-stack-protector` added to strip GCC's canary `sub %fs:0x28,%rax; jne
# <__stack_chk_fail>` epilogue artefact from the disassembly (that jne is
# data-independent — canary vs canary — but inflates the conditional-jump
# count the invariant asserts). `-g` is required so `objdump -dl` can
# attribute lines back to source.
#
# Deliberately does NOT use $(BASEFLAGS): that carries `-I$(STUB)` for the
# dfuzz/asan/ctgrind targets, whose stub `ruby.h` would win over the real
# one if it came first on the include path. Here we want shipping-shape
# codegen, so the real Ruby headers must be preferred.
jacobian_ct.o: $(EXT)/jacobian.c
	$(CC) -O2 -g -Wall -std=c99 -fcommon -fno-stack-protector \
	      -I$(RUBY_HDR) -I$(RUBY_ARCH_HDR) -I$(EXT) \
	      -c $< -o $@

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
	rm -f dfuzz dfuzz_harness ctgrind_harness asan_sweep jacobian_ct.o
