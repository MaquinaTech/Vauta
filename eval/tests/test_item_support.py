# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Unit tests of the blind item-support packets and their scoring (standard library only).

    python3 -I -m unittest discover -s eval/tests -p 'test_item_support.py'

The meeting and the minutes are invented.
"""
import contextlib
import csv
import hashlib
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
import item_support as its  # noqa: E402

M = "XX0001a"
PASSAGES = [{"id": n, "start": float(n), "end": n + 0.5, "speaker": f"Speaker {1 + n % 2}", "text": f"Line {n}."} for n in range(1, 31)]


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def minutes(decisions, tasks):
    return {"case": M, "decisions": decisions, "tasks": tasks, "summary": "", "open_questions": []}


def item(text, cite, unconfirmed=False, reason=""):
    return {"text": text, "citations": [cite], "quote": "", "unconfirmed": unconfirmed, "reason": reason}


BASE = minutes([item("Keep the shell", 5), item("Ranked out", 6, True, "rank:figures")], [item("Send the costs", 20)])
NEW = minutes([item("Keep the round shell", 5), item("Drop the clip", 12, True, "noAgreement")], [item("Book the room", 28)])


class ItemSupportTests(unittest.TestCase):
    def write(self, folder):
        sets = os.path.join(folder, "sets")
        os.makedirs(sets)
        with open(os.path.join(sets, f"{M}.json"), "w", encoding="utf-8") as f:
            json.dump({"meeting": M, "split": "test", "language": "en", "passages": PASSAGES}, f)
        paths = {}
        for label, record in (("base", BASE), ("new", NEW)):
            paths[label] = os.path.join(folder, f"{label}.jsonl")
            with open(paths[label], "w", encoding="utf-8") as f:
                f.write(json.dumps(record) + "\n")
        out = os.path.join(folder, "packets")
        with contextlib.redirect_stdout(io.StringIO()):
            its.main(["packets", "--sets", sets, "--minutes", f"base={paths['base']}", "--minutes", f"new={paths['new']}", "--out", out, "--context", "2"])
        return out

    def test_the_packets_are_blind_and_the_key_is_sealed(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = self.write(tmp)
            blind = os.path.join(out, "blind")
            text = read(os.path.join(blind, "items.md"))
            grades = read(os.path.join(blind, "grades.tsv"))
            for name in ("base", "new"):
                self.assertNotIn(name, text.lower())
                self.assertNotIn(name, grades)
            key_text = read(os.path.join(out, "sealed", "key.json"))
            self.assertEqual(read(os.path.join(blind, "key.sha256")).strip(), hashlib.sha256(key_text.encode()).hexdigest())
            key = json.loads(key_text)["items"]
            self.assertEqual(len(key), 5, "the item ranked out is left out")
            self.assertEqual(sorted(v["label"] for v in key.values()), ["base", "base", "new", "new", "new"])
            self.assertTrue(os.path.exists(os.path.join(blind, "INSTRUCTIONS.md")))

    def test_each_item_shows_the_passages_around_its_citation(self):
        lines = its.render("X:I01", "decision", item("A choice", 12), PASSAGES, 2)
        shown = [line for line in lines if line.startswith("    ")]
        self.assertEqual([int(line.split()[1 if "►" in line else 0]) for line in shown], [10, 11, 12, 13, 14])
        self.assertEqual([line for line in shown if "►" in line], ["    ►   12 Speaker 1: Line 12."])
        edge = its.render("X:I02", "task", item("Late", 30), PASSAGES, 2)
        self.assertEqual(sum(1 for line in edge if line.startswith("    ")), 3, "no passage past the end")
        self.assertIn("    (no passage cited)", its.render("X:I03", "task", {"text": "x", "citations": []}, PASSAGES, 2))

    def test_the_scores_count_each_grade_and_compare_the_two_sets_per_meeting(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = self.write(tmp)
            key = json.loads(read(os.path.join(out, "sealed", "key.json")))["items"]
            path = os.path.join(out, "blind", "grades.tsv")
            rows = list(csv.reader(io.StringIO(read(path)), delimiter="\t"))
            for row in rows[1:]:
                v = key[row[1]]
                row[3] = {"base": "yes", "new": "weak" if v["unconfirmed"] else "yes"}[v["label"]]
            with open(path, "w", newline="", encoding="utf-8") as f:
                csv.writer(f, delimiter="\t").writerows(rows)
            args = type("A", (), {"grades": path, "key": os.path.join(out, "sealed", "key.json"), "compare": "base,new", "margin": 0.1, "out": None})
            with contextlib.redirect_stdout(io.StringIO()):
                report = its.score(args)
            self.assertEqual(report["labels"]["base"]["all"]["supported_rate"], 1.0)
            new = report["labels"]["new"]
            self.assertEqual((new["all"]["items"], new["all"]["yes"], new["all"]["weak"]), (3, 2, 1))
            self.assertEqual((new["firm"]["items"], new["firm"]["supported_rate"]), (2, 1.0), "the unconfirmed item is not firm")
            self.assertEqual(report["compare"]["meetings"], 1, "one meeting: no test")

    def test_a_missing_or_unknown_grade_stops_the_score(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = self.write(tmp)
            args = type("A", (), {"grades": os.path.join(out, "blind", "grades.tsv"), "key": os.path.join(out, "sealed", "key.json"),
                                  "compare": None, "margin": 0.1, "out": None})
            with self.assertRaises(SystemExit):
                its.score(args)

    def test_the_non_inferiority_test_reads_the_paired_differences(self):
        base = {"a": (3, 0, 4), "b": (2, 1, 4), "c": (4, 0, 5)}
        same = its.compare(base, dict(base), 0.10)
        self.assertEqual((same["meetings"], same["mean_difference"]), (3, 0.0))
        worse = its.compare(base, {"a": (0, 0, 4), "b": (0, 0, 4), "c": (1, 0, 5)}, 0.10)
        self.assertFalse(worse["noninferior"])
        self.assertLess(worse["mean_difference"], -0.5)


if __name__ == "__main__":
    unittest.main()
