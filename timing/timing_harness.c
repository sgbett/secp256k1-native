/*
 * timing_harness.c — Standalone binary for timing secp256k1 C internals.
 *
 * Compiles against the C extension source files (field.c, scalar.c,
 * jacobian.c) without Ruby headers.  Calls *_internal functions directly
 * using uint256_t values.
 *
 * This skeleton verifies that compilation, linking, and basic function
 * calls work.  Timing test routines will be added in subsequent tasks.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "dudect.h"

/* -----------------------------------------------------------------------
 * Platform-aware high-resolution timing
 * ----------------------------------------------------------------------- */

#ifdef __APPLE__
#include <mach/mach_time.h>

static uint64_t timing_now_ns(void)
{
    static mach_timebase_info_data_t info = {0, 0};
    if (info.denom == 0) {
        mach_timebase_info(&info);
    }
    return mach_absolute_time() * info.numer / info.denom;
}

#else  /* Linux / POSIX */
#include <time.h>

static uint64_t timing_now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

#endif

/* -----------------------------------------------------------------------
 * Type and function declarations from the C extension
 *
 * We replicate the minimal set of types and declarations here rather
 * than including secp256k1_native.h (which pulls in ruby.h).
 * ----------------------------------------------------------------------- */

#ifndef uint128_t
typedef unsigned __int128 uint128_t;
#endif

typedef struct {
    uint64_t d[4];
} uint256_t;

/* Field arithmetic internals (field.c) */
extern void fred_internal(uint256_t *r, const uint256_t *hi, const uint256_t *lo);
extern void fmul_internal(uint256_t *r, const uint256_t *a, const uint256_t *b);
extern void fsqr_internal(uint256_t *r, const uint256_t *a);
extern void fadd_internal(uint256_t *r, const uint256_t *a, const uint256_t *b);
extern void fsub_internal(uint256_t *r, const uint256_t *a, const uint256_t *b);
extern void fneg_internal(uint256_t *r, const uint256_t *a);
extern void finv_internal(uint256_t *r, const uint256_t *a);
extern int  fsqrt_internal(uint256_t *r, const uint256_t *a);

/* 256-bit helpers (field.c) */
extern uint64_t uint256_add(uint256_t *r, const uint256_t *a, const uint256_t *b);
extern uint64_t uint256_sub(uint256_t *r, const uint256_t *a, const uint256_t *b);
extern uint64_t uint256_is_zero(const uint256_t *x);

/* Scalar arithmetic internals (scalar.c) */
extern void scalar_reduce(uint256_t *r, const uint256_t *hi, const uint256_t *lo);
extern void scalar_mul_internal(uint256_t *r, const uint256_t *a, const uint256_t *b);
extern void scalar_add_internal(uint256_t *r, const uint256_t *a, const uint256_t *b);
extern void scalar_inv_internal(uint256_t *r, const uint256_t *a);

/* Jacobian point operations (jacobian.c) */
extern void jp_double_internal(uint256_t r[3], const uint256_t p[3]);
extern void jp_add_internal(uint256_t r[3], const uint256_t p[3], const uint256_t q[3]);
extern void jp_neg_internal(uint256_t r[3], const uint256_t p[3]);
extern void scalar_multiply_ct_internal(uint256_t r[3], const uint256_t *k, const uint256_t base[3]);

/* -----------------------------------------------------------------------
 * secp256k1 generator point G — affine coordinates as uint256_t
 *
 * GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
 * GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
 *
 * Stored in little-endian limb order (d[0] = least-significant 64 bits).
 * ----------------------------------------------------------------------- */

static const uint256_t GENERATOR_X = {{
    0x59F2815B16F81798ULL,  /* bits   0-63  */
    0x029BFCDB2DCE28D9ULL,  /* bits  64-127 */
    0x55A06295CE870B07ULL,  /* bits 128-191 */
    0x79BE667EF9DCBBACULL   /* bits 192-255 */
}};

static const uint256_t GENERATOR_Y = {{
    0x9C47D08FFB10D4B8ULL,  /* bits   0-63  */
    0xFD17B448A6855419ULL,  /* bits  64-127 */
    0x5DA4FBFC0E1108A8ULL,  /* bits 128-191 */
    0x483ADA7726A3C465ULL   /* bits 192-255 */
}};

