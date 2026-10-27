# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Unit tests of the scorers (standard library unittest; needs numpy).  python3 -I -m unittest discover eval/tests"""
import itertools
import os
import random
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
import numpy as np  # noqa: E402
import score_der as sd  # noqa: E402
import score_wer as sw  # noqa: E402
import score_wer_es as swe  # noqa: E402


class MinutesScorerTests(unittest.TestCase):
    def test_fixture(self):
        import json
        import score_minutes as sm
        fx = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fixtures", "minutes_example.json")))
        r = sm.score(fx["transcript"]["passages"], fx["minutes"]["items"])
        self.assertEqual(r["items"], 5)
        self.assertAlmostEqual(r["cited_share"], 4 / 5)
        self.assertAlmostEqual(r["citation_validity"], 2 / 4)   # 5000 is not in passage 3, passage 9 does not exist
        self.assertAlmostEqual(r["unconfirmed_share"], 1 / 5)
        self.assertEqual(r["invalid_not_marked"], 1)            # the item citing the missing passage

    def test_figure_separators(self):
        import score_minutes as sm
        self.assertEqual(sm.figures("1,500 and 1.500 and 2 000"), {"1500", "2000"})


class MissingHypothesisTests(unittest.TestCase):
    def test_a_reference_without_a_hypothesis_is_reported(self):
        refs = {"a": [(0.0, 5.0, "x")], "b": [(0.0, 5.0, "x")]}
        self.assertEqual(sd.missing_hypotheses(refs, {"a": [(0.0, 5.0, "y")]}), ["b"])
        self.assertEqual(sd.missing_hypotheses(refs, dict(refs)), [])


class DocTablesTests(unittest.TestCase):
    def test_rows_ignore_totals_and_the_others_suffix(self):
        import check_doc_tables as cdt
        text = "| EN2002a_others | 2003 | 3 | 4 | 16.7 | 11.8 | 1.1 | 3.8 | 21.0 |\n| **all 10 files** | 11631 | | | **12.0** | 6.4 | 3.1 | 2.5 | **17.9** |"
        self.assertEqual(list(cdt.rows(text)), ["EN2002a"])


class HalvesTests(unittest.TestCase):
    def test_pinned_halves_follow_the_stated_rule(self):
        import json
        pins = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pins.json")))
        uris = sorted([m + "_others" for m in pins["ami_meetings"]] + pins["voxconverse_files"])
        self.assertEqual(len(uris), 18)
        self.assertEqual(pins["diarization_halves"]["half_a"], uris[0::2])
        self.assertEqual(pins["diarization_halves"]["half_b"], uris[1::2])


class HungarianTests(unittest.TestCase):
    def test_matches_brute_force(self):
        rng = random.Random(7)
        for _ in range(60):
            n, m = rng.randint(1, 5), rng.randint(1, 5)
            w = np.array([[rng.randint(0, 50) for _ in range(m)] for _ in range(n)])
            got = sum(w[i, j] for i, j in sd.hungarian_max(w).items())
            if n <= m:
                best = max(sum(w[i, c[i]] for i in range(n)) for c in itertools.permutations(range(m), n))
            else:
                best = max(sum(w[r[j], j] for j in range(m)) for r in itertools.permutations(range(n), m))
            self.assertEqual(got, best)


