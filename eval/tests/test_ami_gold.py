# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Unit tests of the human gold of the minutes and its scoring (standard library only).

    python3 -I -m unittest discover -s eval/tests -p 'test_ami_gold.py'

The corpus is invented: one meeting in the layout of the AMI annotations, written to an in-memory zip.
"""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
import build_ami_gold as bg  # noqa: E402
import score_minutes_gold as sg  # noqa: E402

M = "XX0001a"
ROOT = '<?xml version="1.0" encoding="ISO-8859-1"?><nite:root xmlns:nite="http://nite.sourceforge.net/">{}</nite:root>'


def words(letter, rows):
    """A words file: (start, end, text) per word, ids XX0001a.<letter>.words<n> in order; None times for a word without any."""
    out = []
    for n, (start, end, text) in enumerate(rows):
        times = f' starttime="{start}" endtime="{end}"' if start is not None else ""
        out.append(f'<w nite:id="{M}.{letter}.words{n}"{times}>{text}</w>')
    return ROOT.format("".join(out))


def acts(letter, ranges):
    """A dialogue act file: one act per (first word, last word), ids XX0001a.<letter>.da.<n> from 1."""
    out = []
    for n, (first, last) in enumerate(ranges, start=1):
        href = f"{M}.{letter}.words.xml#id({M}.{letter}.words{first})..id({M}.{letter}.words{last})"
        out.append(f'<dact nite:id="{M}.{letter}.da.{n}"><nite:child href="{href}"/></dact>')
    return ROOT.format("".join(out))


def corpus():
    """Speaker A is the project manager and B the industrial designer. A says words 0-5 (0-3 s) and 6-8 (10-12 s), B says
    words 0-3 (20-22 s). The summary has an abstract sentence, a decision linked to A's first act, an action linked to B's act,
    an action with no link and a problem linked to A's second act."""
    files = {
        "corpusResources/meetings.xml": ROOT.format(
            f'<meeting observation="{M}"><speaker nxt_agent="A" global_name="XEE001" role="PM"/>'
            f'<speaker nxt_agent="B" global_name="XEE002" role="ID"/></meeting>'),
        f"words/{M}.A.words.xml": words("A", [(0.0, 0.5, "we"), (0.5, 1.0, "take"), (1.0, 1.5, "the"), (1.5, 2.0, "rubber"),
                                             (2.0, 2.5, "case"), (None, None, "."), (10.0, 10.5, "too"), (10.5, 11.0, "costly"),
                                             (11.0, 12.0, "though")]),
        f"words/{M}.B.words.xml": words("B", [(20.0, 20.5, "I'll"), (20.5, 21.0, "draw"), (21.0, 21.5, "the"), (21.5, 22.0, "case")]),
        f"dialogueActs/{M}.A.dialog-act.xml": acts("A", [(0, 5), (6, 8)]),
        f"dialogueActs/{M}.B.dialog-act.xml": acts("B", [(0, 3)]),
        f"extractive/{M}.summlink.xml": ROOT.format("".join(
            f'<summlink><nite:pointer role="extractive" href="{M}.{letter}.dialog-act.xml#id({M}.{letter}.da.{n})"/>'
            f'<nite:pointer role="abstractive" href="{M}.abssumm.xml#id({M}.Annotator.s.{s})"/></summlink>'
            for letter, n, s in [("A", 1, 1), ("A", 1, 2), ("B", 1, 3), ("A", 2, 5)])),
        f"abstractive/{M}.abssumm.xml": ROOT.format(
            f'<abstract><sentence nite:id="{M}.Annotator.s.1">The group met about the case.</sentence></abstract>'
            f'<decisions><sentence nite:id="{M}.Annotator.s.2">It was decided that the case is rubber.</sentence></decisions>'
            f'<actions><sentence nite:id="{M}.Annotator.s.3">The Industrial Designer will draw the case.</sentence>'
            f'<sentence nite:id="{M}.Annotator.s.4">Their coach will send the brief.</sentence></actions>'
            f'<problems><sentence nite:id="{M}.Annotator.s.5">The case may be too costly.</sentence></problems>'),
    }
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as zf:
        for name, text in files.items():
            zf.writestr(name, text.encode("iso-8859-1"))
    buffer.seek(0)
    return zipfile.ZipFile(buffer)


