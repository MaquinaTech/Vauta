# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Scores the minutes of `llm-eval --tasks minutes` against the human gold of build_ami_gold.py, by the passage each item cites.

A decision or task of the minutes cites one passage of the transcript. It is *grounded* in a human sentence when that passage is within
`--tolerance` passages (1 by default) of a passage the annotators linked to the sentence. Per provider, decisions are scored against
the human decisions and tasks against the human actions:

- found: the share of the human sentences that have a linked passage which some item of the same kind is grounded in (recall);
- supported: the share of the items grounded in a human sentence of the same kind (an item with no citation is not);
- in the summary: the share of the items grounded in any sentence of the human summary (abstract, decisions, actions, problems);
- at random: the share of the transcript's passages within the tolerance of a human sentence of that kind (or of any sentence of the
  summary), what a citation drawn at random would score as supported (or in the summary);
- owners: of the tasks grounded in an action whose subject names roles, the share whose owner is one of those speakers.

The items the minutes rank out ("Other possible items") are not counted as items; `found with other items` adds them to the recall.
AMI's sentences often hold several decisions ("It was decided that the remote would feature an LCD screen, rubber buttons, ..."), so a
sentence counts as found once and an item as supported by any sentence: there is no one-to-one matching. This scores where an item
points, not what it says: an item can cite the right passage and get it wrong, or say it right and cite another passage.

What an item says is scored with `--matches` and `--key`: the items a judge graded blind (gold_match_packets.py, the rubric in
eval/rubric/MINUTES_GOLD_MATCH.md) and the sealed key of those packets. Per provider and kind, over every human sentence, linked or not:
the human sentences some item states, in part or in full (found by content), those stated in full, the items that state one, and of
the stated sentences that have a link, the share whose item cites a passage within the tolerance of it (cited where it was said).

    python3 -I eval/scripts/score_minutes_gold.py --gold <folder> --minutes apple=<minutes.apple.jsonl> [--minutes integrated=<...>]
        [--tolerance 1] [--matches <blind>/items_graded.tsv --key <sealed>/key.json] [--out <folder>]
"""
import argparse
import csv
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "llm-eval"))
import stats  # noqa: E402

PAIRS = (("decision", "decisions"), ("action", "tasks"))  # human kind, field of the minutes
SPEAKER = re.compile(r"\bSpeaker (\d+)\b")
SUMS = ("linked", "found", "found_with_other_items", "items", "supported", "in_summary", "uncited", "other_items",
        "covered", "covered_summary", "passages", "owners_right", "owners_total")


def ranked_out(item):
    """An item the minutes' ranking left in "Other possible items" (`UnconfirmedReason.rankedOut`: `rank` or `rank:<code>`)."""
    reason = item.get("reason") or ""
    return bool(item.get("unconfirmed")) and (reason == "rank" or reason.startswith("rank:"))


def grounded(item, sentences, tolerance):
    """The human sentences whose linked passages the item's citations are within the tolerance of."""
    cites = [c for c in item.get("citations") or [] if isinstance(c, int)]
    return [s for s in sentences if any(abs(c - p) <= tolerance for c in cites for p in s["passages"])]


def owner(task):
    """"Speaker 2" from the owner the minutes stored for a speaker of the transcript; None for no owner or a person's name."""
    match = SPEAKER.search(task.get("owner") or "")
    return f"Speaker {match.group(1)}" if match else None


def covered(sentences, tolerance, count):
    """How many of the transcript's passages (ids 1 to count) are within the tolerance of a linked passage of the sentences."""
    return len({p for s in sentences for q in s["passages"] for p in range(q - tolerance, q + tolerance + 1) if 1 <= p <= count})


def score_meeting(gold, minutes, tolerance):
    """The counts of one meeting's minutes, per human kind."""
    summary = [s for s in gold["items"] if s["passages"]]
    count = gold.get("transcript_passages") or 0
    out = {}
    for kind, field in PAIRS:
        sentences = [s for s in gold["items"] if s["kind"] == kind]
        linked = [s for s in sentences if s["passages"]]
        items = [i for i in minutes.get(field) or [] if not ranked_out(i)]
        others = [i for i in minutes.get(field) or [] if ranked_out(i)]
        found = {s["id"] for i in items for s in grounded(i, linked, tolerance)}
        with_others = found | {s["id"] for i in others for s in grounded(i, linked, tolerance)}
        row = dict(sentences=len(sentences), linked=len(linked), found=len(found), found_with_other_items=len(with_others),
                   items=len(items), supported=sum(1 for i in items if grounded(i, linked, tolerance)),
                   in_summary=sum(1 for i in items if grounded(i, summary, tolerance)),
                   uncited=sum(1 for i in items if not i.get("citations")), other_items=len(others),
                   covered=covered(linked, tolerance, count), covered_summary=covered(summary, tolerance, count), passages=count,
                   owners_right=0, owners_total=0)
        if kind == "action":
            for task in items:
                named = {o for s in grounded(task, linked, tolerance) for o in s.get("owners", []) if o.startswith("Speaker ")}
                if named:
                    row["owners_total"] += 1
                    row["owners_right"] += owner(task) in named
        out[kind] = row
    return out


