#!/usr/bin/env bash
# check-ct-mask-guard.sh — CI guard against raw `-(uint{32,64}_t)(cond)` mask construction.
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
#   guard. Unparenthesised operands are matched too (`-(uint64_t)cond`), so
#   dropping the operand parens is not an escape. The pattern is legitimate
#   only when its result is fed directly into `ct_value_barrier_u64(...)`
#   inside `ct_mask_u64`'s definition in `secp256k1_native.h`. Every other
#   occurrence in code — including `ct_value_barrier_u64(...)` inlined at
#   another call site — is a latent CT regression. Prose in docstrings is
#   filtered by skipping lines whose first non-whitespace character is `*`
#   (block-comment continuation) or `//` (C99 single-line comment). `/*` is
#   NOT stripped because `/* short */ code_with_pattern` puts real code
#   after the comment closer.
#
#   The legitimate-site filter is anchored on two fronts:
#     - file scope — only lines in `ext/secp256k1_native/secp256k1_native.h`
#       are eligible (so an inline `ct_value_barrier_u64(-(uint64_t)(cond))`
#       elsewhere trips the guard);
#     - word boundary on `ct_value_barrier_u64` (so a lookalike wrapper
#       `my_ct_value_barrier_u64`, `xct_value_barrier_u64` cannot piggyback
#       on the exemption).
#
# Exit codes:
#   0 — no violations (only the legitimate barrier-wrapped site matched, if any).
#   1 — one or more raw `-(uint{32,64}_t)(...)` mask constructions found.
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
#      after the "file:line:" prefix is `*` (block-comment continuation) or
#      `//` (C99 single-line comment). Both mean the rest of the line is
#      guaranteed prose and can legitimately mention the anti-pattern.
#
#      `/*` is deliberately NOT stripped: `/* stub */ code_with_pattern` is a
#      valid C construction that puts real code after a short block comment,
#      and stripping the line as prose would let a contributor smuggle a
#      violation past the guard by prefixing it with `/* x */`.
#   2. Lines in `ext/secp256k1_native/secp256k1_native.h` where the pattern is
#      passed directly into `ct_value_barrier_u64(...)` with a `uint64_t`
#      width. This is the ONE legitimate site — the `ct_mask_u64` definition
#      in the header — and the exemption is file-scoped so an inline
#      `ct_value_barrier_u64(-(uint64_t)(cond))` written *elsewhere* still
#      trips the guard. The stated discipline is "all masks through
#      `ct_mask_u64`", and file scoping is what enforces it. Word-boundary
#      anchored on the LHS so `my_ct_value_barrier_u64(` etc. cannot bypass.
#      Prefer this over line-range anchoring so reordering within the header
#      does not break the exemption.
#
# The search pattern tolerates whitespace between the leading `-` and the
# `(uintNN_t)` cast, and does not require the cast operand to be
# parenthesised — `-(uint64_t)cond` and `-(uint64_t)(cond)` are both
# structurally equivalent latent-branch shapes and both must be caught.
# Both `uint32_t` and `uint64_t` are matched — narrower widths compose
# identically as latent branches.
#
# The primary recursive grep is run separately so we can distinguish its exit
# codes precisely: 0 = matches, 1 = clean tree (fine), ≥2 = real error
# (unreadable file, invalid regex, ...). A blanket `|| true` on the whole
# pipeline would mask exit-2 as "no violations" and silently defeat the
# guard. The subsequent filter greps operate on captured text so cannot fail
# from I/O, and `|| true` there is safe.
if raw_matches=$(grep -rnE -- \
        '-[[:space:]]*\([[:space:]]*uint(32|64)_t[[:space:]]*\)' \
        "$SEARCH_DIR"); then
    :  # exit 0 — matches; will filter below
else
    grep_status=$?
    if [ "$grep_status" -gt 1 ]; then
        echo "ERROR: initial grep failed with status $grep_status (unreadable file / invalid regex?)" >&2
        exit 2
    fi
    raw_matches=""  # exit 1 = no matches on a clean tree
fi

violations=$(printf '%s' "$raw_matches" \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(\*|//)' \
    | grep -vE '^ext/secp256k1_native/secp256k1_native\.h:[0-9]+:.*[^A-Za-z0-9_]ct_value_barrier_u64\([[:space:]]*-[[:space:]]*\([[:space:]]*uint64_t[[:space:]]*\)' \
    || true)

if [ -n "$violations" ]; then
    echo "ERROR: raw -(uint{32,64}_t)( mask construction found — use ct_mask_u64() instead:" >&2
    echo "$violations" >&2
    exit 1
fi

echo "OK: no raw -(uint{32,64}_t)( mask construction outside ct_value_barrier_u64."
exit 0