/* -----------------------------------------------------------------------
 * secp256k1 field prime P = 2^256 - 2^32 - 977
 * Little-endian limb order (d[0] = least-significant 64 bits).
 * ----------------------------------------------------------------------- */

static const uint256_t FIELD_P = {{
    0xFFFFFFFEFFFFFC2FULL,  /* bits   0-63  */
    0xFFFFFFFFFFFFFFFFULL,  /* bits  64-127 */
    0xFFFFFFFFFFFFFFFFULL,  /* bits 128-191 */
    0xFFFFFFFFFFFFFFFFULL   /* bits 192-255 */
}};

/* -----------------------------------------------------------------------
 * Deterministic PRNG — xorshift64 (Marsaglia, 2003)
 *
 * Using a deterministic PRNG avoids potential timing variation from
 * libc rand() and ensures reproducible test inputs across runs.
 * ----------------------------------------------------------------------- */

static uint64_t xorshift64_state = 0x123456789ABCDEF0ULL;

static uint64_t xorshift64(void)
{
    uint64_t x = xorshift64_state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    xorshift64_state = x;
    return x;
}

/* -----------------------------------------------------------------------
 * Field operation timing tests (dudect)
 *
 * Each test compares two classes of input designed to exercise different
 * sides of a branchless conditional:
 *   - Class A: values that trigger the conditional path
 *   - Class B: values that do not trigger it
 *
 * If the implementation is truly constant-time, both classes should
 * produce indistinguishable timing distributions (|t| < 4.5).
 * ----------------------------------------------------------------------- */

#define FIELD_TIMING_MEASUREMENTS 1500000

/*
 * test_fred — timing test for fred_internal.
 *
 * Both classes use hi = 0 so the fold arithmetic is identical (no
 * high-limb multiplication). The classes differ only in whether the
 * low value triggers the final branchless conditional subtraction:
 *   Class A (>= P): lo just above P → final subtraction selects reduced.
 *   Class B (< P):  lo just below P → final subtraction selects original.
 *
 * By keeping both values near P (differing by at most ~2^16), we ensure
 * the fold arithmetic executes identically and only the branchless
 * conditional select differs.
 */
static int test_fred(void)
{
    dudect_ctx_t ctx;
    dudect_init(&ctx);
    int i;

    for (i = 0; i < FIELD_TIMING_MEASUREMENTS; i++) {
        uint256_t hi = {{ 0ULL, 0ULL, 0ULL, 0ULL }};
        uint256_t lo;
        uint256_t r;
        int class_id = i & 1;
        uint64_t t0, t1;

        if (class_id == 0) {
            /* Class A: value just above P (triggers conditional subtraction).
             * P + random offset in [1, 0xFFFF]. */
            lo = FIELD_P;
            uint256_t offset = {{ (xorshift64() & 0xFFFE) + 1, 0ULL, 0ULL, 0ULL }};
            uint256_add(&lo, &lo, &offset);
        } else {
            /* Class B: value just below P (no conditional subtraction).
             * P - random offset in [1, 0xFFFF]. */
            lo = FIELD_P;
            uint256_t offset = {{ (xorshift64() & 0xFFFE) + 1, 0ULL, 0ULL, 0ULL }};
            uint256_sub(&lo, &lo, &offset);
        }

        t0 = timing_now_ns();
        fred_internal(&r, &hi, &lo);
        t1 = timing_now_ns();

        dudect_add(&ctx, class_id, (double)(t1 - t0));
    }

    dudect_report(&ctx, "fred_internal");
    return dudect_passed(&ctx);
}

/*
 * test_fsub — timing test for fsub_internal.
 *
 * Class A (borrow): a < b → subtraction underflows, triggers addition
 *   of P to correct the result.
 * Class B (no borrow): a > b → no underflow, no P-addition.
 */