def rate(k, n):
    return round(k / n, 3) if n else None


def pooled(rows):
    """The sums of per-meeting rows, their rates and the meeting-cluster bootstrap interval of found and supported."""
    total = {key: sum(r[key] for r in rows) for key in SUMS}
    total["meetings"] = len(rows)

    def interval(num, den):
        lo, hi = stats.cluster_bootstrap([(r[num], r[den]) for r in rows],
                                         lambda sample: rate(sum(x for x, _ in sample), sum(n for _, n in sample)))
        return [round(lo, 3), round(hi, 3)] if lo is not None else None

    total.update(found_rate=rate(total["found"], total["linked"]), found_ci=interval("found", "linked"),
                 found_with_other_items_rate=rate(total["found_with_other_items"], total["linked"]),
                 supported_rate=rate(total["supported"], total["items"]), supported_ci=interval("supported", "items"),
                 in_summary_rate=rate(total["in_summary"], total["items"]), chance_rate=rate(total["covered"], total["passages"]),
                 summary_chance_rate=rate(total["covered_summary"], total["passages"]),
                 owners_rate=rate(total["owners_right"], total["owners_total"]))
    return total


def read_jsonl(path):
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def score(golds, providers, tolerance):
    """{provider: {"meetings": {meeting: counts}, "missing": [...], "all"/"test": {kind: pooled}}}."""
    report = {}
    for provider, lines in providers.items():
        by_case = {line.get("case"): line for line in lines}
        meetings = {m: score_meeting(g, by_case[m], tolerance) for m, g in sorted(golds.items()) if m in by_case}
        entry = {"meetings": meetings, "missing": sorted(m for m in golds if m not in by_case)}
        for split in ("all", "test"):
            chosen = [m for m in meetings if split == "all" or golds[m].get("split") == split]
            entry[split] = {kind: pooled([meetings[m][kind] for m in chosen]) for kind, _ in PAIRS}
        report[provider] = entry
    return report


