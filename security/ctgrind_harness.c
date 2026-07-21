/*
 * ctgrind_harness.c — deterministic constant-time verification via valgrind
 * secret-poisoning (the "ctgrind" technique).
 *
 * We mark secret inputs (the scalar k, and secret field operands) as
 * UNINITIALISED using VALGRIND_MAKE_MEM_UNDEFINED.  Memcheck then propagates
 * "undefinedness" through every data-flow operation.  The instant the program
 * uses a poisoned value to:
 *   - decide a conditional branch / conditional move, OR
 *   - compute a memory address that is dereferenced,
 * memcheck reports "Conditional jump or move depends on uninitialised value(s)"
 * (or a bad-address error).  Either is a secret-dependent control-flow / memory
 * access — i.e. a constant-time violation.
 *
 * This is DETERMINISTIC and robust to VM noise (unlike statistical dudect):
 * it inspects the actual IR, not wall-clock timing.
 *
 * Build (NO sanitizer — incompatible with valgrind):
 *   cc -O2 -std=c99 -fcommon -g \
 *      -I<timing> -I<ext> \
 *      ctgrind_harness.c <timing>/ruby_stubs.c \
 *      <ext>/field.c <ext>/scalar.c <ext>/jacobian.c <ext>/secp256k1_native.c \
 *      -lm -o ctgrind_harness
 *
 * Run:
 *   valgrind --tool=memcheck --error-exitcode=1 ./ctgrind_harness
 *   -> exit 0 and no errors == constant-time w.r.t. poisoned secrets.
 */

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "secp256k1_native.h"
#include <valgrind/memcheck.h>

/* The generator G in affine coords (public base point), used as a realistic
 * base for the scalar multiply. */
static const uint256_t G_X = {{
    0x59F2815B16F81798ULL, 0x029BFCDB2DCE28D9ULL,
    0x55A06295CE870B07ULL, 0x79BE667EF9DCBBACULL
}};
static const uint256_t G_Y = {{
    0x9C47D08FFB10D4B8ULL, 0xFD17B448A6855419ULL,
    0x5DA4FBFC0E1108A8ULL, 0x483ADA7726A3C465ULL
}};

/* Sink to prevent the compiler/valgrind from eliding results. We DEFINE the
 * sink memory as initialised before printing so the print itself is not what
 * trips memcheck — only genuine secret-dependent control flow should. */
static void consume(const uint256_t *x, const char *label)
{
    /* Make a private copy and un-poison it so the final hexdump doesn't
     * itself raise an "uninitialised" report. Any error BEFORE this point
     * is a real constant-time violation in the function under test. */
    uint256_t c = *x;
    VALGRIND_MAKE_MEM_DEFINED(&c, sizeof(c));
    volatile uint64_t acc = c.d[0] ^ c.d[1] ^ c.d[2] ^ c.d[3];
    fprintf(stderr, "[sink] %s = %016llx\n", label,
            (unsigned long long)acc);
}

static void consume_point(const uint256_t p[3], const char *label)
{
    consume(&p[0], label);
    consume(&p[1], label);
    consume(&p[2], label);
}

