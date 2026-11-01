# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Blind grading of minutes items against the transcript around the passage each cites (eval/rubric/MINUTES_ITEM_SUPPORT.md).

`packets`: per meeting, the decisions and tasks every set of minutes shows (the items ranked into "Other possible items" are left
out), mixed and shuffled under neutral ids, each with the passages around the one it cites. No label is named in `blind/`;
`sealed/key.json` maps each id to its label, kind and position, and `blind/key.sha256` seals it before any judging. The judge
fills `blind/grades.tsv`.

`score`: per label, the items the transcript supports (`yes`), those it supports only weakly (`weak`) and the rest (`no`), with a
meeting-cluster bootstrap interval; with `--compare BASE,NEW`, the paired per-meeting difference of the supported share and its
non-inferiority test (two one-sided t tests, `--margin`).

    python3 -I eval/scripts/item_support.py packets --sets <folder of <meeting>.json> --minutes base=<minutes.jsonl>
        --minutes new=<minutes.jsonl> --out <folder> [--context 6] [--seed 31]
    python3 -I eval/scripts/item_support.py score --grades <blind>/grades.tsv --key <sealed>/key.json
        [--compare base,new] [--margin 0.10] [--out <folder>]
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
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "llm-eval"))
from score_minutes_gold import read_jsonl, ranked_out  # noqa: E402
import stats  # noqa: E402

RUBRIC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "rubric", "MINUTES_ITEM_SUPPORT.md")
FIELDS = (("decision", "decisions"), ("task", "tasks"))
GRADES = ("yes", "weak", "no")


def context(passages, cites, width):
    """The passages from `width` before the first cited one to `width` after the last, in order."""
    if not cites:
        return []
    low, high = min(cites) - width, max(cites) + width
    return [p for p in passages if low <= p["id"] <= high]


def render(item_id, kind, item, passages, width):
    """One item of items.md: its id and kind, its text, owner and due date, and the passages around its citation."""
    cites = [c for c in item.get("citations") or [] if isinstance(c, int)]
    lines = [f"### {item_id} · {kind}", "", " ".join((item.get("text") or "").split())]
    extra = [f"Owner: {item['owner']}" if item.get("owner") else "", f"Due: {item['due']}" if item.get("due") else ""]
    if any(extra):
        lines.append(" · ".join(e for e in extra if e))
    lines.append("")
    shown = context(passages, cites, width)
    if not shown:
        lines.append("    (no passage cited)")
    for p in shown:
        mark = "►" if p["id"] in cites else " "
        lines.append(f"    {mark} {p['id']:>4} {p.get('speaker') or '?'}: {' '.join((p.get('text') or '').split())}")
    return lines + [""]


def packets(sets, minutes, seed, width):
    """(markdown lines, grade rows, key) for the meetings of `sets` that some minutes cover."""
    rnd = random.Random(seed)
    md, rows, key = ["# Items to grade", ""], [], {}
    for meeting, transcript in sorted(sets.items()):
        shown = []
        for label, lines in sorted(minutes.items()):
            record = next((line for line in lines if line.get("case") == meeting), None)
            for kind, field in FIELDS:
                for index, item in enumerate((record or {}).get(field) or []):
                    if not ranked_out(item):
                        shown.append((label, kind, field, index, item))
        if not shown:
            continue
        rnd.shuffle(shown)
        md += [f"## {meeting}", ""]
        for n, (label, kind, field, index, item) in enumerate(shown, 1):
            item_id = f"{meeting}:I{n:02d}"
            key[item_id] = {"label": label, "field": field, "index": index, "meeting": meeting, "unconfirmed": bool(item.get("unconfirmed"))}
            md += render(item_id, kind, item, transcript["passages"], width)
            rows.append([meeting, item_id, kind, "", ""])
    return md, rows, key


def read_sets(folder):
    out = {}
    for name in sorted(os.listdir(folder)):
        if name.endswith(".json"):
            with open(os.path.join(folder, name), encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict) and "passages" in data and "meeting" in data:
                out[data["meeting"]] = data
    return out