def read_matches(graded, key):
    """{(provider, meeting, field, index): [(sentence id, "full" or "part")]} from the judge's graded items and the packets' key."""
    with open(key, encoding="utf-8") as f:
        items = json.load(f)["items"]
    out = {}
    with open(graded, encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            k = items[row["item_id"]]
            states = []
            for part in (row.get("states") or "").split(";"):
                human, _, grade = part.strip().partition("=")
                if human and human != "none":
                    states.append((human.split(":", 1)[1] if ":" in human else human, grade or "full"))
            out[(k["provider"], row["meeting"], k["field"], k["index"])] = states
    return out


CONTENT = ("human", "found", "found_full", "items", "stated", "pairs_linked", "pairs_cited")


def content_meeting(gold, minutes, matches, provider, tolerance):
    """The counts of one meeting's minutes by content, per human kind."""
    sentences = {s["id"]: s for s in gold["items"]}
    out = {}
    for kind, field in PAIRS:
        found, full = set(), set()
        row = dict.fromkeys(CONTENT, 0)
        row["human"] = sum(1 for s in gold["items"] if s["kind"] == kind)
        for index, item in enumerate(minutes.get(field) or []):
            if ranked_out(item):
                continue
            row["items"] += 1
            stated = [(h, g) for h, g in matches.get((provider, gold["meeting"], field, index), []) if sentences.get(h, {}).get("kind") == kind]
            row["stated"] += bool(stated)
            for human, grade in stated:
                found.add(human)
                if grade == "full":
                    full.add(human)
                if sentences[human]["passages"]:
                    row["pairs_linked"] += 1
                    row["pairs_cited"] += bool(grounded(item, [sentences[human]], tolerance))
        row["found"], row["found_full"] = len(found), len(full)
        out[kind] = row
    return out


def pooled_content(rows):
    total = {key: sum(r[key] for r in rows) for key in CONTENT}
    total["meetings"] = len(rows)

    def interval(num, den):
        lo, hi = stats.cluster_bootstrap([(r[num], r[den]) for r in rows],
                                         lambda sample: rate(sum(x for x, _ in sample), sum(n for _, n in sample)))
        return [round(lo, 3), round(hi, 3)] if lo is not None else None

    total.update(found_rate=rate(total["found"], total["human"]), found_ci=interval("found", "human"),
                 found_full_rate=rate(total["found_full"], total["human"]),
                 stated_rate=rate(total["stated"], total["items"]), stated_ci=interval("stated", "items"),
                 cited_rate=rate(total["pairs_cited"], total["pairs_linked"]))
    return total


def score_content(golds, providers, matches, tolerance):
    """Like `score`, by what the items say: {provider: {"meetings": ..., "all"/"test": {kind: pooled}}}."""
    report = {}
    for provider, lines in providers.items():
        by_case = {line.get("case"): line for line in lines}
        meetings = {m: content_meeting(g, by_case[m], matches, provider, tolerance) for m, g in sorted(golds.items()) if m in by_case}
        entry = {"meetings": meetings}
        for split in ("all", "test"):
            chosen = [m for m in meetings if split == "all" or golds[m].get("split") == split]
            entry[split] = {kind: pooled_content([meetings[m][kind] for m in chosen]) for kind, _ in PAIRS}
        report[provider] = entry
    return report


def percent(value):
    return "–" if value is None else f"{100 * value:.0f} %"


def table(report, split):
    lines = ["| Provider | Kind | Human sentences | Found | With other items | Items | Supported | At random | In the human summary | At random | Owners |",
             "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for provider, entry in report.items():
        for kind, field in PAIRS:
            t = entry[split][kind]
            ci = lambda c: f" [{percent(c[0])}, {percent(c[1])}]" if c else ""
            owners = f"{t['owners_right']} of {t['owners_total']}" if kind == "action" else "–"
            lines.append(f"| {provider} | {field} | {t['linked']} | {percent(t['found_rate'])}{ci(t['found_ci'])} "
                         f"| {percent(t['found_with_other_items_rate'])} | {t['items']} | {percent(t['supported_rate'])}{ci(t['supported_ci'])} "
                         f"| {percent(t['chance_rate'])} | {percent(t['in_summary_rate'])} | {percent(t['summary_chance_rate'])} | {owners} |")
    return "\n".join(lines)


def content_table(report, split):
    lines = ["| Provider | Kind | Human sentences | Found by content | In full | Items | Stating one | Cited where it was said |",
             "|---|---|---:|---:|---:|---:|---:|---:|"]
    for provider, entry in report.items():
        for kind, field in PAIRS:
            t = entry[split][kind]
            ci = lambda c: f" [{percent(c[0])}, {percent(c[1])}]" if c else ""
            lines.append(f"| {provider} | {field} | {t['human']} | {percent(t['found_rate'])}{ci(t['found_ci'])} | {percent(t['found_full_rate'])} "
                         f"| {t['items']} | {percent(t['stated_rate'])}{ci(t['stated_ci'])} | {t['pairs_cited']} of {t['pairs_linked']} |")
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--gold", required=True, help="folder of <meeting>.gold.json (build_ami_gold.py)")
    ap.add_argument("--minutes", action="append", required=True, metavar="PROVIDER=FILE", help="minutes.<provider>.jsonl of llm-eval")
    ap.add_argument("--tolerance", type=int, default=1, help="passages of slack around a linked passage (default 1)")
    ap.add_argument("--matches", help="items_graded.tsv of a blind judge (gold_match_packets.py)")
    ap.add_argument("--key", help="the sealed key.json of those packets")
    ap.add_argument("--out", help="folder for gold_scores.json and gold_scores.md")
    a = ap.parse_args(argv)
    if bool(a.matches) != bool(a.key):
        ap.error("--matches and --key go together")
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
    report = score(golds, providers, a.tolerance)
    test = sum(1 for g in golds.values() if g.get("split") == "test")
    md = [f"Tolerance ±{a.tolerance} passage{'s' if a.tolerance != 1 else ''}; {len(golds)} meetings with a human summary, {test} of them test.", "",
          "All meetings:", "", table(report, "all"), "", "Test meetings:", "", table(report, "test")]
    for provider, entry in report.items():
        if entry["missing"]:
            md += ["", f"{provider}: no minutes for {', '.join(entry['missing'])} (left out)."]
    content = score_content(golds, providers, read_matches(a.matches, a.key), a.tolerance) if a.matches else None
    if content:
        md += ["", "By content (the judge's matches), all meetings:", "", content_table(content, "all"), "",
               "By content, test meetings:", "", content_table(content, "test")]
    text = "\n".join(md) + "\n"
    print(text)
    if a.out:
        os.makedirs(a.out, exist_ok=True)
        with open(os.path.join(a.out, "gold_scores.json"), "w", encoding="utf-8") as f:
            json.dump({"tolerance": a.tolerance, "providers": report, "content": content}, f, indent=1, sort_keys=True)
        with open(os.path.join(a.out, "gold_scores.md"), "w", encoding="utf-8") as f:
            f.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
