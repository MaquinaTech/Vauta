# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Speaker-attributed error rates of the app's transcript on AMI: cpWER, tcpWER and WDER (score_cpwer.py).

  python3 -I eval/scripts/run_cpwer.py [--bin .build/release/Vauta] [--locale en-US] [--tag <name>] [--collar 5]

For each AMI meeting of the word-error-rate set (pins.json, `wer_meetings`), the first `wer_seconds` of the remote mix of
build_sets.py (three speakers summed, level-normalised, Opus coded: what the Others channel carries) go through
`Vauta attribute-file`: the app's transcription with word times, its speaker separation and its line splitting, as for an
imported recording. Each recognised word gets a speaker; the reference is the AMI manual word transcript of the three remote
speakers (as in run_wer.py), each word with its own speaker and time. Only the no-bleed region is scored (the UEM of the
speaker separation figures: where the fourth person, whose voice leaks into the remote headsets, is silent), on both sides
by the middle of each word. No oracle masking: the audio is the mix as it is.
Needs the speech model of the locale installed for the binary (`Vauta install-speech-assets --locale en-US`).
Output: $VAUTA_EVAL_WORK/runs/<tag>/cpwer.json and cpwer.md. Transcripts and word files are not kept (AMI is CC BY 4.0;
only counts are written).
"""
import argparse
import json
import os
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_cpwer as cp  # noqa: E402
from common import EVAL, PINS, RUNS, SETS, SR, SRC, log, read_wav, write_wav  # noqa: E402

AMI_SET = PINS.get("ami_set", "ami_others")
DEFAULT_BIN = os.path.join(os.path.dirname(EVAL), ".build", "release", "Vauta")


def reference(zf, letters, meeting, seconds):
    """[(speaker, start, end, text)] of the given {global name: letter} speakers, words starting before `seconds`."""
    out = []
    for speaker, letter in letters.items():
        for el in ET.fromstring(zf.read(f"words/{meeting}.{letter}.words.xml")):
            if el.tag != "w" or el.get("punc") == "true" or el.get("trunc") == "true":
                continue
            start = float(el.get("starttime", "nan"))
            if start < seconds:
                out.append((speaker, start, float(el.get("endtime", start)), el.text or ""))
    return out


def regions(path):
    return [(float(f[2]), float(f[3])) for f in (line.split() for line in open(path)) if len(f) >= 4]


def inside(word, spans):
    middle = (word[1] + word[2]) / 2
    return any(a <= middle < b for a, b in spans)


def attribute(binary, wav, locale, out):
    p = subprocess.run([binary, "attribute-file", wav, "--out", out, "--locale", locale, "--show-text", "--i-understand"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f"attribute-file failed on {wav}: {p.stderr[-300:]}")
    words = [json.loads(line) for line in open(out) if line.strip()]
    os.remove(out)
    return [(w.get("speaker"), w["start"], w["end"], w["text"]) for w in words]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=DEFAULT_BIN)
    ap.add_argument("--locale", default="en-US")
    ap.add_argument("--tag", default=time.strftime("%Y%m%d-%H%M%S"))
    ap.add_argument("--collar", type=float, default=5.0, help="seconds each side of a hypothesis word for tcpWER")
    ap.add_argument("--only", nargs="*", help="these meetings of the set only (a quick check)")
    a = ap.parse_args()
    seconds = PINS["wer_seconds"]
    info = json.load(open(os.path.join(SETS, AMI_SET, "info.json")))
    zf = zipfile.ZipFile(os.path.join(SRC, "ann", "ami_public_manual_1.6.2.zip"))
    letter = {}
    for mt in ET.fromstring(zf.read("corpusResources/meetings.xml")).iter("meeting"):
        letter[mt.get("observation")] = {s.get("global_name"): s.get("nxt_agent") for s in mt.iter("speaker")}
    tmp = os.path.join(RUNS, a.tag, "tmp")
    os.makedirs(tmp, exist_ok=True)
    rows = []
    total = dict(cp_errors=0, tcp_errors=0, words=0, wrong=0, recognised=0, blind_errors=0, hyp_speakers=0, wall=0.0)
    for m in [m for m in PINS["wer_meetings"] if not a.only or m in a.only]:
        meta = info[f"{m}_others"]
        spans = [(s, min(e, seconds)) for s, e in regions(os.path.join(SETS, AMI_SET, "uem_nobleed", f"{m}_others.uem")) if s < seconds]
        ref = [w for w in reference(zf, {s: letter[m][s] for s in meta["remote"]}, m, seconds) if inside(w, spans)]
        x, _ = read_wav(os.path.join(SETS, AMI_SET, "audio", f"{m}_others.wav"))
        clip = os.path.join(tmp, f"{m}_others.wav")
        write_wav(clip, x[:seconds * SR])
        t0 = time.time()
        said = attribute(a.bin, clip, a.locale, os.path.join(tmp, f"{m}.words.jsonl"))
        wall = time.time() - t0
        os.remove(clip)
        hyp = [w for w in said if inside(w, spans)]
        r, h = cp.tokens(ref), cp.tokens(hyp)
        plain, timed, d = cp.cp_wer(r, h), cp.cp_wer(r, h, collar=a.collar), cp.wder(r, h)
        speakers = len({w[0] for w in hyp if w[0] is not None})
        rows.append(dict(meeting=m, scored_s=round(sum(b - s for s, b in spans), 1), words=plain["words"], cpwer=plain["wer"],
                         tcpwer=timed["wer"], wder=d["wder"], wer=d["wer"], ref_speakers=len(r), hyp_speakers=speakers,
                         unattributed=sum(1 for w in hyp if w[0] is None), wall_s=round(wall, 1)))
        total["cp_errors"] += plain["errors"]
        total["tcp_errors"] += timed["errors"]
        total["words"] += plain["words"]
        total["wrong"] += d["wrong_speaker"]
        total["recognised"] += d["recognised"]
        total["blind_errors"] += round(d["wer"] * d["words"])
        total["hyp_speakers"] += speakers
        total["wall"] += wall
        log(f"{m}: cpWER {100 * plain['wer']:.1f}%, tcpWER {100 * timed['wer']:.1f}%, WDER {100 * d['wder']:.1f}%, "
            f"WER {100 * d['wer']:.1f}% of {plain['words']} words; {speakers} speakers for 3; {wall:.0f} s")
    os.rmdir(tmp)
    words = max(1, total["words"])
    summary = dict(meetings=len(rows), seconds=seconds, collar=a.collar, words=total["words"],
                   cpwer=total["cp_errors"] / words, tcpwer=total["tcp_errors"] / words,
                   wder=total["wrong"] / max(1, total["recognised"]), wer=total["blind_errors"] / words,
                   mean_hyp_speakers=total["hyp_speakers"] / max(1, len(rows)), wall_s=round(total["wall"], 1))
    json.dump(dict(summary=summary, files=rows), open(os.path.join(RUNS, a.tag, "cpwer.json"), "w"), indent=1)
    lines = [f"Pooled over {len(rows)} meetings ({summary['words']} reference words in the no-bleed region of the first {seconds} s):",
             f"cpWER {100 * summary['cpwer']:.1f} %, tcpWER (collar {a.collar:g} s) {100 * summary['tcpwer']:.1f} %, "
             f"WDER {100 * summary['wder']:.1f} %, speaker-blind WER {100 * summary['wer']:.1f} %, "
             f"{summary['mean_hyp_speakers']:.1f} speakers found for 3 on average.", "",
             "| Meeting | Words | cpWER | tcpWER | WDER | WER | Speakers found | Unattributed words |",
             "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for r in rows:
        lines.append(f"| {r['meeting']} | {r['words']} | {100 * r['cpwer']:.1f} % | {100 * r['tcpwer']:.1f} % | {100 * r['wder']:.1f} % | "
                     f"{100 * r['wer']:.1f} % | {r['hyp_speakers']} | {r['unattributed']} |")
    open(os.path.join(RUNS, a.tag, "cpwer.md"), "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
