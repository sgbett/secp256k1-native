/*
 * asan_sweep.c — standalone ASan+UBSan sweep of the secp256k1-native C
 * internal ops. Calls every internal field/scalar/jacobian op over
 * structured edge cases and a large volume of random inputs.
 *
 * Build (from task certified line + sanitizers):
 *   cc -O2 -std=c99 -fcommon -g -fsanitize=address,undefined -fno-omit-frame-pointer \
 *     -I<timing> -I<ext> asan_sweep.c <timing>/ruby_stubs.c \
 *     <ext>/field.c <ext>/scalar.c <ext>/jacobian.c <ext>/secp256k1_native.c \
 *     -lm -o asan_sweep
 * Run: UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 ./asan_sweep
 */
#include "secp256k1_native.h"
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* ---- simple deterministic PRNG: splitmix64 ---- */
static uint64_t sm_state;
static uint64_t sm_next(void) {
    uint64_t z = (sm_state += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}
static void rand_u256(uint256_t *x) {
    x->d[0] = sm_next(); x->d[1] = sm_next();
    x->d[2] = sm_next(); x->d[3] = sm_next();
}

/* sink so the optimiser cannot delete the calls */
static volatile uint64_t SINK;
static void absorb(const uint256_t *x) {
    SINK ^= x->d[0] ^ x->d[1] ^ x->d[2] ^ x->d[3];
}
static void absorb3(const uint256_t r[3]) {
    absorb(&r[0]); absorb(&r[1]); absorb(&r[2]);
}

/* ---- structured edge values ---- */
static uint256_t V_ZERO, V_ONE, V_TWO, V_PM1, V_P, V_MAX, V_NM1, V_N, V_GX, V_GY;

static void set_limbs(uint256_t *x, uint64_t d0,uint64_t d1,uint64_t d2,uint64_t d3){
    x->d[0]=d0; x->d[1]=d1; x->d[2]=d2; x->d[3]=d3;
}
static void init_edges(void) {
    set_limbs(&V_ZERO,0,0,0,0);
    set_limbs(&V_ONE,1,0,0,0);
    set_limbs(&V_TWO,2,0,0,0);
    /* P-1 */
    set_limbs(&V_PM1,0xFFFFFFFEFFFFFC2EULL,0xFFFFFFFFFFFFFFFFULL,0xFFFFFFFFFFFFFFFFULL,0xFFFFFFFFFFFFFFFFULL);
    V_P = FIELD_P;
    set_limbs(&V_MAX,~0ULL,~0ULL,~0ULL,~0ULL); /* 2^256-1 */
    /* N-1 */
    set_limbs(&V_NM1,0xBFD25E8CD0364140ULL,0xBAAEDCE6AF48A03BULL,0xFFFFFFFFFFFFFFFEULL,0xFFFFFFFFFFFFFFFFULL);
    V_N = CURVE_N;
    /* G.x, G.y little-endian */
    set_limbs(&V_GX,0x59F2815B16F81798ULL,0x029BFCDB2DCE28D9ULL,0x55A06295CE870B07ULL,0x79BE667EF9DCBBACULL);
    set_limbs(&V_GY,0x9C47D08FFB10D4B8ULL,0xFD17B448A6855419ULL,0x5DA4FBFC0E1108A8ULL,0x483ADA7726A3C465ULL);
}

/* Exercise every field/scalar unary+binary op on a pair (a,b). */
static void exercise_field(const uint256_t *a, const uint256_t *b) {
    uint256_t r, hi, lo;
    fadd_internal(&r, a, b); absorb(&r);
    fsub_internal(&r, a, b); absorb(&r);
    fsub_internal(&r, b, a); absorb(&r);
    fmul_internal(&r, a, b); absorb(&r);
    fsqr_internal(&r, a);    absorb(&r);
    fneg_internal(&r, a);    absorb(&r);
    /* fred over a full 512-bit value (hi=b, lo=a) */
    fred_internal(&r, b, a); absorb(&r);
    /* finv/fsqrt: reduce first like the Ruby wrappers do (a may be >= P) */
    set_limbs(&hi,0,0,0,0); fred_internal(&lo, &hi, a);
    if (!uint256_is_zero(&lo)) { finv_internal(&r, &lo); absorb(&r); }
    { int ok = fsqrt_internal(&r, &lo); absorb(&r); SINK ^= (uint64_t)ok; }
}

static void exercise_scalar(const uint256_t *a, const uint256_t *b) {
    uint256_t r, hi, lo;
    scalar_add_internal(&r, a, b); absorb(&r);
    scalar_mul_internal(&r, a, b); absorb(&r);
    scalar_reduce(&r, b, a); absorb(&r);
    set_limbs(&hi,0,0,0,0); scalar_reduce(&lo, &hi, a);
    if (!uint256_is_zero(&lo)) { scalar_inv_internal(&r, &lo); absorb(&r); }
}

/* Build a Jacobian point array from three uint256_t. */
static void mkpt(uint256_t out[3], const uint256_t *x,const uint256_t *y,const uint256_t *z){
    out[0]=*x; out[1]=*y; out[2]=*z;
}

static void exercise_jacobian(const uint256_t p[3], const uint256_t q[3]) {
    uint256_t r[3], n[3];
    jp_double_internal(r, p); absorb3(r);
    jp_neg_internal(n, p);    absorb3(n);
    jp_add_internal(r, p, q); absorb3(r);
    jp_add_internal(r, q, p); absorb3(r);
    /* equal points -> doubling path */
    jp_add_internal(r, p, p); absorb3(r);
    /* negated points -> infinity path */
    jp_add_internal(r, p, n); absorb3(r);
    /* aliasing like the ladder: r aliases an input */
    { uint256_t a[3]; memcpy(a,p,sizeof a); jp_add_internal(a, a, q); absorb3(a); }
    { uint256_t a[3]; memcpy(a,p,sizeof a); jp_double_internal(a, a); absorb3(a); }
}

int main(int argc, char **argv) {
    init_edges();
    long iters = (argc > 1) ? atol(argv[1]) : 3000000L;
    sm_state = (argc > 2) ? (uint64_t)atoll(argv[2]) : 0xDEADBEEFCAFEBABEULL;
    /* mode: 0=all (default), 1=field/scalar only (fast, high volume),
       2=jacobian/ladder only */
    int mode = (argc > 3) ? atoi(argv[3]) : 0;

    /* ---------- 1. Structured edge cases ---------- */
    const uint256_t *edges[] = {
        &V_ZERO,&V_ONE,&V_TWO,&V_PM1,&V_P,&V_MAX,&V_NM1,&V_N,&V_GX,&V_GY
    };
    int ne = (int)(sizeof(edges)/sizeof(edges[0]));
    for (int i=0;i<ne;i++)
        for (int j=0;j<ne;j++) {
            exercise_field(edges[i],edges[j]);
            exercise_scalar(edges[i],edges[j]);
        }

    /* Jacobian edge points: infinity, [Gx,Gy,1], [x,0,z] (Y=0 doubling),
       Z=0 with nonzero X/Y, large coords. */
    uint256_t INF[3]; mkpt(INF,&V_ZERO,&V_ONE,&V_ZERO);
    uint256_t G[3];   mkpt(G,&V_GX,&V_GY,&V_ONE);
    uint256_t YZERO[3]; mkpt(YZERO,&V_GX,&V_ZERO,&V_ONE);
    uint256_t ZZERO[3]; mkpt(ZZERO,&V_GX,&V_GY,&V_ZERO);
    uint256_t BIG[3]; mkpt(BIG,&V_MAX,&V_MAX,&V_MAX);
    uint256_t Pco[3]; mkpt(Pco,&V_P,&V_P,&V_P);
    uint256_t *jpts[] = {INF,G,YZERO,ZZERO,BIG,Pco};
    int nj = (int)(sizeof(jpts)/sizeof(jpts[0]));
    for (int i=0;i<nj;i++)
        for (int j=0;j<nj;j++)
            exercise_jacobian(jpts[i],jpts[j]);

    /* scalar_multiply_ct over edge scalars (must be < N) and edge bases. */
    const uint256_t *scal[] = {&V_ZERO,&V_ONE,&V_TWO,&V_NM1};
    for (int s=0;s<4;s++)
        for (int i=0;i<nj;i++) {
            /* clamp scalar < N by reducing */
            uint256_t k, hi; set_limbs(&hi,0,0,0,0);
            scalar_reduce(&k,&hi,scal[s]);
            uint256_t rr[3];
            scalar_multiply_ct_internal(rr,&k,jpts[i]);
            absorb3(rr);
        }

    /* ---------- 2. Large random volume ---------- */
    for (long it=0; it<iters; it++) {
        uint256_t a,b; rand_u256(&a); rand_u256(&b);
        if (mode != 2) {
            exercise_field(&a,&b);
            exercise_scalar(&a,&b);
        }

        if (mode != 1 && (it & 7) == 0) {
            /* jacobian + ladder less often (much heavier) */
            uint256_t x,y,z; rand_u256(&x); rand_u256(&y); rand_u256(&z);
            uint256_t qx,qy,qz; rand_u256(&qx); rand_u256(&qy); rand_u256(&qz);
            uint256_t p3[3]={x,y,z}, q3[3]={qx,qy,qz};
            exercise_jacobian(p3,q3);

            uint256_t k,hi; set_limbs(&hi,0,0,0,0);
            uint256_t kr; rand_u256(&kr); scalar_reduce(&k,&hi,&kr);
            uint256_t rr[3];
            scalar_multiply_ct_internal(rr,&k,p3);
            absorb3(rr);
        }
        if ((it % 500000)==0) { fprintf(stderr,"."); fflush(stderr); }
    }
    fprintf(stderr,"\n");

    printf("DONE iters=%ld sink=%llu\n", iters, (unsigned long long)SINK);
    return 0;
}