def write_packets(a):
    minutes = {}
    for spec in a.minutes:
        label, _, path = spec.partition("=")
        if not path:
            raise SystemExit(f"--minutes takes LABEL=FILE, not {spec}")
        minutes[label] = read_jsonl(path)
    md, rows, key = packets(read_sets(a.sets), minutes, a.seed, a.context)
    blind, sealed = os.path.join(a.out, "blind"), os.path.join(a.out, "sealed")
    os.makedirs(blind, exist_ok=True)
    os.makedirs(sealed, exist_ok=True)
    with open(os.path.join(blind, "items.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(md))
    with open(os.path.join(blind, "grades.tsv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, delimiter="\t")
        w.writerow(["meeting", "item_id", "kind", "support", "note"])
        w.writerows(rows)
    shutil.copy(RUBRIC, os.path.join(blind, "INSTRUCTIONS.md"))
    text = json.dumps({"seed": a.seed, "context": a.context, "items": key}, sort_keys=True, indent=1)
    with open(os.path.join(sealed, "key.json"), "w", encoding="utf-8") as f:
        f.write(text)
    digest = hashlib.sha256(text.encode()).hexdigest()
    with open(os.path.join(blind, "key.sha256"), "w", encoding="utf-8") as f:
        f.write(digest + "\n")
    print(f"{len(rows)} items; key sha256 {digest}")


def read_grades(path, key):
    """{item id: grade}; every id of the key must be graded with one of GRADES."""
    with open(path, encoding="utf-8", newline="") as f:
        graded = {row["item_id"]: (row.get("support") or "").strip().lower() for row in csv.DictReader(f, delimiter="\t")}
    missing = sorted(i for i in key if i not in graded)
    bad = sorted(i for i, g in graded.items() if i in key and g not in GRADES)
    if missing or bad:
        raise SystemExit(f"grades: {len(missing)} items not graded, {len(bad)} with a grade other than {'/'.join(GRADES)}")
    return graded


def rate(k, n):
    return round(k / n, 3) if n else None


def tally(ids, key, graded, firm_only=False):
    """Per meeting: (yes, weak, items)."""
    out = {}
    for i in ids:
        if firm_only and key[i]["unconfirmed"]:
            continue
        y, w, n = out.get(key[i]["meeting"], (0, 0, 0))
        out[key[i]["meeting"]] = (y + (graded[i] == "yes"), w + (graded[i] == "weak"), n + 1)
    return out


def summary(per_meeting):
    rows = list(per_meeting.values())
    yes, weak, items = (sum(r[k] for r in rows) for k in range(3))
    lo, hi = stats.cluster_bootstrap(rows, lambda s: rate(sum(r[0] for r in s), sum(r[2] for r in s)))
    return {"items": items, "yes": yes, "weak": weak, "no": items - yes - weak, "supported_rate": rate(yes, items),
            "supported_ci": [round(lo, 3), round(hi, 3)] if lo is not None else None, "at_least_weak_rate": rate(yes + weak, items)}


def compare(base, new, margin):
    """The paired per-meeting difference of the supported share (new minus base) over the meetings with items in both."""
    meetings = sorted(m for m in base if m in new and base[m][2] and new[m][2])
    diffs = [new[m][0] / new[m][2] - base[m][0] / base[m][2] for m in meetings]
    if len(diffs) < 2:
        return {"meetings": len(diffs)}
    test = stats.tost_paired(diffs, margin)
    return {"meetings": len(diffs), "margin": margin, "mean_difference": round(test["mean"], 3),
            "interval_90": [round(x, 3) for x in test["interval"]], "p_lower": round(test["p_lower"], 4), "noninferior": test["noninferior"]}


def score(a):
    with open(a.key, encoding="utf-8") as f:
        key = json.load(f)["items"]
    graded = read_grades(a.grades, key)
    labels = sorted({v["label"] for v in key.values()})
    report = {"labels": {}}
    for label in labels:
        ids = [i for i, v in key.items() if v["label"] == label]
        report["labels"][label] = {"all": summary(tally(ids, key, graded)), "firm": summary(tally(ids, key, graded, firm_only=True))}
    if a.compare:
        base, new = a.compare.split(",")
        per = {lab: tally([i for i, v in key.items() if v["label"] == lab], key, graded) for lab in (base, new)}
        report["compare"] = {"base": base, "new": new, **compare(per[base], per[new], a.margin)}
    lines = ["| Minutes | Items | Supported | 95 % interval | At least weak | Firm items | Firm supported |", "|---|---:|---:|---|---:|---:|---:|"]
    for label, r in report["labels"].items():
        al, fi = r["all"], r["firm"]
        ci = "–" if not al["supported_ci"] else f"[{al['supported_ci'][0]:.0%}, {al['supported_ci'][1]:.0%}]"
        lines.append(f"| {label} | {al['items']} | {al['supported_rate']:.0%} | {ci} | {al['at_least_weak_rate']:.0%} | {fi['items']} | "
                     + ("–" if fi["supported_rate"] is None else f"{fi['supported_rate']:.0%}") + " |")
    if "compare" in report and "noninferior" in report["compare"]:
        c = report["compare"]
        lines += ["", f"{c['new']} minus {c['base']}, per meeting ({c['meetings']}): mean {c['mean_difference']:+.3f}, 90 % interval "
                  f"[{c['interval_90'][0]:+.3f}, {c['interval_90'][1]:+.3f}]; non-inferior at margin {c['margin']}: {c['noninferior']} (p {c['p_lower']})."]
    print("\n".join(lines))
    if a.out:
        os.makedirs(a.out, exist_ok=True)
        with open(os.path.join(a.out, "support_scores.json"), "w", encoding="utf-8") as f:
            json.dump(report, f, indent=1, sort_keys=True)
        with open(os.path.join(a.out, "support_scores.md"), "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    return report


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="command", required=True)
    p = sub.add_parser("packets")
    p.add_argument("--sets", required=True, help="folder of <meeting>.json (the llm-eval sets)")
    p.add_argument("--minutes", action="append", required=True, metavar="LABEL=FILE")
    p.add_argument("--out", required=True)
    p.add_argument("--context", type=int, default=6, help="passages shown before and after the cited one (default 6)")
    p.add_argument("--seed", type=int, default=31)
    s = sub.add_parser("score")
    s.add_argument("--grades", required=True)
    s.add_argument("--key", required=True)
    s.add_argument("--compare", help="BASE,NEW: the paired difference and its non-inferiority test")
    s.add_argument("--margin", type=float, default=0.10)
    s.add_argument("--out")
    a = ap.parse_args(argv)
    if a.command == "packets":
        write_packets(a)
    else:
        score(a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