static int test_fsub(void)
{
    dudect_ctx_t ctx;
    dudect_init(&ctx);
    int i;

    for (i = 0; i < FIELD_TIMING_MEASUREMENTS; i++) {
        uint256_t a, b, r;
        int class_id = i & 1;
        uint64_t t0, t1;

        if (class_id == 0) {
            /* Class A: a < b (triggers borrow → P-addition) */
            a.d[0] = xorshift64() & 0xFFFF;
            a.d[1] = 0ULL;
            a.d[2] = 0ULL;
            a.d[3] = 0ULL;
            b.d[0] = xorshift64();
            b.d[1] = xorshift64();
            b.d[2] = xorshift64();
            b.d[3] = xorshift64() & 0x7FFFFFFFFFFFFFFFULL;
        } else {
            /* Class B: a > b (no borrow) */
            a.d[0] = xorshift64();
            a.d[1] = xorshift64();
            a.d[2] = xorshift64();
            a.d[3] = xorshift64() & 0x7FFFFFFFFFFFFFFFULL;
            b.d[0] = xorshift64() & 0xFFFF;
            b.d[1] = 0ULL;
            b.d[2] = 0ULL;
            b.d[3] = 0ULL;
        }

        t0 = timing_now_ns();
        fsub_internal(&r, &a, &b);
        t1 = timing_now_ns();

        dudect_add(&ctx, class_id, (double)(t1 - t0));
    }

    dudect_report(&ctx, "fsub_internal");
    return dudect_passed(&ctx);
}

/*
 * test_fneg — timing test for fneg_internal.
 *
 * Class A (near-P): values with high limbs near P's high limbs. The
 *   P - a computation produces a small result and the zero-detection
 *   mask is all-zeros (non-zero input → keep negated).
 * Class B (small): small random values. P - a produces a large result
 *   and the zero-detection mask is also all-zeros.
 *
 * Both classes exercise non-zero inputs but from opposite ends of the
 * field, testing that the branchless zero-detection and masking produce
 * constant-time behaviour regardless of the magnitude of the input.
 */
static int test_fneg(void)
{
    dudect_ctx_t ctx;
    dudect_init(&ctx);
    int i;

    for (i = 0; i < FIELD_TIMING_MEASUREMENTS; i++) {
        uint256_t a, r;
        int class_id = i & 1;
        uint64_t t0, t1;

        if (class_id == 0) {
            /* Class A: values near P (high limbs close to P's) */
            a.d[0] = 0xFFFFFFFEFFFFFC2FULL - (xorshift64() & 0xFFFF);
            a.d[1] = 0xFFFFFFFFFFFFFFFFULL;
            a.d[2] = 0xFFFFFFFFFFFFFFFFULL;
            a.d[3] = 0xFFFFFFFFFFFFFFFFULL;
        } else {
            /* Class B: small random values */
            a.d[0] = xorshift64();
            a.d[1] = xorshift64() & 0xFF;
            a.d[2] = 0ULL;
            a.d[3] = 0ULL;
        }

        t0 = timing_now_ns();
        fneg_internal(&r, &a);
        t1 = timing_now_ns();

        dudect_add(&ctx, class_id, (double)(t1 - t0));
    }

    dudect_report(&ctx, "fneg_internal");
    return dudect_passed(&ctx);
}

/*
 * test_fadd — timing test for fadd_internal.
 *
 * Class A (overflow): a + b > P → triggers conditional subtraction of P.
 * Class B (no overflow): a + b < P → no subtraction triggered.
 */
static int test_fadd(void)
{
    dudect_ctx_t ctx;
    dudect_init(&ctx);
    int i;

    for (i = 0; i < FIELD_TIMING_MEASUREMENTS; i++) {
        uint256_t a, b, r;
        int class_id = i & 1;
        uint64_t t0, t1;

        if (class_id == 0) {
            /* Class A: both operands near P/2, so a + b > P.
             * P/2 ~ 0x7FFFFFFFFFFFFFFF...  with d[3] ~ 0x7FFFFFFF... */
            a.d[0] = xorshift64();
            a.d[1] = xorshift64();
            a.d[2] = xorshift64();
            a.d[3] = 0x8000000000000000ULL | (xorshift64() & 0x7FFFFFFFFFFFFFFFULL);
            b.d[0] = xorshift64();
            b.d[1] = xorshift64();
            b.d[2] = xorshift64();
            b.d[3] = 0x8000000000000000ULL | (xorshift64() & 0x7FFFFFFFFFFFFFFFULL);
        } else {
            /* Class B: both operands small, a + b < P */
            a.d[0] = xorshift64();
            a.d[1] = xorshift64() & 0xFF;
            a.d[2] = 0ULL;
            a.d[3] = 0ULL;
            b.d[0] = xorshift64();
            b.d[1] = xorshift64() & 0xFF;
            b.d[2] = 0ULL;
            b.d[3] = 0ULL;
        }

        t0 = timing_now_ns();
        fadd_internal(&r, &a, &b);
        t1 = timing_now_ns();

        dudect_add(&ctx, class_id, (double)(t1 - t0));
    }

    dudect_report(&ctx, "fadd_internal");
    return dudect_passed(&ctx);
}

