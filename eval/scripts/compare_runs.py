# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Paired comparison of two diarization runs on the same sets: DER pooled as total error over the total reference time scored
with the collar (not weighted by per-set reference seconds; the two differ by about 0.1 point), speaker counts, and the
per-file change with a 95 % bootstrap interval (resampling files).

  python3 -I eval/scripts/compare_runs.py --sets-dir <sets> --before <run dir> --after <run dir> [--seed 1]

The tuning_set group needs a sets directory that holds ami_others and voxconverse (the main harness's <VAUTA_EVAL_WORK>/sets);
the other groups read eval/heldout/sets. A run directory is what run_diar_sets.py or run_diarization.py wrote (<set>/*.rttm). Groups: the scored region of each
set is the one named below (AMI: no-bleed). Prints one JSON object per group."""
import argparse
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_der as sd  # noqa: E402

# group name -> [(set directory, UEM subdirectory or None)]
GROUPS = {
    "tuning_set": [("ami_others", "uem_nobleed"), ("voxconverse", None)],
    "heldout_english": [("ami_dev_others", "uem_nobleed"), ("voxconverse_heldout", None)],
    "heldout_ami": [("ami_dev_others", "uem_nobleed")],
    "heldout_voxconverse": [("voxconverse_heldout", None)],
    "es_conv": [("es_conv", "uem")],
    "aug_calls": [("aug_calls", "uem_nodrop")],
}


def score_group(sets_dir, run, parts):
    tot = {c: {k: 0.0 for k in ("ref", "miss", "fa", "conf")} for c in (0.0, 0.25)}
    errs, per_file = [], {}
    for name, uem in parts:
        refs = sd.load_dir(os.path.join(sets_dir, name, "rttm"), sd.parse_rttm)
        hyps = sd.load_dir(os.path.join(run, name), sd.parse_rttm)
        uems = sd.load_dir(os.path.join(sets_dir, name, uem), sd.parse_uem) if uem else {}
        per, agg, e = sd.score(refs, hyps, uems)
        for c in tot:
            for k in tot[c]:
                tot[c][k] += agg[c][k]
        errs += e
        per_file.update({u: sd.der(r[0.25]) for u, r in per.items()})
    summary = {"der_c025": round(sd.der(tot[0.25]), 2), "der_c0": round(sd.der(tot[0.0]), 2),
               "miss": round(sd.pct(tot[0.25], "miss"), 2), "fa": round(sd.pct(tot[0.25], "fa"), 2),
               "conf": round(sd.pct(tot[0.25], "conf"), 2), "ref_s": round(tot[0.0]["ref"]), "files": len(errs),
               "count_exact": sum(x == 0 for x in errs), "count_within1": sum(abs(x) <= 1 for x in errs),
               "count_mean_error": round(sum(errs) / len(errs), 2)}
    return summary, per_file


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sets-dir", required=True)
    ap.add_argument("--before", required=True)
    ap.add_argument("--after", required=True)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    for group, parts in GROUPS.items():
        if not all(os.path.isdir(os.path.join(r, n)) for r in (a.before, a.after) for n, _ in parts):
            continue
        before, pb = score_group(a.sets_dir, a.before, parts)
        after, pa = score_group(a.sets_dir, a.after, parts)
        diffs = [pa[u] - pb[u] for u in pb]
        rnd = random.Random(a.seed)
        means = sorted(sum(rnd.choice(diffs) for _ in diffs) / len(diffs) for _ in range(10000))
        print(json.dumps({"group": group, "before": before, "after": after,
                          "per_file": {"better": sum(d < -0.05 for d in diffs), "worse": sum(d > 0.05 for d in diffs),
                                       "mean_change": round(sum(diffs) / len(diffs), 2),
                                       "ci95": [round(means[250], 2), round(means[9750], 2)]}}))


if __name__ == "__main__":
    main()
