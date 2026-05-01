/*
 * dudect.c — Online Welch's t-test for timing leakage detection
 *
 * Implements the statistical core of the dudect methodology.
 * See dudect.h for API documentation and methodology references.
 */

#include "dudect.h"
#include <math.h>
#include <stdio.h>

/* -----------------------------------------------------------------------
 * Initialisation
 * ----------------------------------------------------------------------- */

void dudect_init(dudect_ctx_t *ctx)
{
    ctx->classes[0].n    = 0;
    ctx->classes[0].mean = 0.0;
    ctx->classes[0].m2   = 0.0;

    ctx->classes[1].n    = 0;
    ctx->classes[1].mean = 0.0;
    ctx->classes[1].m2   = 0.0;

    ctx->threshold = DUDECT_THRESHOLD_DEFAULT;
}

/* -----------------------------------------------------------------------
 * Measurement accumulation — Welford's online algorithm
 *
 * For each new value x:
 *   n     += 1
 *   delta  = x - mean
 *   mean  += delta / n
 *   delta2 = x - mean        (using the updated mean)
 *   M2    += delta * delta2
 *
 * This is numerically stable for millions of samples — unlike the
 * naive (sum, sum-of-squares) approach which suffers from catastrophic
 * cancellation.
 * ----------------------------------------------------------------------- */

void dudect_add(dudect_ctx_t *ctx, int class_id, double measurement)
{
    welford_t *w;
    double delta, delta2;

    w = &ctx->classes[class_id];

    w->n += 1;
    delta   = measurement - w->mean;
    w->mean += delta / (double)w->n;
    delta2  = measurement - w->mean;
    w->m2  += delta * delta2;
}

/* -----------------------------------------------------------------------
 * Welch's t-statistic
 *
 *         mean_a - mean_b
 *   t = ---------------------
 *       sqrt(var_a/n_a + var_b/n_b)
 *
 * where var = M2 / (n - 1)  (Bessel-corrected sample variance).
 *
 * Returns 0.0 when the statistic cannot be meaningfully computed:
 *   - Either class has fewer than 2 samples (variance undefined)
 *   - Both variances are zero (denominator would be zero)
 * ----------------------------------------------------------------------- */

double dudect_t_statistic(const dudect_ctx_t *ctx)
{
    const welford_t *a = &ctx->classes[0];
    const welford_t *b = &ctx->classes[1];
    double var_a, var_b, denom;

    /* Need at least 2 samples per class for sample variance */
    if (a->n < 2 || b->n < 2)
        return 0.0;

    var_a = a->m2 / (double)(a->n - 1);
    var_b = b->m2 / (double)(b->n - 1);

    denom = var_a / (double)a->n + var_b / (double)b->n;

    /* Both distributions have zero variance — means are exact but
     * the t-statistic is undefined.  Return 0 (indistinguishable). */
    if (denom <= 0.0)
        return 0.0;

    return (a->mean - b->mean) / sqrt(denom);
}

/* -----------------------------------------------------------------------
 * Pass/fail determination
 * ----------------------------------------------------------------------- */

int dudect_passed(const dudect_ctx_t *ctx)
{
    double t;

    /* Insufficient data — cannot declare pass */
    if (ctx->classes[0].n < 2 || ctx->classes[1].n < 2)
        return 0;

    t = dudect_t_statistic(ctx);
    return fabs(t) < ctx->threshold ? 1 : 0;
}

/* -----------------------------------------------------------------------
 * Human-readable report
 * ----------------------------------------------------------------------- */

void dudect_report(const dudect_ctx_t *ctx, const char *label)
{
    double t = dudect_t_statistic(ctx);
    int    pass = dudect_passed(ctx);

    printf("dudect: %-30s  ", label);
    printf("n0=%-8ld n1=%-8ld  ", ctx->classes[0].n, ctx->classes[1].n);
    printf("mean0=%12.3f  mean1=%12.3f  ", ctx->classes[0].mean, ctx->classes[1].mean);
    printf("t=%+9.4f  ", t);
    printf("%s\n", pass ? "PASS" : "FAIL");
}