/*
 * test_field_ops — run all four field operation timing tests.
 *
 * Returns 0 if all tests pass, 1 if any test fails.
 */
static int test_field_ops(void)
{
    int failures = 0;

    printf("\n[6] Field operation timing tests (dudect)\n");
    printf("  Measurements per function: %d\n\n", FIELD_TIMING_MEASUREMENTS);

    if (!test_fred()) failures++;
    if (!test_fsub()) failures++;
    if (!test_fneg()) failures++;
    if (!test_fadd()) failures++;

    printf("\n  Field timing: %d/4 passed\n\n",
           4 - failures);
    return failures > 0 ? 1 : 0;
}

/* -----------------------------------------------------------------------
 * Scalar multiplication and point operation timing tests (dudect)
 * ----------------------------------------------------------------------- */

#define SCALAR_MUL_MEASUREMENTS 10000
#define JP_ADD_MEASUREMENTS     1000000

/*
 * Generate a random 256-bit value reduced modulo N.
 *
 * Generates 4 random limbs via xorshift64, then reduces mod N using
 * scalar_reduce(hi=0, lo=random). This ensures the scalar is always
 * in [0, N) regardless of the raw random value.
 */
static void random_scalar_mod_n(uint256_t *out)
{
    uint256_t hi = {{ 0ULL, 0ULL, 0ULL, 0ULL }};
    uint256_t lo;
    lo.d[0] = xorshift64();
    lo.d[1] = xorshift64();
    lo.d[2] = xorshift64();
    lo.d[3] = xorshift64();
    scalar_reduce(out, &hi, &lo);
}

/*
 * test_scalar_mul — timing test for scalar_multiply_ct_internal.
 *
 * The Montgomery ladder must execute in constant time regardless of the
 * scalar value. This test compares:
 *   Class A: fixed scalar (k = 1, minimal Hamming weight)
 *   Class B: random scalar (varying Hamming weight and bit pattern)
 *
 * Both classes multiply the same base point (generator G in Jacobian form).
 * If the ladder is truly constant-time, the two classes should produce
 * indistinguishable timing distributions (|t| < 4.5).
 *
 * Uses 10,000 measurements — scalar_multiply_ct_internal is ~256x slower
 * than individual field operations (256 iterations of jp_add + jp_double).
 */
static int test_scalar_mul(void)
{
    dudect_ctx_t ctx;
    dudect_init(&ctx);

    /* Base point: generator G in Jacobian coordinates [Gx, Gy, 1] */
    uint256_t base[3];
    base[0] = GENERATOR_X;
    base[1] = GENERATOR_Y;
    memset(&base[2], 0, sizeof(uint256_t));
    base[2].d[0] = 1;

    /* Class A: fixed scalar k = 1 (minimal Hamming weight — only bit 0 set) */
    uint256_t fixed_scalar = {{ 1ULL, 0ULL, 0ULL, 0ULL }};

    int i;
    for (i = 0; i < SCALAR_MUL_MEASUREMENTS; i++) {
        uint256_t r[3];
        int class_id = i & 1;
        uint64_t t0, t1;

        if (class_id == 0) {
            /* Class A: fixed scalar */
            t0 = timing_now_ns();
            scalar_multiply_ct_internal(r, &fixed_scalar, base);
            t1 = timing_now_ns();
        } else {
            /* Class B: random scalar mod N */
            uint256_t random_k;
            random_scalar_mod_n(&random_k);

            /* Ensure non-zero (k=0 is never a valid secret key) */
            if (uint256_is_zero(&random_k)) {
                random_k.d[0] = 1;
            }

            t0 = timing_now_ns();
            scalar_multiply_ct_internal(r, &random_k, base);
            t1 = timing_now_ns();
        }

        dudect_add(&ctx, class_id, (double)(t1 - t0));
    }

    dudect_report(&ctx, "scalar_multiply_ct_internal");
    return dudect_passed(&ctx);
}

