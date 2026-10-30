# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Whether the microphone heard the others, on real speech: `Vauta echo-coupling` over the AMI sets (run build_sets.py first).

  python3 -I eval/scripts/run_echo_coupling.py [--bin .build/release/Vauta] [--tag <name>] [--seconds 600]

While recording, the app measures from the loudness of its two channels whether the microphone hears the Others channel
(EchoCoupling): over speakers it does, and the echo marks run; when it never does in a minute of the others speaking ("never
heard": headphones) no echo is marked; and a microphone that hears them in two of the last six windows suggests headphones
("heard lately"). Its thresholds were set on simulated energies. This measures them on real speech: the first `--seconds` of
the 10 AMI meetings, "me" being the participant build_sets.py left out of the Others mix, and the Others file that mix (three
headsets, level-normalised, Opus coded). The Me file is, by condition:

  room        me's raw headset. The participants sat in one room, so the headset hears the others faintly, like a microphone
              hearing speakers turned low: the hardest case to hear (expected: heard, never "never heard").
  speakers    me's raw headset with the Others mix added 20 dB lower and 150 ms later: speakers at a usual level (expected:
              heard; the delay is 0.15 s, or about 0 where the room's cross-talk is the stronger).
  headphones  me's raw headset of the next meeting in pins.json, whose room never heard this Others mix (expected: never heard).

Output: $VAUTA_EVAL_WORK/runs/<tag>/echo_coupling.json and echo_coupling.md. The files built for the command are temporary and
removed as soon as it has read them.
"""
import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np  # noqa: E402
from common import EVAL, PINS, RUNS, SETS, SR, SRC, log, read_wav, write_wav  # noqa: E402

AMI_SET = PINS.get("ami_set", "ami_others")
DEFAULT_BIN = os.path.join(os.path.dirname(EVAL), ".build", "release", "Vauta")
LINE = re.compile(r"windows (\d+) · heard (\d+) · delay (-|-?[\d.]+ s) · never heard (true|false) · heard lately (true|false)")
CONDITIONS = ("room", "speakers", "headphones")
SPEAKERS_GAIN, SPEAKERS_DELAY = 0.1, 0.15


def coupling(binary, me, others):
    out = subprocess.run([binary, "echo-coupling", me, others], capture_output=True, text=True, check=True).stdout
    m = LINE.search(out)
    if not m:
        raise SystemExit(f"echo-coupling printed something else: {out!r}")
    windows, heard, delay, never, lately = m.groups()
    return dict(windows=int(windows), heard=int(heard), delay=None if delay == "-" else float(delay[:-2]),
                never_heard=never == "true", heard_lately=lately == "true")


def summary(rows):
    out = {}
    for c in CONDITIONS:
        r = [x for x in rows if x["condition"] == c]
        windows = sum(x["windows"] for x in r)
        delays = [x["delay"] for x in r if x["delay"] is not None]
        out[c] = dict(meetings=len(r), windows=windows, heard_share=sum(x["heard"] for x in r) / windows if windows else None,
                      never_heard=sum(x["never_heard"] for x in r), heard_lately=sum(x["heard_lately"] for x in r),
                      median_delay=statistics.median(delays) if delays else None)
    return out


def markdown(rows, summ, seconds):
    lines = [f"# Whether the microphone heard the others (AMI, first {seconds:.0f} s of 10 meetings)", "",
             "| Condition | Expected | Windows | Heard | Never heard | Heard lately | Median delay |",
             "|---|---|---:|---:|---:|---:|---:|"]
    expected = {"room": "heard", "speakers": "heard", "headphones": "never heard"}
    for c in CONDITIONS:
        s = summ[c]
        share = "-" if s["heard_share"] is None else f"{100 * s['heard_share']:.1f} %"
        delay = "-" if s["median_delay"] is None else f"{s['median_delay']:.2f} s"
        lines.append(f"| {c} | {expected[c]} | {s['windows']} | {share} | {s['never_heard']}/{s['meetings']} | "
                     f"{s['heard_lately']}/{s['meetings']} | {delay} |")
    lines += ["", "| Meeting | Condition | Windows | Heard | Delay | Never heard | Heard lately |", "|---|---|---:|---:|---:|---|---|"]
    for x in rows:
        delay = "-" if x["delay"] is None else f"{x['delay']:.2f} s"
        lines.append(f"| {x['meeting']} | {x['condition']} | {x['windows']} | {x['heard']} | {delay} | {x['never_heard']} | {x['heard_lately']} |")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=DEFAULT_BIN)
    ap.add_argument("--tag", default="echo-coupling")
    ap.add_argument("--seconds", type=float, default=600)
    a = ap.parse_args()
    info = json.load(open(os.path.join(SETS, AMI_SET, "info.json")))
    with zipfile.ZipFile(f"{SRC}/ann/ami_public_manual_1.6.2.zip") as zf:
        root = ET.fromstring(zf.read("corpusResources/meetings.xml"))
    chan = {mt.get("observation"): {s.get("global_name"): int(s.get("channel")) for s in mt.iter("speaker")} for mt in root.iter("meeting")}
    meetings = PINS["ami_meetings"]
    n = int(a.seconds * SR)

    def headset(m):
        x, sr = read_wav(f"{SRC}/ami-audio/{m}/{m}.Headset-{chan[m][info[f'{m}_others']['me_speaker']]}.wav")
        assert sr == SR, sr
        return x[:n]

    rows = []
    with tempfile.TemporaryDirectory(dir=SETS) as tmp:
        for i, m in enumerate(meetings):
            others, sr = read_wav(os.path.join(SETS, AMI_SET, "audio", f"{m}_others.wav"))
            assert sr == SR, sr
            others = others[:n]
            others_path = os.path.join(tmp, "others.wav")
            write_wav(others_path, others)
            mine = headset(m)
            speakers = mine.copy()
            lag = int(SPEAKERS_DELAY * SR)
            end = min(len(speakers), len(others) + lag)
            speakers[lag:end] += SPEAKERS_GAIN * others[:end - lag]
            for c, x in zip(CONDITIONS, (mine, speakers, headset(meetings[(i + 1) % len(meetings)]))):
                path = os.path.join(tmp, f"{c}.wav")
                write_wav(path, x)
                r = coupling(a.bin, path, others_path)
                os.remove(path)
                rows.append(dict(meeting=m, condition=c, **r))
                log(m, c, r)
            os.remove(others_path)
    summ = summary(rows)
    out = os.path.join(RUNS, a.tag)
    os.makedirs(out, exist_ok=True)
    json.dump(dict(seconds=a.seconds, speakers_gain=SPEAKERS_GAIN, speakers_delay=SPEAKERS_DELAY, summary=summ, rows=rows),
              open(os.path.join(out, "echo_coupling.json"), "w"), indent=1)
    open(os.path.join(out, "echo_coupling.md"), "w").write(markdown(rows, summ, a.seconds))
    log("wrote", out)


if __name__ == "__main__":
    main()
