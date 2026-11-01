# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Human gold for the minutes, from the AMI manual annotations 1.6.2 (CC BY 4.0, pinned in eval/pins.json).

For each meeting: the sentences of the annotators' abstractive summary (its abstract, decisions, actions and problems), each with the
dialogue acts the annotators linked to it (the summary links), as times and as passages of the evaluation transcript of that meeting
(the `<meeting>.json` that `llm-eval --tasks minutes` reads, built by tools/llm-eval/data/build_ami_long.py). The owners of an action
are the roles its subject names ("The industrial designer will ..."), as speakers of that transcript through corpusResources/meetings.xml.

    python3 -I eval/scripts/build_ami_gold.py --sets <folder of <meeting>.json> --out <folder> [--zip <ami_public_manual_1.6.2.zip>]

Writes <out>/<meeting>.gold.json for every set the zip has a summary for, and <out>/gold.sha256. The names of annotators and participants
in the corpus ids are not copied. Nothing of it is committed: it is rebuilt from the zip, which must have the SHA-256 of eval/pins.json.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import PINS, SRC, sha256_file  # noqa: E402

NITE = "{http://nite.sourceforge.net/}"
SOURCE = "AMI Meeting Corpus, manual annotations 1.6.2: abstractive summaries and summary links (CC BY 4.0)"
SECTIONS = {"abstract": "abstract", "decisions": "decision", "actions": "action", "problems": "problem"}
HREF = re.compile(r"^(?P<file>[^#]+)#id\((?P<a>[^)]+)\)(?:\.\.id\((?P<b>[^)]+)\))?$")
# Longest first, so "user interface designer" is one mention and "marketing expert" is not read twice. The annotators also wrote
# "industrial specialist", "Industrial Deigner" and "the two designers" (the industrial and the interface designer).
ROLE = re.compile(r"\b(?:(?P<UI>user interface (?:designer|specialist|expert)|(?:ui|interface) (?:designer|specialist|expert))"
                  r"|(?P<ID>industrial (?:designer|deigner|specialist|expert))|(?P<ME>marketing(?: (?:expert|specialist|manager))?)"
                  r"|(?P<PM>project manager)|(?P<DESIGNERS>(?:two|the) designers))\b", re.I)
ABBREVIATION = re.compile(r"\b(?P<role>PM|ID|UI|ME)\b")  # case-sensitive: "The ID will ...", never the word "me"
GROUP = re.compile(r"\b(?:the (?:whole )?(?:group|team)|(?:some |all )?(?:the )?team members?|each (?:team )?member|everyone|everybody"
                   r"|all (?:the )?(?:members|participants)|all of them|they|individual(?:ly)?)\b", re.I)
PLACEHOLDER = re.compile(r"^\W*N/?A\W*$", re.I)  # "*NA*", "NA.": the annotator's way of saying there was none
MODAL = re.compile(r"\b(?:will|would|shall|should|must|is to|are to|has to|have to|needs? to|(?:is|are) going to|plans? to|agreed to)\b", re.I)
EPS = 0.01


def ref(href):
    """(file, first id, last id) of a NITE href; the last is the first when the href is not a range."""
    match = HREF.match(href or "")
    if not match:
        return None
    return match["file"], match["a"], match["b"] or match["a"]


def letter_of(file_name, meeting):
    """The speaker letter of a per-speaker file: "ES2004c.B.dialog-act.xml" gives "B"."""
    parts = file_name.split(".")
    return parts[1] if len(parts) > 2 and parts[0] == meeting and len(parts[1]) == 1 else None


