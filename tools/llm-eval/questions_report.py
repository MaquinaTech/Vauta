#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Scores the live-question detection and answers. usage:

  questions_report.py --sentences sentences.jsonl [--labels labels.jsonl] [--runs questions.apple.jsonl ...] [--split test|dev] [--hours name=H ...]

--sentences: the file `llm-eval --tasks live-questions --sentences` writes (every sentence with its cue score).
--labels: pool lines whose `label` object the labelling passes filled (see rubric/QUESTION_LABEL_RUBRIC.md). Without labels only the
          counts that need none are printed (sentences, candidates per hour, what reaches the model check).
--runs: the `questions/questions.<provider>.jsonl` files of `llm-eval --tasks live-questions` runs (one line per candidate sentence).

Precision and recall are against `label.kind == information`. A card is a true card when its sentence is `information` and `answerable`
is so_far, past_meeting or document; every other shown card counts as a false card. Latency is the simulated seconds from the end of
the question to the card. Nothing here judges the answers' text: that is the blind judge's (rubric/LIVE_ANSWER_RUBRIC.md adapted).
"""
import argparse, collections, json, statistics as st, sys

ap = argparse.ArgumentParser()
ap.add_argument("--sentences", required=True)
ap.add_argument("--labels")
ap.add_argument("--runs", nargs="*", default=[])
ap.add_argument("--split", choices=["dev", "test"])
ap.add_argument("--hours", nargs="*", default=[])
a = ap.parse_args()

sentences = [json.loads(l) for l in open(a.sentences)]
key = lambda r: (r["meeting"], r["line"], r["text"])
by_key = {key(r): r for r in sentences}
meetings = collections.defaultdict(lambda: 0.0)
for r in sentences:
    meetings[r["meeting"]] = max(meetings[r["meeting"]], r["end"])
for h in a.hours:
    n, v = h.split("="); meetings[n] = float(v) * 3600
hours = sum(meetings.values()) / 3600
# The hours of a run are those of the meetings it replayed: a meeting that is in the sentences file but was never replayed (an aggregate
# of other windows, say) must not dilute its rates. The first evaluation counted one such meeting (2.25 h of 28.7).
def replayed_hours(rows):
    names = {r["meeting"] for r in rows if "meeting" in r}
    return sum(v for m, v in meetings.items() if m in names) / 3600 if names else hours
out = {"meetings": len(meetings), "hours": round(hours, 2), "sentences": len(sentences), "with_question_mark": sum(r["hasQuestionMark"] for r in sentences)}
for thr, name in [(0.8, "low"), (0.5, "standard"), (0.35, "high")]:
    c = [r for r in sentences if r["score"] + 1e-9 >= thr]
    out[f"candidates_{name}"] = {"n": len(c), "per_hour": round(len(c) / hours, 1)}

labels = {}
if a.labels:
    for l in open(a.labels):
        r = json.loads(l)
        if r.get("label", {}).get("kind") and (a.split is None or r.get("split") == a.split):
            labels[(r["meeting"], r["line"], r["text"])] = r["label"]
    out["labelled"] = len(labels)

def prf(tp, fp, fn):
    p = tp / (tp + fp) if tp + fp else None
    r = tp / (tp + fn) if tp + fn else None
    return {"tp": tp, "fp": fp, "fn": fn, "precision": None if p is None else round(p, 3), "recall": None if r is None else round(r, 3)}

if labels and a.split:
    # Rates are per hour of the meetings of that split only.
    split_meetings = {k[0] for k in labels}
    hours = sum(v for m, v in meetings.items() if m in split_meetings) / 3600
    out["hours_of_split"] = round(hours, 2)
if labels:
    positives = {k for k, v in labels.items() if v["kind"] == "information"}
    out["information_labelled"] = len(positives)
    for thr, name in [(0.8, "low"), (0.5, "standard"), (0.35, "high")]:
        picked = {k for k in labels if k in by_key and by_key[k]["score"] + 1e-9 >= thr}
        out[f"s1_{name}"] = prf(len(picked & positives), len(picked - positives), len(positives - picked))
        for lang in sorted({v.get("language") for v in labels.values() if v.get("language")}):
            sub = {k for k in labels if labels[k].get("language") == lang}
            out[f"s1_{name}_{lang}"] = prf(len((picked & positives) & sub), len((picked - positives) & sub), len((positives - picked) & sub))

for path in a.runs:
    rows = [json.loads(l) for l in open(path)]
    name = path.split("/")[-1]
    outcomes = collections.Counter(r["outcome"] for r in rows)
    hours = replayed_hours(rows)
    run = {"candidates": len(rows), "outcomes": dict(outcomes), "hours_replayed": round(hours, 2), "meetings_replayed": len({r.get("meeting") for r in rows})}
    shown = [r for r in rows if r.get("shown")]
    lat = sorted(r["latencySeconds"] for r in shown if r.get("latencySeconds") is not None)
    if lat:
        run["latency_p50"] = round(lat[len(lat) // 2], 1); run["latency_p90"] = round(lat[min(len(lat) - 1, int(len(lat) * 0.9))], 1)
    run["cards_per_hour"] = round(len(shown) / hours, 2)
    run["model_checks_per_hour"] = round(sum(1 for r in rows if r.get("checkKind")) / hours, 1)
    run["answers_per_hour"] = round(sum(1 for r in rows if r.get("answerSeconds", 0) > 0) / hours, 1)
    if labels:
        reach = [r for r in rows if r["outcome"] in ("answered", "no_answer", "superseded", "stale", "rate_limited") and key(r) in labels]
        tp = sum(labels[key(r)]["kind"] == "information" for r in reach); fp = len(reach) - tp
        run["reaches_answer"] = prf(tp, fp, len(positives) - tp)
        good = lambda l: l["kind"] == "information" and l.get("answerable") in ("so_far", "past_meeting", "document")
        answerable = {k for k, v in labels.items() if good(v)}
        cards = {key(r) for r in shown if key(r) in labels}
        run["coverage_answerable"] = {"cards": len(cards & answerable), "answerable": len(answerable), "share": round(len(cards & answerable) / len(answerable), 3) if answerable else None}
        false_cards = [r for r in shown if key(r) not in labels or not good(labels[key(r)])]
        run["false_cards"] = len(false_cards); run["false_cards_per_hour"] = round(len(false_cards) / hours, 2)
        so_far = {k for k, v in labels.items() if good(v) and v.get("answerable") == "so_far"}
        run["recall_so_far"] = round(len(cards & so_far) / len(so_far), 3) if so_far else None
    out[name] = run
print(json.dumps(out, indent=1, ensure_ascii=False, sort_keys=True))
