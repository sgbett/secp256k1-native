/*
 * dudect.h — Online Welch's t-test for timing leakage detection
 *
 * Implements the statistical core of the dudect methodology
 * (Reparaz, Gierlichs & Verbauwhede, 2017).
 *
 * Two classes of timing measurements are accumulated using Welford's
 * online algorithm for numerically stable running mean and variance.
 * Welch's t-statistic then quantifies whether the two classes have
 * distinguishable means — if |t| >= threshold, there is evidence of
 * timing leakage.
 *
 * Threshold: |t| < 4.5 is "pass" (the standard dudect convention,
 * corresponding to a two-tailed p-value of approximately 7e-6 for
 * large sample sizes).
 */

#ifndef DUDECT_H
#define DUDECT_H

/* Default threshold for pass/fail determination.
 * |t| < 4.5 corresponds to ~99.9993% confidence that the means
 * are indistinguishable — the standard convention in dudect. */
#define DUDECT_THRESHOLD_DEFAULT 4.5

/* Welford accumulator for online mean and variance computation.
 * Tracks count, running mean, and M2 (sum of squared deviations
 * from the current mean) for a single measurement class. */
typedef struct {
    long   n;     /* sample count                                */
    double mean;  /* running mean                                */
    double m2;    /* sum of squared deviations from running mean */
} welford_t;

/* Two-class comparison context for dudect analysis.
 * Contains one Welford accumulator per class and the
 * pass/fail threshold. */
typedef struct {
    welford_t classes[2];  /* class 0 and class 1 accumulators */
    double    threshold;   /* |t| must be below this to pass   */
} dudect_ctx_t;

/* Initialise a dudect context with zeroed accumulators and the
 * default threshold (4.5). */
void dudect_init(dudect_ctx_t *ctx);

/* Add a timing measurement to the specified class (0 or 1).
 * Uses Welford's online algorithm for numerically stable
 * incremental mean and variance. */
void dudect_add(dudect_ctx_t *ctx, int class_id, double measurement);

/* Compute Welch's t-statistic from the accumulated measurements.
 * Returns 0.0 if either class has fewer than 2 samples (variance
 * is undefined) or if both variances are zero. */
double dudect_t_statistic(const dudect_ctx_t *ctx);

/* Return 1 if |t| < threshold (no detectable leakage), 0 otherwise.
 * Returns 0 if insufficient samples to compute a meaningful statistic. */
int dudect_passed(const dudect_ctx_t *ctx);

/* Print a summary to stdout: label, sample counts, means,
 * t-statistic, and pass/fail verdict. */
void dudect_report(const dudect_ctx_t *ctx, const char *label);

#endif /* DUDECT_H */
