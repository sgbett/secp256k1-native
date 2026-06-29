/* Differential fuzzing harness for secp256k1-native C internals.
 * Reads lines "OP HEX...", writes hex results. All u256 hex big-endian.
 */
#include "secp256k1_native.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int hex_to_u256(const char *hex, uint256_t *out) {
    char buf[65];
    size_t len = strlen(hex);
    if (len > 64) return -1;
    memset(buf, '0', 64);
    memcpy(buf + (64 - len), hex, len);
    buf[64] = '\0';
    memset(out, 0, sizeof(*out));
    for (int limb = 0; limb < 4; limb++) {
        char tmp[17];
        memcpy(tmp, buf + (3 - limb) * 16, 16);
        tmp[16] = '\0';
        out->d[limb] = strtoull(tmp, NULL, 16);
    }
    return 0;
}

static void print_u256(const uint256_t *v) {
    printf("%016llx%016llx%016llx%016llx",
        (unsigned long long)v->d[3], (unsigned long long)v->d[2],
        (unsigned long long)v->d[1], (unsigned long long)v->d[0]);
}

int main(void) {
    char line[1024];
    char op[32];
    char h[8][80];
    uint256_t a, b, k;
    while (fgets(line, sizeof(line), stdin)) {
        /* Zero h[] each iteration so any sscanf slot left unmatched by a
         * short input line reads as an empty string rather than uninitialised
         * stack. hex_to_u256("") returns the all-zero u256 — the per-op
         * result will be wrong, but the harness will not crash. */
        memset(h, 0, sizeof h);
        int n = sscanf(line, "%31s %79s %79s %79s %79s %79s %79s %79s",
                       op, h[0], h[1], h[2], h[3], h[4], h[5], h[6]);
        if (n < 1) continue;
        if (strcmp(op, "fmul") == 0) {
            hex_to_u256(h[0], &a); hex_to_u256(h[1], &b);
            uint256_t r; fmul_internal(&r, &a, &b); print_u256(&r); printf("\n");
        } else if (strcmp(op, "fsqr") == 0) {
            hex_to_u256(h[0], &a);
            uint256_t r; fsqr_internal(&r, &a); print_u256(&r); printf("\n");
        } else if (strcmp(op, "fadd") == 0) {
            hex_to_u256(h[0], &a); hex_to_u256(h[1], &b);
            uint256_t r; fadd_internal(&r, &a, &b); print_u256(&r); printf("\n");
        } else if (strcmp(op, "fsub") == 0) {
            hex_to_u256(h[0], &a); hex_to_u256(h[1], &b);
            uint256_t r; fsub_internal(&r, &a, &b); print_u256(&r); printf("\n");
        } else if (strcmp(op, "fneg") == 0) {
            hex_to_u256(h[0], &a);
            uint256_t r; fneg_internal(&r, &a); print_u256(&r); printf("\n");
        } else if (strcmp(op, "finv") == 0) {
            hex_to_u256(h[0], &a);
            uint256_t r; finv_internal(&r, &a); print_u256(&r); printf("\n");
        } else if (strcmp(op, "fsqrt") == 0) {
            hex_to_u256(h[0], &a);
            uint256_t r; int ok = fsqrt_internal(&r, &a);
            printf("%d ", ok); print_u256(&r); printf("\n");
        } else if (strcmp(op, "fred") == 0) {
            hex_to_u256(h[0], &a); hex_to_u256(h[1], &b);
            uint256_t r; fred_internal(&r, &a, &b); print_u256(&r); printf("\n");
        } else if (strcmp(op, "smul") == 0) {
            hex_to_u256(h[0], &a); hex_to_u256(h[1], &b);
            uint256_t r; scalar_mul_internal(&r, &a, &b); print_u256(&r); printf("\n");
        } else if (strcmp(op, "sadd") == 0) {
            hex_to_u256(h[0], &a); hex_to_u256(h[1], &b);
            uint256_t r; scalar_add_internal(&r, &a, &b); print_u256(&r); printf("\n");
        } else if (strcmp(op, "sinv") == 0) {
            hex_to_u256(h[0], &a);
            uint256_t r; scalar_inv_internal(&r, &a); print_u256(&r); printf("\n");
        } else if (strcmp(op, "sreduce") == 0) {
            hex_to_u256(h[0], &a); hex_to_u256(h[1], &b);
            uint256_t r; scalar_reduce(&r, &a, &b); print_u256(&r); printf("\n");
        } else if (strcmp(op, "jdouble") == 0) {
            uint256_t p[3], r[3];
            hex_to_u256(h[0], &p[0]); hex_to_u256(h[1], &p[1]); hex_to_u256(h[2], &p[2]);
            jp_double_internal(r, p);
            print_u256(&r[0]); printf(" "); print_u256(&r[1]); printf(" "); print_u256(&r[2]); printf("\n");
        } else if (strcmp(op, "jadd") == 0) {
            uint256_t p[3], q[3], r[3];
            hex_to_u256(h[0], &p[0]); hex_to_u256(h[1], &p[1]); hex_to_u256(h[2], &p[2]);
            hex_to_u256(h[3], &q[0]); hex_to_u256(h[4], &q[1]); hex_to_u256(h[5], &q[2]);
            jp_add_internal(r, p, q);
            print_u256(&r[0]); printf(" "); print_u256(&r[1]); printf(" "); print_u256(&r[2]); printf("\n");
        } else if (strcmp(op, "jneg") == 0) {
            uint256_t p[3], r[3];
            hex_to_u256(h[0], &p[0]); hex_to_u256(h[1], &p[1]); hex_to_u256(h[2], &p[2]);
            jp_neg_internal(r, p);
            print_u256(&r[0]); printf(" "); print_u256(&r[1]); printf(" "); print_u256(&r[2]); printf("\n");
        } else if (strcmp(op, "smulct") == 0) {
            uint256_t base[3], r[3];
            hex_to_u256(h[0], &k);
            hex_to_u256(h[1], &base[0]); hex_to_u256(h[2], &base[1]); hex_to_u256(h[3], &base[2]);
            scalar_multiply_ct_internal(r, &k, base);
            print_u256(&r[0]); printf(" "); print_u256(&r[1]); printf(" "); print_u256(&r[2]); printf("\n");
        } else {
            printf("ERR unknown op %s\n", op);
        }
    }
    return 0;
}
