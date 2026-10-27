# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Share of each speaker's turn time that another speaker's turn also covers, per run directory, with the gate the app
uses for voice recognition (`VoiceProfileThresholds.maximumOverlapShare` 0.40, at least 30 s of turn speech).

  python3 -I eval/scripts/overlap_shares.py <run dir> [<run dir> ...] [--sets ami_dev_others voxconverse_heldout]

Same definition as `SpeakerCentroids.overlapShares` (stretches of other speakers that cut a turn are merged so that a
stretch counts once). Reads the RTTMs a run wrote (<set>/*.rttm); prints one JSON object per run. Text only."""
import argparse
import glob
import json
import os
import statistics


def parse(path):
    turns = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) >= 8 and p[0] == "SPEAKER":
                start, dur = float(p[3]), float(p[4])
                turns.append((start, start + dur, p[7]))
    return turns


def overlap_shares(turns):
    turns = sorted(turns)
    total, shared = {}, {}
    for i, (s, e, spk) in enumerate(turns):
        total[spk] = total.get(spk, 0.0) + max(0.0, e - s)
        cuts = sorted((max(os_, s), min(oe, e)) for os_, oe, ospk in turns if ospk != spk and os_ < e and oe > s)
        covered, edge = 0.0, float("-inf")
        for a, b in cuts:
            a = max(a, edge)
            if b > a:
                covered += b - a
                edge = b
        shared[spk] = shared.get(spk, 0.0) + covered
    return {k: (min(1.0, shared[k] / v) if v > 0 else 0.0) for k, v in total.items()}, total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--sets", nargs="*", default=None)
    a = ap.parse_args()
    for run in a.runs:
        sets = a.sets or sorted(d for d in os.listdir(run) if os.path.isdir(os.path.join(run, d)))
        shares, eligible, kept = [], 0, 0
        for name in sets:
            for path in sorted(glob.glob(os.path.join(run, name, "*.rttm"))):
                share, total = overlap_shares(parse(path))
                for spk, seconds in total.items():
                    if seconds < 30:
                        continue
                    eligible += 1
                    shares.append(share[spk])
                    kept += share[spk] <= 0.40
        shares.sort()
        q = lambda f: round(shares[min(len(shares) - 1, int(f * len(shares)))], 3) if shares else None  # noqa: E731
        print(json.dumps({"run": os.path.basename(run.rstrip("/")), "sets": sets, "speakers_with_30s": eligible,
                          "clean_at_0.40": kept, "mean": round(statistics.fmean(shares), 3) if shares else None,
                          "median": q(0.5), "p90": q(0.9)}))


if __name__ == "__main__":
    main()