class DerTests(unittest.TestCase):
    REF = [(0.0, 10.0, "A"), (10.0, 10.0, "B"), (20.0, 5.0, "A")]

    def der(self, hyp, uem=None, collar=0.0):
        r = sd.score_file(self.REF, hyp, uem, collar)
        return 100 * (r["miss"] + r["fa"] + r["conf"]) / r["ref"], r

    def test_identity_is_zero(self):
        self.assertAlmostEqual(self.der(self.REF)[0], 0.0)

    def test_label_names_do_not_matter(self):
        self.assertAlmostEqual(self.der([(0, 10, "x"), (10, 10, "y"), (20, 5, "x")])[0], 0.0)

    def test_empty_hypothesis_is_all_miss(self):
        d, r = self.der([])
        self.assertAlmostEqual(d, 100.0)
        self.assertAlmostEqual(r["miss"], 25.0)

    def test_one_speaker_for_everyone_is_confusion(self):
        d, r = self.der([(0, 25, "x")])
        # The best mapping keeps A (15 s); the 10 s of B are confusion.
        self.assertAlmostEqual(r["conf"], 10.0)
        self.assertAlmostEqual(d, 40.0)

    def test_false_alarm_and_miss(self):
        d, r = self.der([(0, 10, "x"), (10, 5, "y"), (25, 5, "y")])
        self.assertAlmostEqual(r["miss"], 10.0)  # the last 5 s of B and the 5 s of A that follow
        self.assertAlmostEqual(r["fa"], 5.0)

    def test_overlap_is_scored(self):
        ref = [(0, 10, "A"), (5, 10, "B")]
        r = sd.score_file(ref, [(0, 10, "x")], None, 0.0)
        self.assertAlmostEqual(r["ref"], 20.0)
        self.assertAlmostEqual(r["miss"], 10.0)  # B (10 s) has no hypothesis speaker for the second 5 s; overlap 5..10 misses one

    def test_collar_forgives_boundary_error(self):
        hyp = [(0.1, 10.0, "x"), (10.1, 10.0, "y"), (20.1, 5.0, "x")]
        self.assertGreater(self.der(hyp)[0], 0.0)
        self.assertAlmostEqual(self.der(hyp, collar=0.25)[0], 0.0)

    def test_uem_limits_scored_time(self):
        d, r = self.der([], uem=[(0.0, 10.0)])
        self.assertAlmostEqual(r["ref"], 10.0)

    def test_speaker_counts_need_ten_seconds(self):
        ref = [(0, 30, "A"), (30, 3, "B")]
        self.assertEqual(sd.speaker_counts(ref, [(0, 30, "x"), (30, 12, "y")], None), (1, 2))


class MaskTests(unittest.TestCase):
    def test_mask_keeps_only_regions_with_padding(self):
        import run_wer as rw
        x = np.ones(10 * 16000, dtype=np.float32)
        y = rw.mask_outside(x, [(2.0, 4.0)], 0.5)
        self.assertEqual(float(y[int(1.4 * 16000)]), 0.0)
        self.assertEqual(float(y[int(1.6 * 16000)]), 1.0)
        self.assertEqual(float(y[int(4.4 * 16000)]), 1.0)
        self.assertEqual(float(y[int(4.6 * 16000)]), 0.0)


class WerTests(unittest.TestCase):
    def test_edit_counts(self):
        self.assertEqual(sw.align("a b c d".split(), "a x c".split())[:3], (1, 1, 0))  # substitution b to x, deletion of d
        self.assertEqual(sw.align("a b".split(), "a b c".split())[:3], (0, 0, 1))

    def test_normalisation(self):
        self.assertEqual(sw.normalize("Um, I've got 3 apples -- OK!"), "i've got three apples okay")
        self.assertEqual(sw.normalize("Twenty-five percent"), "twenty five percent")
        self.assertEqual(sw.normalize("25%"), "twenty five percent")
        self.assertEqual(sw.normalize("Hmm. Uh-huh."), "")

    def test_numbers(self):
        self.assertEqual(sw.number_words(0), "zero")
        self.assertEqual(sw.number_words(113), "one hundred thirteen")
        self.assertEqual(sw.number_words(2024), "two thousand twenty four")


class SpanishWerTests(unittest.TestCase):
    def test_normalisation(self):
        self.assertEqual(swe.normalize("Hay 1.234 personas, el 25% y 3,5 años"),
                         "hay mil doscientos treinta y cuatro personas el veinticinco por ciento y tres coma cinco años")
        self.assertEqual(swe.normalize("¿Qué tal? 2023"), "qué tal dos mil veintitrés")
        self.assertEqual(swe.normalize("Eh, mm, vale"), "vale")

    def test_folded_figure_ignores_accents_but_not_the_enye(self):
        self.assertEqual(swe.normalize("Á los niños", fold=True), "a los niños")
        self.assertEqual(swe.wer("más cañas", "mas cañas", fold=True)["wer"], 0.0)
        self.assertGreater(swe.wer("más cañas", "mas cañas")["wer"], 0.0)

    def test_counts(self):
        r = swe.wer("uno dos tres cuatro", "uno tres cinco")
        self.assertEqual((r["sub"], r["dele"], r["ins"], r["words"]), (1, 1, 0, 4))


if __name__ == "__main__":
    unittest.main()