/*
 * test_jp_add — timing test for jp_add_internal.
 *
 * jp_add_internal has branches on uint256_is_zero for the Z-coordinate
 * (infinity checks) and the intermediate value h (equal/negated point
 * checks). These operate on accumulator state, not directly on the
 * secret scalar. Testing this in isolation helps identify the leakage
 * source if scalar_multiply_ct fails.
 *
 * Both classes use "normal" points (finite, distinct) to exercise the
 * main computation path:
 *   Class A: both points have Z = 1 (affine embedding)
 *   Class B: both points have non-trivial Z coordinates (from doubling)
 *
 * If jp_add is truly constant-time on non-degenerate inputs, both
 * classes should produce indistinguishable timing (|t| < 4.5).
 */
static int test_jp_add(void)
{
    dudect_ctx_t ctx;
    dudect_init(&ctx);

    /* Precompute points for the two classes.
     *
     * Class A points: G and 2G, both in affine embedding (Z = 1).
     * We compute 2G via jp_double, then convert to affine using finv.
     *
     * Class B points: 3G and 5G in Jacobian form (non-trivial Z),
     * computed by repeated doubling/adding without affine conversion.
     */

    /* G in Jacobian: [Gx, Gy, 1] */
    uint256_t g_jac[3];
    g_jac[0] = GENERATOR_X;
    g_jac[1] = GENERATOR_Y;
    memset(&g_jac[2], 0, sizeof(uint256_t));
    g_jac[2].d[0] = 1;

    /* 2G (Jacobian, non-trivial Z from doubling) */
    uint256_t g2_jac[3];
    jp_double_internal(g2_jac, g_jac);

    /* Convert 2G to affine embedding for Class A:
     * x_affine = X / Z^2, y_affine = Y / Z^3 */
    uint256_t z_inv, z_sq, z3_inv;
    finv_internal(&z_inv, &g2_jac[2]);        /* 1/Z */
    fsqr_internal(&z_sq, &z_inv);              /* 1/Z^2 */
    fmul_internal(&z3_inv, &z_sq, &z_inv);    /* 1/Z^3 */

    uint256_t g2_affine[3];
    fmul_internal(&g2_affine[0], &g2_jac[0], &z_sq);    /* X / Z^2 */
    fmul_internal(&g2_affine[1], &g2_jac[1], &z3_inv);  /* Y / Z^3 */
    memset(&g2_affine[2], 0, sizeof(uint256_t));
    g2_affine[2].d[0] = 1;  /* Z = 1 */

    /* 3G = 2G + G (Jacobian, non-trivial Z) */
    uint256_t g3_jac[3];
    jp_add_internal(g3_jac, g2_jac, g_jac);

    /* 5G = 3G + 2G (Jacobian, non-trivial Z) */
    uint256_t g5_jac[3];
    jp_add_internal(g5_jac, g3_jac, g2_jac);

    int i;
    for (i = 0; i < JP_ADD_MEASUREMENTS; i++) {
        uint256_t r[3];
        int class_id = i & 1;
        uint64_t t0, t1;

        if (class_id == 0) {
            /* Class A: both points affine (Z = 1) */
            t0 = timing_now_ns();
            jp_add_internal(r, g_jac, g2_affine);
            t1 = timing_now_ns();
        } else {
            /* Class B: both points with non-trivial Z coordinates */
            t0 = timing_now_ns();
            jp_add_internal(r, g3_jac, g5_jac);
            t1 = timing_now_ns();
        }

        dudect_add(&ctx, class_id, (double)(t1 - t0));
    }

    dudect_report(&ctx, "jp_add_internal");
    return dudect_passed(&ctx);
}

/*
 * test_point_ops — run scalar multiplication and point operation timing tests.
 *
 * Returns 0 if all tests pass, 1 if any test fails.
 */
static int test_point_ops(void)
{
    int failures = 0;

    printf("\n[7] Point operation timing tests (dudect)\n\n");

    printf("  scalar_multiply_ct: %d measurements (slow — ~256 point ops each)\n",
           SCALAR_MUL_MEASUREMENTS);
    if (!test_scalar_mul()) failures++;

    printf("\n  jp_add: %d measurements\n", JP_ADD_MEASUREMENTS);
    if (!test_jp_add()) failures++;

    printf("\n  Point timing: %d/2 passed\n\n", 2 - failures);
    return failures > 0 ? 1 : 0;
}

/* -----------------------------------------------------------------------
 * Helpers
 * ----------------------------------------------------------------------- */

