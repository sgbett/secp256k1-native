# Makefile for the secp256k1-native timing harness.
#
# Builds a standalone binary that links against the C extension's
# internal functions without requiring Ruby headers or libraries.
#
# Usage:
#   make              # build timing_harness
#   make clean        # remove build artifacts

CC       ?= cc
CFLAGS   := -O2 -Wall -std=c99
LDFLAGS  := -lm

# Extension source directory (relative to timing/)
EXT_DIR  := ../ext/secp256k1_native

# We need our own header instead of secp256k1_native.h (which includes ruby.h).
# The ruby_stubs.c provides all Ruby API symbols the linker needs.
# The -DTIMING_HARNESS flag is set but currently unused — available for
# future conditional compilation if needed.
CFLAGS   += -DTIMING_HARNESS

# Include this directory first so our stub ruby.h is found before any
# system Ruby header, then the extension directory for secp256k1_native.h.
CFLAGS   += -I. -I$(EXT_DIR)

# Source files
HARNESS_SRCS := timing_harness.c ruby_stubs.c
EXT_SRCS     := $(EXT_DIR)/field.c $(EXT_DIR)/scalar.c $(EXT_DIR)/jacobian.c $(EXT_DIR)/secp256k1_native.c

# Object files — all built in this directory
HARNESS_OBJS := timing_harness.o ruby_stubs.o
EXT_OBJS     := field.o scalar.o jacobian.o secp256k1_native.o

ALL_OBJS     := $(HARNESS_OBJS) $(EXT_OBJS)
TARGET       := timing_harness

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(ALL_OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

# Harness source files
timing_harness.o: timing_harness.c
	$(CC) $(CFLAGS) -c -o $@ $<

ruby_stubs.o: ruby_stubs.c
	$(CC) $(CFLAGS) -c -o $@ $<

# Extension source files — compiled with our stubs providing Ruby symbols
field.o: $(EXT_DIR)/field.c $(EXT_DIR)/secp256k1_native.h
	$(CC) $(CFLAGS) -c -o $@ $<

scalar.o: $(EXT_DIR)/scalar.c $(EXT_DIR)/secp256k1_native.h
	$(CC) $(CFLAGS) -c -o $@ $<

jacobian.o: $(EXT_DIR)/jacobian.c $(EXT_DIR)/secp256k1_native.h
	$(CC) $(CFLAGS) -c -o $@ $<

secp256k1_native.o: $(EXT_DIR)/secp256k1_native.c $(EXT_DIR)/secp256k1_native.h
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(ALL_OBJS) $(TARGET)
