# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Word error rate of the app's offline transcription on AMI, against AMI's manual word transcripts.

  python3 -I eval/scripts/run_wer.py [--bin .build/release/Vauta] [--locale en-US] [--tag <name>] [--pad 0.25]

For each AMI meeting in pins.json, the first `wer_seconds` of two conditions are transcribed with
`Vauta transcribe-file <wav> --show-text --i-understand` (the text comes on stderr; AMI is a public corpus, this is
not a real meeting):
  headset  the raw close-talk headset (no gain, no codec) of the speaker who talks most in the window. The best case.
  others   the remote mix built by build_sets.py (three speakers summed, level-normalised, Opus coded): what the Others
           channel carries. Speech that overlaps is one stream for a single recogniser, so this includes the overlap loss.
The reference is the AMI manual word transcript (words/<meeting>.<speaker>.words.xml in the pinned annotations zip):
the words, without punctuation tokens, vocal sounds or truncated fragments, of the scored speakers whose start falls
inside the window, in time order. Both sides go through score_wer.normalize (documented there).

Oracle masking (the headline figure). A headset also picks up its neighbours, and the others mix is level-normalised per
speaker, so it carries faint voices that the reference of the scored speakers does not include (the user's own voice in
the remote headsets, a neighbour in a headset). A recogniser rightly transcribes them and the scorer counts them as
insertions. To measure recognition rather than that artifact, the audio is muted outside the scored speakers' reference
turns (plus `--pad` seconds each side) before it is transcribed, using the AMI reference segmentation. The figure without
masking (`wer_unmasked`) is reported next to it. Neither is a real-call figure.
Needs the speech model of the locale installed for the binary (`Vauta install-speech-assets --locale en-US`).
Output: $VAUTA_EVAL_WORK/runs/<tag>/wer.json and wer.md. Transcripts are not kept.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_wer as sw  # noqa: E402
from common import EVAL, PINS, RUNS, SETS, SR, SRC, log, read_wav, write_wav  # noqa: E402

AMI_SET = PINS.get("ami_set", "ami_others")

DEFAULT_BIN = os.path.join(os.path.dirname(EVAL), ".build", "release", "Vauta")


def reference_words(zf, letters, meeting, seconds):
    """Words of the given speaker letters starting before `seconds`, in time order, as one text."""
    words = []
    for letter in letters:
        root = ET.fromstring(zf.read(f"words/{meeting}.{letter}.words.xml"))
        for el in root:
            if el.tag != "w" or el.get("punc") == "true" or el.get("trunc") == "true":
                continue
            start = float(el.get("starttime", "nan"))
            if start < seconds:
                words.append((start, float(el.get("endtime", start)), el.text or ""))
    return " ".join(w[2] for w in sorted(words))