static void print_uint256(const char *label, const uint256_t *v)
{
    printf("  %s = 0x%016llx%016llx%016llx%016llx\n",
           label,
           (unsigned long long)v->d[3],
           (unsigned long long)v->d[2],
           (unsigned long long)v->d[1],
           (unsigned long long)v->d[0]);
}

/* -----------------------------------------------------------------------
 * Main — verify compilation and basic function calls
 * ----------------------------------------------------------------------- */

int main(void)
{
    printf("secp256k1-native timing harness\n");
    printf("===============================\n\n");

    /* 1. Verify uint256_t creation and field reduction */
    printf("[1] Field reduction (fred_internal)\n");
    {
        uint256_t hi = {{ 0ULL, 0ULL, 0ULL, 0ULL }};
        uint256_t lo = GENERATOR_X;
        uint256_t r;
        fred_internal(&r, &hi, &lo);
        print_uint256("fred(0, GX)", &r);

        /* GX is already < P, so fred(0, GX) should equal GX */
        uint64_t diff = 0;
        int i;
        for (i = 0; i < 4; i++) diff |= (r.d[i] ^ GENERATOR_X.d[i]);
        if (diff != 0) {
            fprintf(stderr, "FAIL: fred(0, GX) != GX\n");
            return 1;
        }
        printf("  OK: fred(0, GX) == GX\n\n");
    }

    /* 2. Verify field multiplication */
    printf("[2] Field multiplication (fmul_internal)\n");
    {
        uint256_t r;
        fmul_internal(&r, &GENERATOR_X, &GENERATOR_Y);
        print_uint256("GX * GY mod P", &r);

        if (uint256_is_zero(&r)) {
            fprintf(stderr, "FAIL: GX * GY == 0 (unexpected)\n");
            return 1;
        }
        printf("  OK: non-zero product\n\n");
    }

    /* 3. Verify field inverse */
    printf("[3] Field inverse (finv_internal)\n");
    {
        uint256_t inv, product;
        finv_internal(&inv, &GENERATOR_X);
        fmul_internal(&product, &GENERATOR_X, &inv);
        print_uint256("GX * GX^(-1)", &product);

        /* Should be 1 */
        if (product.d[0] != 1 || product.d[1] != 0 ||
            product.d[2] != 0 || product.d[3] != 0) {
            fprintf(stderr, "FAIL: GX * GX^(-1) != 1\n");
            return 1;
        }
        printf("  OK: GX * GX^(-1) == 1\n\n");
    }

    /* 4. Verify Jacobian point doubling */
    printf("[4] Jacobian point double (jp_double_internal)\n");
    {
        uint256_t base[3];
        base[0] = GENERATOR_X;
        base[1] = GENERATOR_Y;
        memset(&base[2], 0, sizeof(uint256_t));
        base[2].d[0] = 1;  /* Z = 1 (affine) */

        uint256_t r[3];
        jp_double_internal(r, base);
        print_uint256("2G.X", &r[0]);
        print_uint256("2G.Y", &r[1]);
        print_uint256("2G.Z", &r[2]);

        if (uint256_is_zero(&r[2])) {
            fprintf(stderr, "FAIL: 2G is at infinity\n");
            return 1;
        }
        printf("  OK: 2G is a finite point\n\n");
    }

    /* 5. Report timing function works */
    printf("[5] Timing function\n");
    {
        uint64_t t0 = timing_now_ns();
        /* Brief workload to measure */
        uint256_t r;
        int i;
        r = GENERATOR_X;
        for (i = 0; i < 100; i++) {
            fsqr_internal(&r, &r);
        }
        uint64_t t1 = timing_now_ns();
        printf("  100 field squarings: %llu ns\n",
               (unsigned long long)(t1 - t0));
        printf("  OK: timing function operational\n\n");
    }

    printf("All verification checks passed.\n");

    int exit_code = 0;

    /* Run field operation timing tests */
    if (test_field_ops() != 0) {
        fprintf(stderr, "FAIL: field operation timing tests detected leakage\n");
        exit_code = 1;
    }

    /* Run scalar multiplication and point operation timing tests */
    if (test_point_ops() != 0) {
        fprintf(stderr, "FAIL: point operation timing tests detected leakage\n");
        exit_code = 1;
    }

    if (exit_code == 0) {
        printf("All checks passed.\n");
    }
    return exit_code;
}
