# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Blind packets for matching the minutes with AMI's human summaries by content (eval/rubric/MINUTES_GOLD_MATCH.md).

Per meeting, the human decisions and actions of the gold (build_ami_gold.py), and the decisions and tasks the minutes of every
provider show (the items ranked into "Other possible items" are left out), mixed and shuffled under neutral ids. No provider is
named in `blind/`; `sealed/key.json` maps each id to its provider, kind and position, and `blind/key.sha256` seals it before any
judging. The judge fills `blind/items_graded.tsv`; score_minutes_gold.py --matches reads it with the key.

    python3 -I eval/scripts/gold_match_packets.py --gold <folder> --minutes apple=<minutes.apple.jsonl> [--minutes integrated=<...>]
        --out <folder> [--seed 23]
"""
import argparse
import csv
import hashlib
import json
import os
import random
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score_minutes_gold import PAIRS, read_jsonl, ranked_out  # noqa: E402

RUBRIC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "rubric", "MINUTES_GOLD_MATCH.md")


def packets(golds, providers, seed):
    """(human rows, item rows, key): the rows of human.tsv and items.tsv and the id of each item's provider, kind and index."""
    rnd = random.Random(seed)
    human, items, key = [], [], {}
    for meeting, gold in sorted(golds.items()):
        human += [[meeting, f"{meeting}:{s['id']}", s["kind"], s["text"]] for s in gold["items"] if s["kind"] in ("decision", "action")]
        shown = []
        for provider, lines in sorted(providers.items()):
            minutes = next((line for line in lines if line.get("case") == meeting), None)
            for _, field in PAIRS:
                for index, item in enumerate((minutes or {}).get(field) or []):
                    if not ranked_out(item):
                        shown.append((provider, field, index, item.get("text") or ""))
        rnd.shuffle(shown)
        for n, (provider, field, index, text) in enumerate(shown, 1):
            item_id = f"{meeting}:X{n:02d}"
            key[item_id] = {"provider": provider, "field": field, "index": index}
            items.append([meeting, item_id, "decision" if field == "decisions" else "task", " ".join(text.split()), ""])
    return human, items, key


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--gold", required=True)
    ap.add_argument("--minutes", action="append", required=True, metavar="PROVIDER=FILE")
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=23)
    a = ap.parse_args(argv)
    golds = {}
    for name in sorted(os.listdir(a.gold)):
        if name.endswith(".gold.json"):
            with open(os.path.join(a.gold, name), encoding="utf-8") as f:
                g = json.load(f)
            golds[g["meeting"]] = g
    providers = {}
    for spec in a.minutes:
        provider, _, path = spec.partition("=")
        if not path:
            ap.error(f"--minutes takes PROVIDER=FILE, not {spec}")
        providers[provider] = read_jsonl(path)
    human, items, key = packets(golds, providers, a.seed)
    blind, sealed = os.path.join(a.out, "blind"), os.path.join(a.out, "sealed")
    os.makedirs(blind, exist_ok=True)
    os.makedirs(sealed, exist_ok=True)
    for name, header, rows in (("human.tsv", ["meeting", "human_id", "kind", "text"], human),
                               ("items.tsv", ["meeting", "item_id", "kind", "text", "states"], items)):
        with open(os.path.join(blind, name), "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f, delimiter="\t")
            w.writerow(header)
            w.writerows(rows)
    shutil.copy(RUBRIC, os.path.join(blind, "INSTRUCTIONS.md"))
    text = json.dumps({"seed": a.seed, "items": key}, sort_keys=True, indent=1)
    with open(os.path.join(sealed, "key.json"), "w", encoding="utf-8") as f:
        f.write(text)
    digest = hashlib.sha256(text.encode()).hexdigest()
    with open(os.path.join(blind, "key.sha256"), "w", encoding="utf-8") as f:
        f.write(digest + "\n")
    print(f"{len(human)} human sentences, {len(items)} items; key sha256 {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
