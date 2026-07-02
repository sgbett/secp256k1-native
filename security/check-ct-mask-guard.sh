#!/usr/bin/env bash
# check-ct-mask-guard.sh — CI guard against raw `-(uint64_t)(cond)` mask construction.
#
# Background:
#   PR #32 introduced `ct_mask_u64()` to wrap a value barrier around every
#   constant-time select mask, closing the GCC-15 reconstructed-branch leak
#   documented in advisory GHSA-vp2j-gqfm-r3cf (H-2). The helper's docstring says:
#
#     "All constant-time masks MUST be constructed through this helper — a raw
#      `-(uint64_t)(cond)` is a latent branch waiting for the compiler to
#      reconstruct it."
#
#   Code review alone cannot enforce that discipline. This script does.
#
# What it does:
#   Scans `ext/secp256k1_native/` for the mask-construction shape
#   `-(uint{32,64}_t)(...)`. Whitespace variants are matched
#   (`- (uint64_t)(...)`, `-(uint64_t) (...)`, `-( uint64_t )(...)` — all
#   compile identically) so a stylistic reformat cannot silently evade the
#   guard. The pattern is legitimate only when its result is fed directly into
#   `ct_value_barrier_u64(...)` — i.e. inside `ct_mask_u64` itself. Every other
#   occurrence in code is a latent CT regression. Prose in docstrings is
#   filtered by skipping lines whose first non-whitespace character is `*`.
#
#   The legitimate-site filter is anchored to a word boundary on
#   `ct_value_barrier_u64` so a lookalike wrapper (`my_ct_value_barrier_u64`,
#   `xct_value_barrier_u64`) cannot piggyback on the exemption.
#
# Exit codes:
#   0 — no violations (only the legitimate barrier-wrapped site matched, if any).
#   1 — one or more raw `-(uint64_t)(...)` mask constructions found.
#
# Usage:
#   bash security/check-ct-mask-guard.sh
#
# Run from the repository root.

set -euo pipefail

SEARCH_DIR="ext/secp256k1_native"

if [ ! -d "$SEARCH_DIR" ]; then
    echo "ERROR: $SEARCH_DIR not found — run from the repository root." >&2
    exit 2
fi

# Grep every occurrence of the mask-construction shape, then filter out:
#   1. Comment lines (docstring prose) — lines whose first non-whitespace char
#      after the "file:line:" prefix is `*`.
#   2. Lines where the pattern is passed directly into `ct_value_barrier_u64(`
#      with a `uint64_t` width — the one legitimate site (inside `ct_mask_u64`).
#      Word-boundary anchored on the LHS so `my_ct_value_barrier_u64(` etc.
#      cannot bypass. This is a semantic filter (not a line-range filter) so it
#      survives reordering of secp256k1_native.h.
#
# The search pattern tolerates whitespace between the leading `-`, the
# `(uintNN_t)` cast, and its argument `(`. Both `uint32_t` and `uint64_t` are
# caught — narrower widths compose identically as latent branches.
#
# `|| true` because grep exits 1 when no lines match, which is expected on a
# clean tree; `set -e` would otherwise abort here.
violations=$(grep -rnE -- \
        '-[[:space:]]*\([[:space:]]*uint(32|64)_t[[:space:]]*\)[[:space:]]*\(' \
        "$SEARCH_DIR" \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*\*' \
    | grep -vE '(^|[^A-Za-z0-9_])ct_value_barrier_u64\([[:space:]]*-[[:space:]]*\([[:space:]]*uint64_t[[:space:]]*\)[[:space:]]*\(' \
    || true)

if [ -n "$violations" ]; then
    echo "ERROR: raw -(uint64_t)( mask construction found — use ct_mask_u64() instead:" >&2
    echo "$violations" >&2
    exit 1
fi

echo "OK: no raw -(uint{32,64}_t)( mask construction outside ct_value_barrier_u64."
exit 0
