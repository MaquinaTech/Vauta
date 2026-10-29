#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""The statistics of the evaluation gates, in one place (standard library only, Python 3.12 or later).

Import it from the reports (`aggregate.py`, `questions_report.py`) or from a one-off analysis next to them:

    sys.path.insert(0, "tools/llm-eval"); import stats

What each gate reports is an estimate, its 95% interval and, for a gate on a rate, P(rate >= gate). The procedures:

- `wilson(k, n)`: the Wilson score interval of a proportion.
- `exact_sign(wins, losses)`: the exact two-sided sign test on paired units (ties are dropped before calling it).
  `mcnemar_exact(b, c)` is the same test on the discordant pairs of a 2x2 table.
- `cluster_bootstrap(clusters, statistic)`: a percentile interval that resamples whole meetings (5,000 resamples, seed 1 by
  default), so the passages of one meeting are never treated as independent.
- `cohen_kappa(a, b)` and `weighted_kappa(a, b, categories)` (quadratic weights): agreement between two graders.
- `beta_gate(k, n, gate)`: the Jeffreys posterior Beta(k + 1/2, n - k + 1/2) of a rate and P(rate >= gate).
  `clustered_beta_gate(per_meeting, gate)` first shrinks k and n by the design effect of the meetings (Kish's effective sample size),
  so twenty items from one meeting do not count as twenty independent ones.
- `tost_paired(differences, margin)`: two one-sided t tests on paired differences (new minus old); `noninferior` when the lower test
  rejects "new is worse by the margin or more", `equivalent` when both do. The margin is fixed before the run.
- `power_paired(n, delta, sd, margin)`: the power of the non-inferiority test for a true mean difference `delta` (normal approximation).
- `holm(p)` and `bh(p)`: adjusted p-values for several gates at once (Holm's step-down; Benjamini-Hochberg).
- `spread(values)`: the dispersion of one arm over repeated runs (each arm runs at least three times).

The tests are `eval/tests/test_stats.py` (`python3 -I -m unittest discover -s eval/tests -p 'test_stats.py'`).
"""
import math
import random
import statistics
from statistics import NormalDist

Z95 = NormalDist().inv_cdf(0.975)


# MARK: Proportions


def wilson(k, n, z=Z95):
    """The Wilson score interval (lo, hi) of k successes in n trials. (0.0, 1.0) when n is 0."""
    if n == 0:
        return (0.0, 1.0)
    p = k / n
    denominator = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denominator
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denominator
    return (max(0.0, centre - half), min(1.0, centre + half))


def _binomial_tail(k, n):
    """P(X <= k) for X ~ Binomial(n, 1/2)."""
    return sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n


def exact_sign(wins, losses):
    """The exact two-sided sign test: p for `wins` against `losses` under no difference (1.0 with no untied units)."""
    n = wins + losses
    if n == 0:
        return 1.0
    return min(1.0, 2 * _binomial_tail(min(wins, losses), n))


def mcnemar_exact(b, c):
    """The exact McNemar test on the discordant pairs (b: only the first is right, c: only the second is right)."""
    return exact_sign(b, c)


# MARK: Bootstrap


def cluster_bootstrap(clusters, statistic, n=5000, seed=1, level=0.95):
    """The percentile interval (lo, hi) of `statistic(sample)` over `n` resamples of whole clusters (meetings), with replacement.

    `clusters` is a list with one entry per meeting (whatever `statistic` reads: a list of units, a pair of counts…). A resample
    whose statistic is None (nothing to measure in it) is skipped; (None, None) when every resample is."""
    rng = random.Random(seed)
    values = []
    for _ in range(n):
        sample = [clusters[rng.randrange(len(clusters))] for _ in clusters]
        value = statistic(sample)
        if value is not None:
            values.append(value)
    if not values:
        return (None, None)
    values.sort()
    tail = (1 - level) / 2
    return (_quantile(values, tail), _quantile(values, 1 - tail))


def _quantile(sorted_values, q):
    """The q quantile with linear interpolation between order statistics (numpy's default)."""
    position = q * (len(sorted_values) - 1)
    low = math.floor(position)
    high = min(low + 1, len(sorted_values) - 1)
    return sorted_values[low] + (sorted_values[high] - sorted_values[low]) * (position - low)


def ratio(sample):
    """Pooled k / n over a sample of (k, n) per meeting, for `cluster_bootstrap`; None when the sample has no trials."""
    n = sum(c[1] for c in sample)
    return sum(c[0] for c in sample) / n if n else None


# MARK: Agreement


def cohen_kappa(a, b):
    """Cohen's kappa of two graders' labels for the same items (1.0 when both always give the one same label)."""
    return weighted_kappa(a, b, sorted(set(a) | set(b), key=str), quadratic=False)


def weighted_kappa(a, b, categories, quadratic=True):
    """Kappa with quadratic disagreement weights over ordered `categories` (with `quadratic=False`, Cohen's unweighted kappa)."""
    if len(a) != len(b) or not a:
        raise ValueError("two non-empty lists of the same length")
    index = {c: i for i, c in enumerate(categories)}
    k = len(categories)
    if k < 2:
        return 1.0
    observed = [[0] * k for _ in range(k)]
    for x, y in zip(a, b):
        observed[index[x]][index[y]] += 1
    n = len(a)
    rows = [sum(r) for r in observed]
    columns = [sum(observed[i][j] for i in range(k)) for j in range(k)]

    def weight(i, j):
        return ((i - j) / (k - 1)) ** 2 if quadratic else (0.0 if i == j else 1.0)

    seen = sum(weight(i, j) * observed[i][j] for i in range(k) for j in range(k)) / n
    chance = sum(weight(i, j) * rows[i] * columns[j] for i in range(k) for j in range(k)) / (n * n)
    return 1.0 if chance == 0 else 1 - seen / chance


# MARK: Beta and t distributions


def _beta_fraction(a, b, x):
    """The continued fraction of the regularized incomplete beta function (modified Lentz)."""
    tiny, eps = 1e-300, 3e-16
    c, d = 1.0, 1.0 - (a + b) * x / (a + 1)
    d = 1.0 / (d if abs(d) > tiny else tiny)
    h = d
    for m in range(1, 1000):
        for numerator in (m * (b - m) * x / ((a + 2 * m - 1) * (a + 2 * m)), -(a + m) * (a + b + m) * x / ((a + 2 * m) * (a + 2 * m + 1))):
            d = 1.0 + numerator * d
            d = 1.0 / (d if abs(d) > tiny else tiny)
            c = 1.0 + numerator / c
            c = c if abs(c) > tiny else tiny
            h *= d * c
        if abs(d * c - 1.0) < eps:
            return h
    return h


def beta_cdf(x, a, b):
    """The regularized incomplete beta function I_x(a, b): P(X <= x) for X ~ Beta(a, b)."""
    if x <= 0:
        return 0.0
    if x >= 1:
        return 1.0
    front = math.exp(math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b) + a * math.log(x) + b * math.log1p(-x))
    if x < (a + 1) / (a + b + 2):
        return front * _beta_fraction(a, b, x) / a
    return 1.0 - front * _beta_fraction(b, a, 1 - x) / b


def t_cdf(t, df):
    """P(T <= t) for Student's t with `df` degrees of freedom."""
    tail = 0.5 * beta_cdf(df / (df + t * t), df / 2, 0.5)
    return 1 - tail if t > 0 else tail


def t_quantile(q, df):
    """The q quantile of Student's t (bisection on `t_cdf`)."""
    low, high = -1e3, 1e3
    for _ in range(200):
        middle = (low + high) / 2
        if t_cdf(middle, df) < q:
            low = middle
        else:
            high = middle
    return (low + high) / 2


def _bisect(f, low, high, target):
    """x in [low, high] with f(x) = target, for an increasing f."""
    for _ in range(200):
        middle = (low + high) / 2
        if f(middle) < target:
            low = middle
        else:
            high = middle
    return (low + high) / 2


# MARK: Gates on a rate


def beta_gate(k, n, gate, prior=(0.5, 0.5), level=0.95):
    """The Jeffreys posterior of a rate after k successes in n trials: its mean, equal-tailed interval and P(rate >= gate)."""
    a, b = k + prior[0], n - k + prior[1]
    tail = (1 - level) / 2
    return {"estimate": a / (a + b),
            "interval": (_bisect(lambda x: beta_cdf(x, a, b), 0.0, 1.0, tail), _bisect(lambda x: beta_cdf(x, a, b), 0.0, 1.0, 1 - tail)),
            "p_at_least_gate": 1 - beta_cdf(gate, a, b)}


def design_effect(per_meeting):
    """The design effect of a pooled rate over meetings given as (k, n): the variance of the ratio estimator across meetings over the
    binomial variance (1.0 when the meetings agree as well as independent items would, never below 1.0)."""
    pairs = [(k, n) for k, n in per_meeting if n > 0]
    total = sum(n for _, n in pairs)
    if len(pairs) < 2 or total == 0:
        return 1.0
    p = sum(k for k, _ in pairs) / total
    if p in (0.0, 1.0):
        return 1.0
    m = len(pairs)
    mean_n = total / m
    # The variance of the ratio estimator over m meetings, and that of a binomial proportion over the same number of items.
    between = sum((k - p * n) ** 2 for k, n in pairs) / (m - 1) / (m * mean_n * mean_n)
    binomial = p * (1 - p) / total
    return max(1.0, between / binomial)


def clustered_beta_gate(per_meeting, gate, prior=(0.5, 0.5), level=0.95):
    """`beta_gate` on the pooled counts of (k, n) per meeting, with k and n divided by the design effect first."""
    k = sum(c[0] for c in per_meeting)
    n = sum(c[1] for c in per_meeting)
    deff = design_effect(per_meeting)
    result = beta_gate(k / deff, n / deff, gate, prior, level)
    result["design_effect"] = deff
    result["effective_n"] = n / deff
    return result


# MARK: Paired comparisons


def tost_paired(differences, margin, alpha=0.05):
    """Two one-sided t tests on paired differences (new minus old, higher is better) against the equivalence margin."""
    n = len(differences)
    if n < 2:
        raise ValueError("at least two paired differences")
    mean = statistics.fmean(differences)
    sd = statistics.stdev(differences)
    df = n - 1
    se = sd / math.sqrt(n)
    if se == 0:
        p_lower = 0.0 if mean > -margin else 1.0
        p_upper = 0.0 if mean < margin else 1.0
    else:
        p_lower = 1 - t_cdf((mean + margin) / se, df)   # H0: mean <= -margin
        p_upper = t_cdf((mean - margin) / se, df)       # H0: mean >= +margin
    half = t_quantile(1 - alpha, df) * se
    return {"mean": mean, "sd": sd, "n": n, "interval": (mean - half, mean + half), "p_lower": p_lower, "p_upper": p_upper,
            "noninferior": p_lower < alpha, "equivalent": max(p_lower, p_upper) < alpha}


def power_paired(n, delta, sd, margin, alpha=0.05):
    """The power of the non-inferiority test of `tost_paired` (its lower test) with n pairs when the true mean difference is `delta`
    and the differences have standard deviation `sd` (normal approximation; slightly optimistic for small n)."""
    se = sd / math.sqrt(n)
    return NormalDist().cdf((delta + margin) / se - NormalDist().inv_cdf(1 - alpha))


# MARK: Several gates


def holm(pvalues):
    """Holm's step-down adjusted p-values, in the input order."""
    order = sorted(range(len(pvalues)), key=lambda i: pvalues[i])
    m = len(pvalues)
    adjusted = [0.0] * m
    running = 0.0
    for rank, i in enumerate(order):
        running = max(running, (m - rank) * pvalues[i])
        adjusted[i] = min(1.0, running)
    return adjusted


def bh(pvalues):
    """Benjamini-Hochberg adjusted p-values (q-values), in the input order."""
    order = sorted(range(len(pvalues)), key=lambda i: pvalues[i], reverse=True)
    m = len(pvalues)
    adjusted = [0.0] * m
    running = 1.0
    for position, i in enumerate(order):
        rank = m - position
        running = min(running, pvalues[i] * m / rank)
        adjusted[i] = running
    return adjusted


# MARK: Repeated runs


def spread(values):
    """The dispersion of one arm over repeated runs: n, min, median, max and the sample standard deviation (None for one run)."""
    values = list(values)
    return {"n": len(values), "min": min(values), "median": statistics.median(values), "max": max(values),
            "sd": statistics.stdev(values) if len(values) > 1 else None}