def transcribe(binary, wav, locale):
    """-> [(start seconds, text)] of the final segments."""
    p = subprocess.run([binary, "transcribe-file", wav, "--locale", locale, "--show-text", "--i-understand"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f"transcribe-file failed on {wav}: {p.stderr[-300:]}")
    out = []
    for line in p.stderr.splitlines():
        m = re.match(r"^\[([\d:]+)\]\s?(.*)$", line)
        if m:
            secs = 0
            for part in m.group(1).split(":"):
                secs = secs * 60 + int(part)
            out.append((secs, m.group(2)))
    return out


def speech_regions(rttm, speakers):
    """Intervals (start, end) when any of `speakers` talks, from an AMI RTTM."""
    iv = []
    for line in open(rttm):
        x = line.split()
        if len(x) >= 8 and x[7] in speakers:
            iv.append((float(x[3]), float(x[3]) + float(x[4])))
    return iv


def mask_outside(x, regions, pad):
    """Mute every sample that is not within `pad` seconds of a region."""
    import numpy as np
    keep = np.zeros(len(x), bool)
    for a, b in regions:
        keep[max(0, int((a - pad) * SR)):int((b + pad) * SR)] = True
    return np.where(keep, x, 0.0).astype(np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=DEFAULT_BIN)
    ap.add_argument("--locale", default="en-US")
    ap.add_argument("--tag", default=time.strftime("%Y%m%d-%H%M%S"))
    ap.add_argument("--pad", type=float, default=0.25, help="seconds kept around each reference turn when masking")
    a = ap.parse_args()
    seconds = PINS["wer_seconds"]
    info = json.load(open(os.path.join(SETS, AMI_SET, "info.json")))
    zf = zipfile.ZipFile(os.path.join(SRC, "ann", "ami_public_manual_1.6.2.zip"))
    letter = {}
    for mt in ET.fromstring(zf.read("corpusResources/meetings.xml")).iter("meeting"):
        letter[mt.get("observation")] = {s.get("global_name"): s.get("nxt_agent") for s in mt.iter("speaker")}
    split = {}
    for sp in ("test", "dev", "train"):
        for m in open(f"{SRC}/ami-setup/lists/{sp}.meetings.txt").read().split():
            split[m] = sp
    tmp = os.path.join(RUNS, a.tag, "tmp")
    os.makedirs(tmp, exist_ok=True)
    conds = ("headset", "others")
    modes = ("masked", "unmasked")
    rows = []
    totals = {c: {g: dict(sub=0, dele=0, ins=0, words=0) for g in modes} | dict(wall=0.0, audio=0.0) for c in conds}
    for m in PINS["wer_meetings"]:
        meta = info[f"{m}_others"]
        rttm = f"{SRC}/ami-setup/only_words/rttms/{split[m]}/{m}.rttm"
        for cond in conds:
            speakers = [meta["headset_speaker"]] if cond == "headset" else meta["remote"]
            ref = reference_words(zf, [letter[m][s] for s in speakers], m, seconds)
            src = os.path.join(SETS, AMI_SET, "headset", f"{m}_headset.wav") if cond == "headset" \
                else os.path.join(SETS, AMI_SET, "audio", f"{m}_others.wav")
            x, sr = read_wav(src)
            x = x[:seconds * SR]
            regions = speech_regions(rttm, set(speakers))
            res, wall = {}, 0.0
            for mode in modes:
                clip = os.path.join(tmp, f"{m}_{cond}_{mode}.wav")
                write_wav(clip, mask_outside(x, regions, a.pad) if mode == "masked" else x)
                t0 = time.time()
                text = " ".join(t for _, t in transcribe(a.bin, clip, a.locale))
                wall += time.time() - t0
                os.remove(clip)
                res[mode] = sw.wer(ref, text)
            audio = len(x) / SR
            rows.append(dict(meeting=m, condition=cond, audio_s=audio, wall_s=round(wall, 1), masked=res["masked"], unmasked=res["unmasked"]))
            t = totals[cond]
            for g, r in res.items():
                for k in ("sub", "dele", "ins", "words"):
                    t[g][k] += r[k]
            t["wall"] += wall
            t["audio"] += audio
            g = res["masked"]
            log(f"{m} {cond}: WER {g['wer']:.1f}% ({g['sub']} S, {g['dele']} D, {g['ins']} I of {g['words']} words); "
                f"unmasked {res['unmasked']['wer']:.1f}%; {wall / 2:.1f} s per pass for {audio:.0f} s of audio")
    os.rmdir(tmp)

    def pct(t):
        return 100.0 * (t["sub"] + t["dele"] + t["ins"]) / t["words"]
    summary = {c: dict(wer=pct(t["masked"]), wer_unmasked=pct(t["unmasked"]), **t["masked"], audio_s=t["audio"] / 1, wall_s_per_pass=round(t["wall"] / 2, 1))
               for c, t in totals.items()}
    json.dump(dict(locale=a.locale, window_s=seconds, pad_s=a.pad, files=rows, summary=summary),
              open(os.path.join(RUNS, a.tag, "wer.json"), "w"), indent=1)
    lines = ["| meeting | condition | ref words | S | D | I | WER % (oracle-masked) | WER % (unmasked) |", "|---|---|---|---|---|---|---|---|"]
    for r in rows:
        g = r["masked"]
        lines.append(f"| {r['meeting']} | {r['condition']} | {g['words']} | {g['sub']} | {g['dele']} | {g['ins']} | {g['wer']:.1f} | {r['unmasked']['wer']:.1f} |")
    for c, s in summary.items():
        lines.append(f"| **all {len(PINS['wer_meetings'])}** | **{c}** | {s['words']} | {s['sub']} | {s['dele']} | {s['ins']} | **{s['wer']:.1f}** | {s['wer_unmasked']:.1f} |")
    text = "\n".join(lines)
    open(os.path.join(RUNS, a.tag, "wer.md"), "w").write(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