# Passages of the evaluation transcript, as build_ami_long.py numbers them (in time order, ids from 1).
TRANSCRIPT = {"meeting": M, "split": "test", "passages": [
    {"id": 1, "start": 0.0, "end": 2.5, "speaker": "Speaker 1 (remote)", "text": "we take the rubber case."},
    {"id": 2, "start": 5.0, "end": 7.0, "speaker": "Speaker 2 (remote)", "text": "something else entirely here"},
    {"id": 3, "start": 10.0, "end": 12.0, "speaker": "Speaker 1 (remote)", "text": "too costly though"},
    {"id": 4, "start": 14.0, "end": 16.0, "speaker": "Speaker 1 (remote)", "text": "more words of nothing"},
    {"id": 5, "start": 16.5, "end": 18.0, "speaker": "Speaker 2 (remote)", "text": "and more of nothing"},
    {"id": 6, "start": 20.0, "end": 22.0, "speaker": "Speaker 2 (remote)", "text": "I'll draw the case"},
]}


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.gold = bg.build(corpus(), M, TRANSCRIPT)

    def item(self, item_id):
        return next(i for i in self.gold["items"] if i["id"] == item_id)

    def test_each_sentence_has_the_passages_of_the_acts_linked_to_it(self):
        self.assertEqual([i["id"] for i in self.gold["items"]], ["abstract.1", "decision.1", "action.1", "action.2", "problem.1"])
        self.assertEqual(self.item("decision.1")["passages"], [1])
        self.assertEqual(self.item("decision.1")["spans"], [[0.0, 2.5, "Speaker 1"]])  # the word with no time is skipped
        self.assertEqual(self.item("action.1")["passages"], [6])
        self.assertEqual(self.item("problem.1")["passages"], [3])
        self.assertEqual(self.item("action.2")["passages"], [])  # no link
        self.assertEqual((self.gold["linked_acts"], self.gold["unmapped_acts"], self.gold["transcript_passages"]), (4, 0, 6))

    def test_an_action_is_owned_by_the_speaker_its_subject_names(self):
        self.assertEqual(self.gold["roles"], {"Speaker 1": "PM", "Speaker 2": "ID"})
        self.assertEqual(self.item("action.1")["owners"], ["Speaker 2"])
        self.assertEqual(self.item("action.2")["owners"], [])

    def test_no_name_of_the_corpus_ids_is_copied(self):
        text = json.dumps(self.gold)
        self.assertNotIn("Annotator", text)
        self.assertNotIn("XEE00", text)

    def test_owners_read_the_subject_only(self):
        roles = {"A": "PM", "B": "ID", "C": "UI", "D": "ME"}
        self.assertEqual(bg.owners("The User Interface Designer and the Industrial Designer will build it.", roles), ["Speaker 3", "Speaker 2"])
        self.assertEqual(bg.owners("The Marketing Expert will send the minutes to the Project Manager.", roles), ["Speaker 4"])
        self.assertEqual(bg.owners("The group will meet again.", roles), ["group"])
        self.assertEqual(bg.owners("He will look into the costs.", roles), [])
        self.assertEqual(bg.owners("The project manager to send the minutes.", roles), ["Speaker 1"])
        # what the annotators also wrote: a typo, an abbreviation, both designers, the team as "they"
        self.assertEqual(bg.owners("The Industrial Deigner will look at the chips.", roles), ["Speaker 2"])
        self.assertEqual(bg.owners("The ID and the UI will meet.", roles), ["Speaker 2", "Speaker 3"])
        self.assertEqual(bg.owners("The two designers will build a prototype.", roles), ["Speaker 2", "Speaker 3"])
        self.assertEqual(bg.owners("They will send me the minutes.", roles), ["group"])

    def test_a_placeholder_for_no_actions_is_not_a_sentence(self):
        for text in ("*NA*", "NA.", "N/A", "*NA*."):
            self.assertIsNotNone(bg.PLACEHOLDER.match(text), text)
        self.assertIsNone(bg.PLACEHOLDER.match("Nadia will send the minutes."))

    def test_a_meeting_without_a_summary_has_no_gold(self):
        self.assertIsNone(bg.build(corpus(), "XX0002a", TRANSCRIPT))

    def test_a_zip_that_is_not_the_pinned_one_is_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "annotations.zip")
            with open(path, "wb") as f:
                f.write(corpus().fp.getvalue())
            with contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(bg.main(["--zip", path, "--sets", folder, "--out", os.path.join(folder, "out")]), 1)
            self.assertIn("eval/pins.json", err.getvalue())
            self.assertFalse(os.path.exists(os.path.join(folder, "out")))


