# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Mechanical citation checks for minutes written about a PUBLIC transcript (standard library only).

  python3 -I eval/scripts/score_minutes.py --minutes minutes.json --transcript transcript.json [--json out.json]

transcript.json: {"passages": [{"id": 1, "text": "..."}, ...]}
minutes.json:    {"model": "<name and revision>", "items": [{"text": "...", "citations": [1, 4], "unconfirmed": false}, ...]}

An item's citation is valid when every cited passage exists and, together, they contain every figure the item states
(the same idea as `MinutesVerifier.figuresAreInSegment` in the app: a number in a decision or task must be one the
transcript said). Reports the share of items with at least one citation, the share whose citations are all valid, the
share the app marked "Unconfirmed", and, among items with citations, the share the app left unmarked although a citation
is invalid. Never run it on a real meeting. Producing the minutes needs a model the person running it chooses; this
script only scores the result. The rubric for what a person or judge scores is in eval/rubric/MINUTES_RUBRIC.md.
"""
import argparse
import json
import re
import unicodedata


def figures(text):
    """Numbers written with digits, with separators dropped ("1,500", "1.500" and "1 500" are all "1500")."""
    t = unicodedata.normalize("NFKC", text)
    return set(re.sub(r"[,.  ' ](?=\d)", "", m) for m in re.findall(r"\d+(?:[,.  ' ]\d+)*", t))


def score(passages, items):
    by_id = {p["id"]: p["text"] for p in passages}
    cited = valid = unconfirmed = silently_invalid = 0
    for item in items:
        ids = item.get("citations") or []
        marked = bool(item.get("unconfirmed"))
        unconfirmed += marked
        if not ids:
            continue
        cited += 1
        ok = all(i in by_id for i in ids)
        if ok:
            have = set()
            for i in ids:
                have |= figures(by_id[i])
            ok = figures(item["text"]) <= have
        valid += ok
        if not ok and not marked:
            silently_invalid += 1
    n = len(items)
    rate = lambda a, b: (a / b) if b else None  # noqa: E731
    return dict(items=n, cited_share=rate(cited, n), citation_validity=rate(valid, cited), unconfirmed_share=rate(unconfirmed, n),
                invalid_not_marked=silently_invalid)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", required=True)
    ap.add_argument("--transcript", required=True)
    ap.add_argument("--json")
    a = ap.parse_args()
    transcript = json.load(open(a.transcript))
    minutes = json.load(open(a.minutes))
    result = score(transcript["passages"], minutes["items"])
    result["model"] = minutes.get("model")
    print(json.dumps(result, indent=1))
    if a.json:
        json.dump(result, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
