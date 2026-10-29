# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Unit tests of tools/llm-eval/stats.py against known values (standard library only).
python3 -I -m unittest discover -s eval/tests -p 'test_stats.py'"""
import math
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "llm-eval"))
import stats  # noqa: E402


def simpson(f, a, b, n=20000):
    """A numerical integral, to check the closed forms independently."""
    h = (b - a) / n
    return h / 3 * (f(a) + f(b) + sum((4 if i % 2 else 2) * f(a + i * h) for i in range(1, n)))


class ProportionTests(unittest.TestCase):
    def test_wilson(self):
        lo, hi = stats.wilson(0, 10)
        self.assertEqual(lo, 0.0)
        self.assertAlmostEqual(hi, stats.Z95 ** 2 / (10 + stats.Z95 ** 2), places=12)   # 0.2775
        lo, hi = stats.wilson(26, 26)
        self.assertAlmostEqual(lo, 26 / (26 + stats.Z95 ** 2), places=12)              # 0.8713
        self.assertEqual(hi, 1.0)
        lo, hi = stats.wilson(81, 263)                                                  # 0.2553 to 0.3662
        self.assertAlmostEqual(lo, 0.2553, places=4)
        self.assertAlmostEqual(hi, 0.3662, places=4)
        self.assertEqual(stats.wilson(0, 0), (0.0, 1.0))

    def test_exact_sign_and_mcnemar(self):
        self.assertAlmostEqual(stats.exact_sign(10, 2), 2 * 79 / 4096, places=12)      # P(X <= 2 | 12, 1/2) = 79/4096
        self.assertAlmostEqual(stats.exact_sign(2, 10), stats.exact_sign(10, 2), places=12)
        self.assertEqual(stats.exact_sign(5, 5), 1.0)
        self.assertEqual(stats.exact_sign(0, 0), 1.0)
        self.assertAlmostEqual(stats.exact_sign(6, 0), 2 / 64, places=12)
        self.assertEqual(stats.mcnemar_exact(3, 9), stats.exact_sign(3, 9))


class BootstrapTests(unittest.TestCase):
    def test_cluster_bootstrap(self):
        meetings = [(8, 10), (5, 10), (9, 10), (2, 10), (7, 10), (6, 10)]
        lo, hi = stats.cluster_bootstrap(meetings, stats.ratio)
        self.assertLess(lo, stats.ratio(meetings))
        self.assertGreater(hi, stats.ratio(meetings))
        self.assertEqual((lo, hi), stats.cluster_bootstrap(meetings, stats.ratio), "the same seed gives the same interval")
        self.assertNotEqual((lo, hi), stats.cluster_bootstrap(meetings, stats.ratio, seed=2))
        # Meetings that all agree leave nothing to vary.
        self.assertEqual(stats.cluster_bootstrap([(3, 4)] * 5, stats.ratio), (0.75, 0.75))
        self.assertEqual(stats.cluster_bootstrap([(0, 0)] * 3, stats.ratio), (None, None))

    def test_quantile_interpolates_like_numpy(self):
        self.assertEqual(stats._quantile([1, 2, 3, 4], 0.5), 2.5)
        self.assertEqual(stats._quantile([1, 2, 3, 4], 0.0), 1)
        self.assertEqual(stats._quantile([1, 2, 3, 4], 1.0), 4)
        self.assertAlmostEqual(stats._quantile([0, 10], 0.025), 0.25)


class AgreementTests(unittest.TestCase):
    def test_cohen_kappa(self):
        # 50 items: both yes 20, yes/no 5, no/yes 10, both no 15 -> p_o 0.70, p_e 0.50, kappa 0.40.
        a = ["yes"] * 25 + ["no"] * 25
        b = ["yes"] * 20 + ["no"] * 5 + ["yes"] * 10 + ["no"] * 15
        self.assertAlmostEqual(stats.cohen_kappa(a, b), 0.4, places=12)
        self.assertEqual(stats.cohen_kappa(a, a), 1.0)
        self.assertEqual(stats.cohen_kappa(["x"] * 4, ["x"] * 4), 1.0)

    def test_weighted_kappa(self):
        a = ["yes"] * 25 + ["no"] * 25
        b = ["yes"] * 20 + ["no"] * 5 + ["yes"] * 10 + ["no"] * 15
        self.assertAlmostEqual(stats.weighted_kappa(a, b, ["no", "yes"]), stats.cohen_kappa(a, b), places=12, msg="two categories: the weights are 0 and 1")
        # Ordered grades: a disagreement by one step costs less than one by two.
        grades = [0, 1, 2]
        near = stats.weighted_kappa([0, 1, 2, 0, 1, 2], [1, 1, 2, 0, 2, 2], grades)
        far = stats.weighted_kappa([0, 1, 2, 0, 1, 2], [2, 1, 2, 0, 0, 2], grades)
        self.assertGreater(near, far)
        # By hand: observed weighted disagreement 2 * 0.25 / 6, chance from the margins (2, 2, 2) and (1, 2, 3).
        rows, columns = [2, 2, 2], [1, 2, 3]
        chance = sum(((i - j) / 2) ** 2 * rows[i] * columns[j] for i in range(3) for j in range(3)) / 36
        self.assertAlmostEqual(near, 1 - (0.5 / 6) / chance, places=12)
        with self.assertRaises(ValueError):
            stats.weighted_kappa([0], [0, 1], grades)


class DistributionTests(unittest.TestCase):
    def test_beta_cdf_identities(self):
        for x in (0.1, 0.37, 0.5, 0.9):
            self.assertAlmostEqual(stats.beta_cdf(x, 1, 1), x, places=12)
            self.assertAlmostEqual(stats.beta_cdf(x, 3.5, 1), x ** 3.5, places=12)
            self.assertAlmostEqual(stats.beta_cdf(x, 1, 4), 1 - (1 - x) ** 4, places=12)
            self.assertAlmostEqual(stats.beta_cdf(x, 2.5, 7) + stats.beta_cdf(1 - x, 7, 2.5), 1.0, places=12)
        self.assertAlmostEqual(stats.beta_cdf(0.5, 13.5, 13.5), 0.5, places=12)
        self.assertEqual(stats.beta_cdf(0, 2, 3), 0.0)
        self.assertEqual(stats.beta_cdf(1, 2, 3), 1.0)

    def test_beta_cdf_against_an_integral(self):
        a, b = 26.5, 0.5   # Jeffreys after 26 of 26; the density's singularity at 1 is left out of the integral
        density = lambda p: math.exp((a - 1) * math.log(p) + (b - 1) * math.log1p(-p) - (math.lgamma(a) + math.lgamma(b) - math.lgamma(a + b)))
        self.assertAlmostEqual(stats.beta_cdf(0.9, a, b), simpson(density, 1e-12, 0.9), places=8)

    def test_t_distribution(self):
        self.assertAlmostEqual(stats.t_cdf(1.0, 1), 0.75, places=12)                   # Cauchy
        self.assertAlmostEqual(stats.t_cdf(0.0, 7), 0.5, places=12)
        self.assertAlmostEqual(stats.t_cdf(2.228139, 10), 0.975, places=6)             # the table's 97.5% point for 10 df
        self.assertAlmostEqual(stats.t_cdf(-2.228139, 10), 0.025, places=6)
        self.assertAlmostEqual(stats.t_quantile(0.95, 23), 1.713872, places=5)
        self.assertAlmostEqual(stats.t_cdf(1.96, 10_000), 0.975, places=4)             # close to the normal


class GateTests(unittest.TestCase):
    def test_beta_gate(self):
        g = stats.beta_gate(26, 26, 0.9)
        self.assertAlmostEqual(g["estimate"], 26.5 / 27, places=12)
        self.assertAlmostEqual(g["p_at_least_gate"], 1 - stats.beta_cdf(0.9, 26.5, 0.5), places=12)
        lo, hi = g["interval"]
        self.assertAlmostEqual(stats.beta_cdf(lo, 26.5, 0.5), 0.025, places=9)
        self.assertAlmostEqual(stats.beta_cdf(hi, 26.5, 0.5), 0.975, places=9)
        self.assertLess(stats.beta_gate(5, 10, 0.8)["p_at_least_gate"], 0.05)

    def test_design_effect(self):
        self.assertEqual(stats.design_effect([(5, 10)] * 6), 1.0, "meetings that agree exactly count as independent items")
        uneven = [(10, 10), (0, 10), (10, 10), (0, 10)]
        # By hand: p 0.5; between-meeting variance 100 / 3 / (4 * 10^2) = 1/12; binomial 0.25 / 40; ratio 40/3.
        self.assertAlmostEqual(stats.design_effect(uneven), 40 / 3, places=9)
        g = stats.clustered_beta_gate(uneven, 0.5)
        self.assertAlmostEqual(g["effective_n"], 40 / g["design_effect"], places=12)
        self.assertGreater(g["interval"][1] - g["interval"][0], stats.beta_gate(20, 40, 0.5)["interval"][1] - stats.beta_gate(20, 40, 0.5)["interval"][0])
        self.assertEqual(stats.design_effect([(3, 3)]), 1.0)

    def test_tost_paired(self):
        diffs = [0.10, 0.05, -0.02, 0.08, 0.01, 0.04, -0.01, 0.06]
        r = stats.tost_paired(diffs, margin=0.05)
        mean = sum(diffs) / len(diffs)
        sd = math.sqrt(sum((d - mean) ** 2 for d in diffs) / (len(diffs) - 1))
        se = sd / math.sqrt(len(diffs))
        self.assertAlmostEqual(r["mean"], mean, places=12)
        self.assertAlmostEqual(r["p_lower"], 1 - stats.t_cdf((mean + 0.05) / se, 7), places=12)
        self.assertTrue(r["noninferior"])
        self.assertFalse(r["equivalent"], "a gain larger than the margin is not equivalence")
        lo, hi = r["interval"]
        self.assertAlmostEqual(hi - mean, stats.t_quantile(0.95, 7) * se, places=9)
        self.assertFalse(stats.tost_paired([-0.2, -0.1, -0.15, -0.12], margin=0.05)["noninferior"])
        self.assertTrue(stats.tost_paired([0.0] * 5, margin=0.05)["equivalent"])
        with self.assertRaises(ValueError):
            stats.tost_paired([0.1], margin=0.05)

    def test_power_paired(self):
        self.assertAlmostEqual(stats.power_paired(24, 0.0, 0.1, 0.0), 0.05, places=12, msg="no margin and no difference: the size of the test")
        n, delta, sd, margin = 24, 0.0, 0.1, 0.05
        z = stats.NormalDist().inv_cdf(0.95)
        self.assertAlmostEqual(stats.power_paired(n, delta, sd, margin), stats.NormalDist().cdf(margin / (sd / math.sqrt(n)) - z), places=12)
        self.assertGreater(stats.power_paired(48, delta, sd, margin), stats.power_paired(24, delta, sd, margin))


class MultipleTests(unittest.TestCase):
    def test_holm(self):
        adjusted = stats.holm([0.01, 0.04, 0.03, 0.005])
        for got, want in zip(adjusted, [0.03, 0.06, 0.06, 0.02]):
            self.assertAlmostEqual(got, want, places=12)
        self.assertEqual(stats.holm([0.5, 0.9]), [1.0, 1.0])

    def test_bh(self):
        adjusted = stats.bh([0.01, 0.04, 0.03, 0.005])
        for got, want in zip(adjusted, [0.02, 0.04, 0.04, 0.02]):
            self.assertAlmostEqual(got, want, places=12)
        self.assertEqual(stats.bh([]), [])


class SpreadTests(unittest.TestCase):
    def test_spread(self):
        s = stats.spread([32, 43, 37])
        self.assertEqual((s["n"], s["min"], s["median"], s["max"]), (3, 32, 37, 43))
        self.assertAlmostEqual(s["sd"], math.sqrt(((32 - 37.333333333333336) ** 2 + (43 - 37.333333333333336) ** 2 + (37 - 37.333333333333336) ** 2) / 2), places=12)
        self.assertIsNone(stats.spread([5])["sd"])


if __name__ == "__main__":
    unittest.main()