class ScoreTests(unittest.TestCase):
    def setUp(self):
        self.gold = bg.build(corpus(), M, TRANSCRIPT)

    def test_an_item_is_grounded_within_the_tolerance(self):
        minutes = {"case": M, "decisions": [{"text": "Rubber case", "citations": [2]}], "tasks": []}
        near = sg.score_meeting(self.gold, minutes, tolerance=1)["decision"]
        self.assertEqual((near["found"], near["supported"], near["items"]), (1, 1, 1))
        exact = sg.score_meeting(self.gold, minutes, tolerance=0)["decision"]
        self.assertEqual((exact["found"], exact["supported"], exact["in_summary"]), (0, 0, 0))

    def test_found_supported_summary_and_chance(self):
        minutes = {"case": M, "decisions": [
            {"text": "Rubber case", "citations": [1]},
            {"text": "Rubber again", "citations": [1]},       # the same sentence is found once
            {"text": "The cost", "citations": [3]},           # in the summary (a problem), not a decision
            {"text": "No citation", "citations": []},
            {"text": "Ranked out", "citations": [1], "unconfirmed": True, "reason": "rank:noAgreement"},
        ], "tasks": [
            {"text": "Draw the case", "citations": [6], "owner": "Speaker 2"},
            {"text": "Something", "citations": [5], "owner": ""},
        ]}
        row = sg.score_meeting(self.gold, minutes, tolerance=0)
        d, t = row["decision"], row["action"]
        self.assertEqual((d["linked"], d["found"], d["items"], d["supported"], d["in_summary"], d["uncited"], d["other_items"]),
                         (1, 1, 4, 2, 3, 1, 1))
        self.assertEqual((d["covered"], d["covered_summary"], d["passages"]), (1, 3, 6))  # passage 1; passages 1, 3 and 6
        self.assertEqual((t["sentences"], t["linked"], t["found"], t["items"], t["supported"]), (2, 1, 1, 2, 1))
        self.assertEqual((t["owners_right"], t["owners_total"]), (1, 1))

    def test_a_ranked_out_item_counts_only_with_the_other_items(self):
        minutes = {"case": M, "decisions": [{"text": "Ranked out", "citations": [1], "unconfirmed": True, "reason": "rank"}], "tasks": []}
        d = sg.score_meeting(self.gold, minutes, tolerance=0)["decision"]
        self.assertEqual((d["found"], d["found_with_other_items"], d["items"]), (0, 1, 0))
        doubted = {"case": M, "decisions": [{"text": "Doubted", "citations": [1], "unconfirmed": True, "reason": "noAgreement"}], "tasks": []}
        self.assertEqual(sg.score_meeting(self.gold, doubted, tolerance=0)["decision"]["found"], 1)

    def test_a_task_with_another_owner_or_none_is_wrong(self):
        for owner in ("Speaker 1", "", "Ana"):
            minutes = {"case": M, "decisions": [], "tasks": [{"text": "Draw", "citations": [6], "owner": owner}]}
            t = sg.score_meeting(self.gold, minutes, tolerance=0)["action"]
            self.assertEqual((t["owners_right"], t["owners_total"]), (0, 1), owner)

    def test_pooled_rates_and_missing_minutes(self):
        minutes = {"case": M, "decisions": [{"text": "Rubber case", "citations": [1]}, {"text": "Other", "citations": [4]}], "tasks": []}
        report = sg.score({M: self.gold, "XX0002a": dict(self.gold, meeting="XX0002a", split="dev")}, {"p": [minutes]}, tolerance=0)
        self.assertEqual(report["p"]["missing"], ["XX0002a"])
        pooled = report["p"]["all"]["decision"]
        self.assertEqual((pooled["found_rate"], pooled["supported_rate"], pooled["chance_rate"], pooled["meetings"]), (1.0, 0.5, 0.167, 1))
        self.assertEqual(pooled["found_ci"], [1.0, 1.0])
        self.assertEqual(report["p"]["test"]["decision"]["meetings"], 1)


if __name__ == "__main__":
    unittest.main()
