# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Which separated speakers of an AMI "others" set are the left-out participant, heard as cross-talk.

  python3 -I eval/scripts/left_out_voice.py <run dir> [--set ami_others] [--share 0.5]

build_sets.py leaves one participant ("me") out of the Others mix. The three remote headsets still hear that participant faintly
across the room, and the mix is level-normalised, so the voice is in the audio while the reference (the remote speakers only)
lacks it. A diarizer rightly finds it, and the speaker count then reads one too many. This names, per file, each separated
speaker with at least `--share` of its time where only the left-out participant speaks (in the full AMI reference), and gives the
speaker count without them next to the reference's (no-bleed region and the 10 s rule, as score_der.py counts).
Reads the run's RTTMs, the set's info.json and the pinned AMI references; prints markdown. Text only.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np  # noqa: E402
import score_der as sd  # noqa: E402
from common import PINS, SETS, SRC  # noqa: E402


def frames(rows, n):
    m = np.zeros(n, bool)
    for s, d, _ in rows:
        m[int(round(s / sd.H)):int(round((s + d) / sd.H))] = True
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--set", default=PINS.get("ami_set", "ami_others"))
    ap.add_argument("--share", type=float, default=0.5, help="share of a speaker's time where only the left-out participant speaks")
    a = ap.parse_args()
    info = json.load(open(os.path.join(SETS, a.set, "info.json")))
    refs = sd.load_dir(os.path.join(SETS, a.set, "rttm"), sd.parse_rttm)
    uems = sd.load_dir(os.path.join(SETS, a.set, "uem_nobleed"), sd.parse_uem)
    hyps = sd.load_dir(os.path.join(a.run, a.set), sd.parse_rttm)
    lines = [f"Separated speakers that are the left-out participant ({a.set}, at least {100 * a.share:.0f} % of their time where only that "
             "participant speaks):", "",
             "| file | ref spk | hyp spk | the left-out participant | hyp spk without it |", "|---|---|---|---|---|"]
    before, after = [], []
    for uri in sorted(info):
        m = info[uri]
        hyp = hyps.get(uri, [])
        full = sd.parse_rttm(os.path.join(SRC, "ami-setup", "only_words", "rttms", m["split"], m["meeting"] + ".rttm"))[m["meeting"]]
        n = int(max([m["duration"]] + [s + d for s, d, _ in hyp]) / sd.H) + 2
        only_me = frames([r for r in full if r[2] == m["me_speaker"]], n) & ~frames([r for r in full if r[2] in m["remote"]], n)
        left_out = {}
        for spk in sorted({r[2] for r in hyp}):
            f = frames([r for r in hyp if r[2] == spk], n)
            if f.any() and (f & only_me).sum() / f.sum() >= a.share:
                left_out[spk] = (f.sum() * sd.H, (f & only_me).sum() / f.sum())
        nref, nhyp = sd.speaker_counts(refs[uri], hyp, uems.get(uri))
        _, nkept = sd.speaker_counts(refs[uri], [r for r in hyp if r[2] not in left_out], uems.get(uri))
        before.append(nhyp - nref)
        after.append(nkept - nref)
        named = ", ".join(f"{s} ({t:.0f} s, {100 * share:.0f} %)" for s, (t, share) in left_out.items()) or "-"
        lines.append(f"| {uri} | {nref} | {nhyp} | {named} | {nkept} |")
    k = len(before)
    lines += ["", f"Speaker count exact: {sum(e == 0 for e in before)}/{k} as scored, {sum(e == 0 for e in after)}/{k} without the left-out "
              f"participant; mean signed error {sum(before) / k:+.2f} and {sum(after) / k:+.2f}."]
    print("\n".join(lines))


if __name__ == "__main__":
    main()
