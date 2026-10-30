# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Unit tests of the word confidence scoring (standard library only).  python3 -I -m unittest discover -s eval/tests -p 'test_score_wer.py'"""
import os
import random
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
import score_wer as sw  # noqa: E402


class HypCorrectTests(unittest.TestCase):
    def test_matches_substitutions_and_insertions(self):
        ref = "send the deck to the board".split()
        hyp = "send a deck to the big board".split()
        self.assertEqual(sw.hyp_correct(ref, hyp), [True, False, True, True, True, False, True])
        # "the the": either one is the insertion; one of them is right, never both
        self.assertEqual(sum(sw.hyp_correct(ref, "send the deck to the the board".split())), 6)

    def test_empty_sides(self):
        self.assertEqual(sw.hyp_correct([], ["a", "b"]), [False, False])
        self.assertEqual(sw.hyp_correct(["a"], []), [])

    def test_agrees_with_the_error_count(self):
        rng = random.Random(7)
        vocab = "a b c d e".split()
        for _ in range(200):
            ref = [rng.choice(vocab) for _ in range(rng.randint(0, 12))]
            hyp = [rng.choice(vocab) for _ in range(rng.randint(0, 12))]
            s, d, i, n = sw.align(ref, hyp)
            ok = sw.hyp_correct(ref, hyp)
            # every hypothesis word is a match, a substitution or an insertion of one optimal path
            self.assertEqual(len(hyp) - sum(ok), s + i)


class ScoredTokensTests(unittest.TestCase):
    def test_normalisation_spreads_and_drops(self):
        self.assertEqual(sw.scored_tokens([("Um,", 0.4), ("25%", 0.8), ("OK.", None)]),
                         [("twenty", 0.8), ("five", 0.8), ("percent", 0.8), ("okay", None)])


class ReliabilityTests(unittest.TestCase):
    def test_a_perfectly_calibrated_score(self):
        pairs = [(0.25, i < 1) for i in range(4)] + [(0.75, i < 3) for i in range(4)]
        r = sw.reliability(pairs)
        self.assertAlmostEqual(r["ece"], 0.0)
        self.assertEqual([b["words"] for b in r["bins"]], [4, 4])
        self.assertAlmostEqual(r["accuracy"], 0.5)

    def test_an_overconfident_score(self):
        r = sw.reliability([(0.95, ok) for ok in (True, False)])
        self.assertAlmostEqual(r["ece"], 0.45)
        self.assertAlmostEqual(r["brier"], (0.05 ** 2 + 0.95 ** 2) / 2)
        self.assertIsNone(sw.reliability([(0.5, True)])["auroc"], "one class only")

    def test_auroc_by_ranks(self):
        self.assertAlmostEqual(sw.reliability([(0.9, True), (0.8, True), (0.2, False)])["auroc"], 1.0)
        self.assertAlmostEqual(sw.reliability([(0.1, True), (0.9, False)])["auroc"], 0.0)
        self.assertAlmostEqual(sw.reliability([(0.5, True), (0.5, False)])["auroc"], 0.5, msg="a tie counts half")
        self.assertEqual(sw.reliability([(1.0, True)])["bins"][0]["hi"], 1.0, "a confidence of 1 falls in the last bin")
        self.assertEqual(sw.reliability([])["words"], 0)


if __name__ == "__main__":
    unittest.main()
