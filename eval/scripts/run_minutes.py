# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Minutes written by the app about public AMI meetings, with the mechanical citation checks of score_minutes.py.

  python3 -I eval/scripts/run_minutes.py [--bin .build/release/Vauta] [--tag <name>] [--seconds 600]

For each AMI meeting of the word-error-rate set (pins.json, `wer_meetings`), the AMI manual word transcript of the first
`--seconds` seconds, all four participants, is cut into passages (a speaker's words with pauses under one second, three
words or more), numbered in time order, and given to `Vauta minutes-file`: the app's own minutes code (prompts, block
summaries for a window that does not fit, validation, the "Unconfirmed" checks) with Apple's on-device model, in a
throwaway store in a temporary folder. It contacts no model server. Then `score_minutes.score` counts, over the decisions
and tasks the app kept: the share with a citation, the share whose citation is valid (it exists and contains every figure
the item states), the share marked Unconfirmed, and how many of the model's proposals the app dropped before that.
The manual transcript is used, not Apple's recogniser, so the figures measure the minutes writer, not the recogniser.
Needs Apple Intelligence turned on for the binary. Output: $VAUTA_EVAL_WORK/runs/<tag>/minutes.json and minutes.md.
Neither the transcripts nor the minutes are kept (AMI is CC BY 4.0; only counts are written).
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_minutes as sm  # noqa: E402
from common import EVAL, PINS, RUNS, SRC, environment, log  # noqa: E402

DEFAULT_BIN = os.path.join(os.path.dirname(EVAL), ".build", "release", "Vauta")
PAUSE = 1.0
MIN_WORDS = 3


def passages(zf, meeting, letters, seconds):
    """-> [{"id", "start", "text"}] in time order from the manual words of the given speaker letters."""
    out = []
    for letter in letters:
        root = ET.fromstring(zf.read(f"words/{meeting}.{letter}.words.xml"))
        current, last_end = [], None
        for el in root:
            if el.tag != "w" or el.get("trunc") == "true":
                continue
            start = float(el.get("starttime", "nan"))
            if not start < seconds:
                continue
            punc = el.get("punc") == "true"
            if current and not punc and last_end is not None and start - last_end > PAUSE:
                out.append(current)
                current = []
            if not current and punc:
                continue
            current.append((start, float(el.get("endtime", start)), el.text or "", punc))
            last_end = current[-1][1]
        if current:
            out.append(current)
    result = []
    for words in sorted(out, key=lambda w: w[0][0]):
        text = ""
        for _, _, token, punc in words:
            text += token if punc or not text else " " + token
        if sum(1 for w in words if not w[3]) >= MIN_WORDS:
            result.append((words[0][0], text))
    return [{"id": i + 1, "start": round(s, 2), "text": t} for i, (s, t) in enumerate(result)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=DEFAULT_BIN)
    ap.add_argument("--tag", default=time.strftime("%Y%m%d-%H%M%S"))
    ap.add_argument("--seconds", type=int, default=PINS["wer_seconds"])
    a = ap.parse_args()
    zf = zipfile.ZipFile(os.path.join(SRC, "ann", "ami_public_manual_1.6.2.zip"))
    letters = {}
    for mt in ET.fromstring(zf.read("corpusResources/meetings.xml")).iter("meeting"):
        letters[mt.get("observation")] = sorted({s.get("nxt_agent") for s in mt.iter("speaker")})
    os.makedirs(os.path.join(RUNS, a.tag), exist_ok=True)
    rows, all_items, proposed, dropped, calls, model = [], [], 0, 0, 0, None
    with tempfile.TemporaryDirectory(prefix="vauta-minutes-") as tmp:
        for m in PINS["wer_meetings"]:
            ps = passages(zf, m, letters[m], a.seconds)
            tpath, mpath = os.path.join(tmp, f"{m}.transcript.json"), os.path.join(tmp, f"{m}.minutes.json")
            json.dump({"passages": ps}, open(tpath, "w"))
            t0 = time.time()
            p = subprocess.run([a.bin, "minutes-file", tpath, "--out", mpath, "--locale", "en-US"], capture_output=True, text=True)
            if p.returncode != 0:
                # A window the model could not answer (cut off, refused) is a result, not a reason to stop the run.
                reason = p.stderr.strip().splitlines()[-1][:200] if p.stderr.strip() else "no message"
                rows.append(dict(meeting=m, passages=len(ps), failed=reason, wall_s=round(time.time() - t0, 1)))
                log(f"{m}: no minutes: {reason}")
                continue
            res = json.load(open(mpath))
            model = res["model"]
            score = sm.score(ps, res["items"])
            score.update(meeting=m, passages=len(ps), proposed=res["proposed"], dropped=res["dropped"], model_calls=res["modelCalls"],
                         wall_s=round(time.time() - t0, 1))
            rows.append(score)
            all_items += res["items"]
            proposed += res["proposed"]
            dropped += res["dropped"]
            calls += res["modelCalls"]
            log(f"{m}: {len(ps)} passages, {res['proposed']} proposed, {len(res['items'])} kept, "
                f"validity {score['citation_validity']}, unconfirmed {score['unconfirmed_share']}")
    failed = [r for r in rows if "failed" in r]
    rows = [r for r in rows if "failed" not in r]
    # Pool the items of every meeting: passage ids repeat across meetings, so score per meeting and add up.
    cited = sum(round((r["cited_share"] or 0) * r["items"]) for r in rows)
    valid = sum(round((r["citation_validity"] or 0) * round((r["cited_share"] or 0) * r["items"])) for r in rows)
    unconfirmed = sum(round((r["unconfirmed_share"] or 0) * r["items"]) for r in rows)
    silent = sum(r["invalid_not_marked"] for r in rows)
    n = len(all_items)
    rate = lambda x, y: (x / y) if y else None  # noqa: E731
    summary = dict(model=model, meetings=len(rows), meetings_failed=[dict(meeting=r["meeting"], reason=r["failed"]) for r in failed], window_s=a.seconds, transcript="AMI manual words", proposed=proposed, dropped=dropped,
                   dropped_share=rate(dropped, proposed), items=n, cited_share=rate(cited, n), citation_validity=rate(valid, cited),
                   unconfirmed_share=rate(unconfirmed, n), invalid_not_marked=silent, model_calls=calls)
    json.dump(dict(summary=summary, files=rows + failed), open(os.path.join(RUNS, a.tag, "minutes.json"), "w"), indent=1)
    pct = lambda x: "n/a" if x is None else f"{100 * x:.1f}"  # noqa: E731
    lines = ["| meeting | passages | proposed | dropped | kept | cited % | valid citations % | Unconfirmed % |", "|---|---|---|---|---|---|---|---|"]
    for r in rows:
        lines.append(f"| {r['meeting']} | {r['passages']} | {r['proposed']} | {r['dropped']} | {r['items']} | {pct(r['cited_share'])} | "
                     f"{pct(r['citation_validity'])} | {pct(r['unconfirmed_share'])} |")
    lines.append(f"| **all {len(rows)}** | | **{proposed}** | **{dropped}** | **{n}** | **{pct(summary['cited_share'])}** | "
                 f"**{pct(summary['citation_validity'])}** | **{pct(summary['unconfirmed_share'])}** |")
    for r in failed:
        lines.append(f"| {r['meeting']} | {r['passages']} | no minutes: {r['failed']} | | | | | |")
    text = "\n".join(lines)
    open(os.path.join(RUNS, a.tag, "minutes.md"), "w").write(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