class Meeting:
    """The annotation files of one meeting, read on demand from the zip."""

    def __init__(self, zf, meeting):
        self.zf, self.meeting = zf, meeting
        self.names = set(zf.namelist())
        self._words, self._acts = {}, {}

    def xml(self, path):
        return ET.fromstring(self.zf.read(path)) if path in self.names else None

    def words(self, letter):
        """(position of each element id, times of each position) of a words file, in document order."""
        if letter not in self._words:
            root = self.xml(f"words/{self.meeting}.{letter}.words.xml")
            order, times = {}, []
            for el in (root if root is not None else []):
                order[el.get(NITE + "id")] = len(times)
                try:
                    start, end = float(el.get("starttime")), float(el.get("endtime"))
                    times.append((start, end) if start == start and end == end else None)
                except (TypeError, ValueError):
                    times.append(None)
            self._words[letter] = (order, times)
        return self._words[letter]

    def acts(self, letter):
        """(the ids in document order, the word ranges of each id) of a dialogue act file."""
        if letter not in self._acts:
            root = self.xml(f"dialogueActs/{self.meeting}.{letter}.dialog-act.xml")
            ids, ranges = [], {}
            for act in (root.iter("dact") if root is not None else []):
                act_id = act.get(NITE + "id")
                ids.append(act_id)
                ranges[act_id] = [r for r in (ref(child.get("href")) for child in act.iter(NITE + "child")) if r]
            self._acts[letter] = (ids, ranges)
        return self._acts[letter]

    def span(self, letter, act_id):
        """(letter, start, end) of a dialogue act from the times of its words; None when none of them has a time."""
        times = []
        for file_name, first, last in self.acts(letter)[1].get(act_id, []):
            word_letter = letter_of(file_name, self.meeting) or letter
            order, word_times = self.words(word_letter)
            if first not in order or last not in order:
                continue
            times += [t for t in word_times[order[first]:order[last] + 1] if t]
        if not times:
            return None
        return letter, min(t[0] for t in times), max(t[1] for t in times)

    def linked_acts(self):
        """For each abstractive sentence id, the (letter, act id) the summary links point to, in link order."""
        links = {}
        root = self.xml(f"extractive/{self.meeting}.summlink.xml")
        for link in (root.iter("summlink") if root is not None else []):
            pointers = {p.get("role"): ref(p.get("href")) for p in link.iter(NITE + "pointer")}
            extractive, abstractive = pointers.get("extractive"), pointers.get("abstractive")
            if not extractive or not abstractive:
                continue
            letter = letter_of(extractive[0], self.meeting)
            if not letter:
                continue
            ids = self.acts(letter)[0]
            if extractive[1] in ids and extractive[2] in ids:
                chosen = ids[ids.index(extractive[1]):ids.index(extractive[2]) + 1]
            else:
                chosen = [extractive[1]]
            links.setdefault(abstractive[1], []).extend((letter, a) for a in chosen)
        return links

    def sentences(self):
        """(kind, sentence id, text) of the abstractive summary, in document order; nothing when the meeting has none."""
        root = self.xml(f"abstractive/{self.meeting}.abssumm.xml")
        out = []
        for section in (root if root is not None else []):
            kind = SECTIONS.get(section.tag)
            if not kind:
                continue
            for sentence in section.iter("sentence"):
                text = " ".join("".join(sentence.itertext()).split())
                if text and not PLACEHOLDER.match(text):
                    out.append((kind, sentence.get(NITE + "id"), text))
        return out

    def roles(self):
        """The role of each speaker letter ("PM", "ME", "ID", "UI") in corpusResources/meetings.xml."""
        root = self.xml("corpusResources/meetings.xml")
        for meeting in (root.iter("meeting") if root is not None else []):
            if meeting.get("observation") == self.meeting:
                return {s.get("nxt_agent"): s.get("role") for s in meeting.iter("speaker") if s.get("nxt_agent") and s.get("role")}
        return {}


def speaker(letter):
    """The speaker of the evaluation transcript for a corpus letter (A is "Speaker 1", as build_ami_long.py numbers them)."""
    return f"Speaker {ord(letter) - 64}"


def owners(text, roles):
    """The speakers an action's subject names by role, "group" when it names the group, [] when it names neither (a pronoun, the coach)."""
    modal = MODAL.search(text)
    subject = text[:modal.start()] if modal else text
    mentions = sorted([(m.start(), m.lastgroup) for m in ROLE.finditer(subject)] + [(m.start(), m["role"]) for m in ABBREVIATION.finditer(subject)])
    named = []
    for _, mention in mentions:
        for role in (("ID", "UI") if mention == "DESIGNERS" else (mention,)):
            named += [speaker(letter) for letter, r in sorted(roles.items()) if r == role and speaker(letter) not in named]
    if named:
        return named
    return ["group"] if GROUP.search(subject) else []


