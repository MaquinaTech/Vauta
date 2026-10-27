# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Checks that the per-file tables of docs/BENCHMARKS.md equal the tables a run wrote (no hand-copied number survives).

  python3 -I eval/scripts/check_doc_tables.py <run dir> [--doc docs/BENCHMARKS.md]

The run directory holds der_ami_others_uem_nobleed.md and der_voxconverse.md (written by run_diarization.py). Each file row
of those tables (file, reference speech, reference speakers, found speakers, DER with collar, miss, false alarm,
confusion, DER without collar) must appear unchanged in the document's AMI or VoxConverse table, and the document must
hold no other file row. Exits 1 and prints the differences otherwise.
"""
import argparse
import os
import sys


def rows(text):
    out = {}
    for line in text.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 9 and not cells[0].startswith("**") and cells[1].replace(",", "").isdigit():
            out[cells[0].removesuffix("_others")] = [c.replace(",", "") for c in cells[1:9]]
    return out


def section(doc, title, until):
    start = doc.index(title)
    end = doc.index(until, start + len(title)) if until in doc[start + len(title):] else len(doc)
    return doc[start:end]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--doc", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "docs", "BENCHMARKS.md"))
    a = ap.parse_args()
    doc = open(a.doc).read()
    checks = [("AMI, per file (no-bleed region):", "VoxConverse, per file:", "der_ami_others_uem_nobleed.md"),
              ("VoxConverse, per file:", '"Ref speakers" and "Found"', "der_voxconverse.md")]
    bad = 0
    for title, until, name in checks:
        mine = rows(section(doc, title, until))
        theirs = rows(open(os.path.join(a.run, name)).read())
        for uri in sorted(set(mine) | set(theirs)):
            if mine.get(uri) != theirs.get(uri):
                bad += 1
                print(f"{title.split(',')[0]} {uri}: document {mine.get(uri)} but run {theirs.get(uri)}")
    print("tables match" if not bad else f"{bad} row(s) differ")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