int main(void)
{
    fprintf(stderr, "=== ctgrind secret-poisoning harness ===\n");

    /* ------------------------------------------------------------------
     * 1. PRIMARY TARGET: scalar_multiply_ct_internal (Montgomery ladder).
     *    Poison the secret scalar k entirely. The base point is public (G).
     * ------------------------------------------------------------------ */
    {
        uint256_t k;
        /* Give k a real value first so arithmetic is meaningful, THEN poison
         * it. Poisoning marks the bytes undefined for memcheck regardless of
         * their concrete content. */
        k.d[0] = 0xDEADBEEFCAFEBABEULL;
        k.d[1] = 0x0123456789ABCDEFULL;
        k.d[2] = 0xFEDCBA9876543210ULL;
        k.d[3] = 0x7FFFFFFFFFFFFFFFULL; /* < N */

        uint256_t base[3];
        base[0] = G_X;
        base[1] = G_Y;
        memset(&base[2], 0, sizeof(uint256_t));
        base[2].d[0] = 1;

        VALGRIND_MAKE_MEM_UNDEFINED(&k, sizeof(k));

        uint256_t r[3];
        scalar_multiply_ct_internal(r, &k, base);
        consume_point(r, "scalar_multiply_ct");
    }

    /* ------------------------------------------------------------------
     * 2. The ladder's per-iteration primitives, with a SECRET base point.
     *    In a real EC operation the running accumulators r0/r1 are
     *    secret-derived, so jp_add / jp_double must be CT in BOTH operands.
     * ------------------------------------------------------------------ */
    {
        uint256_t p[3], q[3], r[3];
        p[0] = G_X; p[1] = G_Y; memset(&p[2],0,sizeof(uint256_t)); p[2].d[0]=1;
        q[0] = G_X; q[1] = G_Y; memset(&q[2],0,sizeof(uint256_t)); q[2].d[0]=1;
        /* perturb q so they are distinct points */
        q[0].d[0] ^= 0x55ULL;

        VALGRIND_MAKE_MEM_UNDEFINED(p, sizeof(uint256_t)*3);
        VALGRIND_MAKE_MEM_UNDEFINED(q, sizeof(uint256_t)*3);

        jp_add_internal(r, p, q);
        consume_point(r, "jp_add");

        uint256_t d[3];
        VALGRIND_MAKE_MEM_UNDEFINED(p, sizeof(uint256_t)*3);
        jp_double_internal(d, p);
        consume_point(d, "jp_double");

        uint256_t ng[3];
        VALGRIND_MAKE_MEM_UNDEFINED(p, sizeof(uint256_t)*3);
        jp_neg_internal(ng, p);
        consume_point(ng, "jp_neg");
    }

    /* ------------------------------------------------------------------
     * 3. Field ops named in the task: fred, fsub, fneg, fadd, fmul.
     *    Poison both operands (secret field elements).
     * ------------------------------------------------------------------ */
    {
        uint256_t a, b, r;
        a.d[0]=0x1; a.d[1]=0x2; a.d[2]=0x3; a.d[3]=0x4;
        b.d[0]=0xAAAAAAAAAAAAAAAAULL; b.d[1]=0xBBBBBBBBBBBBBBBBULL;
        b.d[2]=0xCCCCCCCCCCCCCCCCULL; b.d[3]=0xDDDDDDDDDDDDDDDDULL;

        VALGRIND_MAKE_MEM_UNDEFINED(&a, sizeof(a));
        VALGRIND_MAKE_MEM_UNDEFINED(&b, sizeof(b));

        fadd_internal(&r, &a, &b); consume(&r, "fadd");
        fsub_internal(&r, &a, &b); consume(&r, "fsub");
        fmul_internal(&r, &a, &b); consume(&r, "fmul");
        fneg_internal(&r, &a);     consume(&r, "fneg");
        fsqr_internal(&r, &a);     consume(&r, "fsqr");

        /* fred takes (hi, lo). Poison a full 512-bit secret value. */
        uint256_t hi, lo;
        memset(&hi, 0x77, sizeof(hi));
        memset(&lo, 0x99, sizeof(lo));
        VALGRIND_MAKE_MEM_UNDEFINED(&hi, sizeof(hi));
        VALGRIND_MAKE_MEM_UNDEFINED(&lo, sizeof(lo));
        fred_internal(&r, &hi, &lo); consume(&r, "fred");
    }

    /* ------------------------------------------------------------------
     * 4. Scalar arithmetic: scalar_add, scalar_mul, scalar_reduce, scalar_inv.
     *    These are used on secret nonces/keys by consumers (e.g. ECDSA
     *    s = k^-1 (z + r*d)).
     *
     *    scalar_inv iterates over the PUBLIC exponent N-2, so its only branch
     *    is on a compile-time constant, not the secret. We still poison its
     *    input and test it directly (empirical over inspected): the secret
     *    flows through branchless scalar_sqr — which delegates to
     *    scalar_mul — so poisoning the entry point deterministically verifies
     *    the whole composition, and guards against a future edit or compiler
     *    reconstruction introducing a secret-dependent branch on the inversion
     *    path (cf. the advisory-0001 select-branchification).
     *
     *    Post-#21, scalar_reduce_limbs is fully branchless — the previous
     *    `if (h == 0) continue;` and `if (carry3)` guards in the residual
     *    fold were removed.  This test confirms 0 errors on the scalar layer.
     * ------------------------------------------------------------------ */
    {
        uint256_t a, b, r;
        a.d[0]=0x1111111111111111ULL; a.d[1]=0x2222222222222222ULL;
        a.d[2]=0x3333333333333333ULL; a.d[3]=0x4444444444444444ULL;
        b.d[0]=0x5555555555555555ULL; b.d[1]=0x6666666666666666ULL;
        b.d[2]=0x7777777777777777ULL; b.d[3]=0x0888888888888888ULL;

        VALGRIND_MAKE_MEM_UNDEFINED(&a, sizeof(a));
        VALGRIND_MAKE_MEM_UNDEFINED(&b, sizeof(b));

        scalar_add_internal(&r, &a, &b); consume(&r, "scalar_add");
        scalar_mul_internal(&r, &a, &b); consume(&r, "scalar_mul");

        uint256_t hi, lo;
        memset(&hi, 0, sizeof(hi));
        lo.d[0]=0xAAAAAAAAAAAAAAAAULL; lo.d[1]=0xBBBBBBBBBBBBBBBBULL;
        lo.d[2]=0xCCCCCCCCCCCCCCCCULL; lo.d[3]=0xDDDDDDDDDDDDDDDDULL;
        VALGRIND_MAKE_MEM_UNDEFINED(&hi, sizeof(hi));
        VALGRIND_MAKE_MEM_UNDEFINED(&lo, sizeof(lo));
        scalar_reduce(&r, &hi, &lo); consume(&r, "scalar_reduce");

        /* scalar_inv: poison the secret input; the exponent (N-2) is public. */
        uint256_t inv_in, inv_r;
        inv_in.d[0]=0x1111111111111111ULL; inv_in.d[1]=0x2222222222222222ULL;
        inv_in.d[2]=0x3333333333333333ULL; inv_in.d[3]=0x4444444444444444ULL;
        VALGRIND_MAKE_MEM_UNDEFINED(&inv_in, sizeof(inv_in));
        scalar_inv_internal(&inv_r, &inv_in); consume(&inv_r, "scalar_inv");
    }

    fprintf(stderr, "=== harness completed all calls ===\n");
    return 0;
}
