# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Unit tests of the speaker-attributed scoring (standard library only).  python3 -I -m unittest discover -s eval/tests -p 'test_score_cpwer.py'"""
import itertools
import os
import random
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
import score_cpwer as cp  # noqa: E402
import score_wer as sw  # noqa: E402


def said(speaker, text, start=0.0, step=0.5):
    """Words of `text` said one after another by `speaker` from `start`, `step` seconds each."""
    return [(speaker, start + k * step, start + (k + 1) * step, w) for k, w in enumerate(text.split())]


class CpWERTests(unittest.TestCase):
    ref = cp.tokens(said("A", "the budget is fine") + said("B", "we keep it", start=3))

    def test_a_perfect_transcript_with_other_labels_scores_zero(self):
        hyp = cp.tokens(said(2, "the budget is fine") + said(1, "we keep it", start=3))
        for collar in (None, 5):
            r = cp.cp_wer(self.ref, hyp, collar)
            self.assertEqual((r["errors"], r["words"], r["pairs"]), (0, 7, {"A": 2, "B": 1}))
        w = cp.wder(self.ref, hyp)
        self.assertEqual((w["wder"], w["wer"], w["recognised"]), (0.0, 0.0, 7))

    def test_a_word_given_to_the_wrong_speaker(self):
        # "fine" is recognised at its moment but in B's stream: a deletion for A and an insertion for B.
        hyp = cp.tokens(said(1, "the budget is") + [(2, 1.5, 2.0, "fine")] + said(2, "we keep it", start=3))
        r = cp.cp_wer(self.ref, hyp)
        self.assertEqual((r["errors"], r["words"]), (2, 7))
        w = cp.wder(self.ref, hyp)
        self.assertEqual((w["wrong_speaker"], w["recognised"], w["wer"]), (1, 7, 0.0), "the words are right, one speaker is not")

    def test_a_speaker_too_many_or_too_few(self):
        extra = cp.tokens(said(1, "the budget is fine") + said(2, "we keep it", start=3) + said(3, "yeah right", start=5))
        self.assertEqual(cp.cp_wer(self.ref, extra)["errors"], 2, "an extra speaker's words are insertions")
        merged = cp.tokens(said(1, "the budget is fine") + said(1, "we keep it", start=3))
        r = cp.cp_wer(self.ref, merged)
        self.assertEqual((r["errors"], r["pairs"]["B"]), (6, None),
                         "two people in one stream: B's words are deletions for B and insertions in the stream A was given")
        self.assertEqual(cp.wder(self.ref, merged)["wrong_speaker"], 3)

    def test_the_collar_of_the_time_constrained_figure(self):
        late = cp.tokens(said("x", "the budget is fine", start=20) + said("y", "we keep it", start=3))
        self.assertEqual(cp.cp_wer(self.ref, late)["errors"], 0, "cpWER ignores the times")
        self.assertEqual(cp.cp_wer(self.ref, late, collar=5)["errors"], 8, "20 s late: 4 deletions and 4 insertions")
        near = cp.tokens(said("x", "the budget is fine", start=3) + said("y", "we keep it", start=3))
        self.assertEqual(cp.cp_wer(self.ref, near, collar=5)["errors"], 0, "3 s late is inside the 5 s collar")

    def test_empty_sides(self):
        self.assertEqual(cp.cp_wer({}, {})["wer"], 0.0)
        self.assertEqual(cp.cp_wer(self.ref, {})["errors"], 7)
        self.assertEqual(cp.cp_wer({}, self.ref)["errors"], 7)
        self.assertEqual(cp.wder(self.ref, {})["recognised"], 0)

    def test_normalisation_keeps_the_times_of_a_word(self):
        streams = cp.tokens([("A", 1.0, 2.0, "1,200 euros"), ("A", 0.0, 1.0, "OK,")])
        self.assertEqual(streams["A"], [(0.0, 1.0, "okay")] + [(1.0, 2.0, t) for t in "one thousand two hundred euros".split()])


class PiecesTests(unittest.TestCase):
    def test_distance_agrees_with_the_wer_alignment(self):
        rng = random.Random(11)
        vocab = "a b c d".split()
        for _ in range(300):
            ref = [(k, k + 1, rng.choice(vocab)) for k in range(rng.randint(0, 9))]
            hyp = [(k, k + 1, rng.choice(vocab)) for k in range(rng.randint(0, 9))]
            s, d, i, _ = sw.align([t[2] for t in ref], [t[2] for t in hyp])
            self.assertEqual(cp.distance(ref, hyp), s + d + i)
            # A collar wider than the whole clip constrains nothing.
            self.assertEqual(cp.distance(ref, hyp, collar=100), s + d + i)

    def test_hungarian_finds_the_cheapest_assignment(self):
        rng = random.Random(5)
        for size in range(1, 7):
            for _ in range(40):
                cost = [[rng.randint(0, 20) for _ in range(size)] for _ in range(size)]
                column = cp.hungarian(cost)
                self.assertEqual(sorted(column), list(range(size)))
                best = min(sum(cost[i][p[i]] for i in range(size)) for p in itertools.permutations(range(size)))
                self.assertEqual(sum(cost[i][column[i]] for i in range(size)), best)


if __name__ == "__main__":
    unittest.main()