def passages_of(spans, passages):
    """The ids of the transcript's passages, of the same speaker, that overlap any of the spans."""
    out = set()
    for letter, start, end in spans:
        label = speaker(letter) + " "
        for p in passages:
            if (p.get("speaker") or "").startswith(label) and p["start"] <= end + EPS and p["end"] >= start - EPS:
                out.add(p["id"])
    return sorted(out)


def build(zf, meeting, transcript):
    """The gold of one meeting, or None when the zip has no abstractive summary for it."""
    m = Meeting(zf, meeting)
    sentences = m.sentences()
    if not sentences:
        return None
    links, roles = m.linked_acts(), m.roles()
    passages = transcript.get("passages", [])
    items, counters, linked, unmapped = [], {}, 0, 0
    for kind, sentence_id, text in sentences:
        counters[kind] = counters.get(kind, 0) + 1
        spans = []
        for letter, act_id in links.get(sentence_id, []):
            linked += 1
            s = m.span(letter, act_id)
            if s and s not in spans:
                spans.append(s)
            elif not s:
                unmapped += 1
        item = {"id": f"{kind}.{counters[kind]}", "kind": kind, "text": text,
                "spans": [[round(s, 2), round(e, 2), speaker(letter)] for letter, s, e in sorted(spans, key=lambda x: (x[1], x[0]))],
                "passages": passages_of(spans, passages)}
        if kind == "action":
            item["owners"] = owners(text, roles)
        items.append(item)
    return {"meeting": meeting, "split": transcript.get("split"), "source": SOURCE, "transcript_passages": len(passages),
            "roles": {speaker(letter): role for letter, role in sorted(roles.items())},
            "linked_acts": linked, "unmapped_acts": unmapped, "items": items}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--zip", default=os.path.join(SRC, "ann", "ami_public_manual_1.6.2.zip"),
                    help="the AMI manual annotations (default: <work>/src/ann/ami_public_manual_1.6.2.zip, as fetch.py stores them)")
    ap.add_argument("--sets", required=True, help="folder of <meeting>.json transcripts (build_ami_long.py)")
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    if sha256_file(a.zip) != PINS["ami_manual_annotations"]["sha256"]:
        print(f"ERROR: {a.zip} is not the AMI annotations pinned in eval/pins.json (ami_manual_annotations).", file=sys.stderr)
        return 1
    os.makedirs(a.out, exist_ok=True)
    zf = zipfile.ZipFile(a.zip)
    manifest = []
    for name in sorted(os.listdir(a.sets)):
        if not name.endswith(".json") or name.startswith("_"):
            continue
        with open(os.path.join(a.sets, name), encoding="utf-8") as f:
            transcript = json.load(f)
        meeting = transcript.get("meeting") or name[:-5]
        gold = build(zf, meeting, transcript)
        if gold is None:
            print(f"{meeting}: no abstractive summary, skipped")
            continue
        data = (json.dumps(gold, ensure_ascii=False, indent=1, sort_keys=True) + "\n").encode("utf-8")
        path = os.path.join(a.out, f"{meeting}.gold.json")
        with open(path, "wb") as f:
            f.write(data)
        manifest.append(f"{hashlib.sha256(data).hexdigest()}  {meeting}.gold.json")
        kinds = {k: sum(1 for i in gold["items"] if i["kind"] == k) for k in ("decision", "action")}
        empty = sum(1 for i in gold["items"] if i["kind"] in kinds and not i["passages"])
        print(f"{meeting}: {kinds['decision']} decisions, {kinds['action']} actions, {empty} with no passage, "
              f"{gold['unmapped_acts']} of {gold['linked_acts']} linked acts without times")
    text = "\n".join(manifest) + "\n"
    with open(os.path.join(a.out, "gold.sha256"), "w", encoding="utf-8") as f:
        f.write(text)
    print(f"{len(manifest)} meetings; gold digest {hashlib.sha256(text.encode()).hexdigest()[:16]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
