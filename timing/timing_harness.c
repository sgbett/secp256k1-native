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

    printf("All checks passed.\n");
    return 0;
}
