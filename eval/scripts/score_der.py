# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Independent diarization error rate (DER) scorer. Python standard library plus numpy; no pyannote.

  python3 -I eval/scripts/score_der.py --ref <ref rttm dir> --hyp <hyp rttm dir> [--uem <uem dir>] [--out result.md] [--json result.json]

Frame-based on a 10 ms grid, in the NIST form: for every scored frame with nr reference and nh hypothesis speakers, and
with the best one-to-one mapping of hypothesis to reference speakers (Hungarian, maximising the matched frame count),
  miss = max(0, nr - nh)   false alarm = max(0, nh - nr)   confusion = min(nr, nh) - matched
  DER = (miss + false alarm + confusion) / reference speech time.
Overlapped speech is scored (nothing is skipped). `--collar` frames: a no-score zone of +-0.25 s around every
reference segment boundary (the NIST / VoxConverse convention) is reported next to the no-collar figure. Files are
matched by RTTM file id (column 2); a missing hypothesis is an error (`--allow-missing` scores it as empty, everything missed). The UEM (optional) limits
the scored time. Speaker counts use only speakers with at least 10 s of speech inside the scored time, on both sides.
Cross-checked against pyannote.metrics 4.1 (same engine outputs): see docs/BENCHMARKS.md.
"""
import argparse
import json
import os
import sys

import numpy as np

H = 0.01
MIN_SPEAKER_SECONDS = 10.0


def parse_rttm(path):
    """-> {uri: [(start, duration, speaker)]}"""
    out = {}
    for line in open(path):
        x = line.split()
        if len(x) >= 8 and x[0] == "SPEAKER":
            out.setdefault(x[1], []).append((float(x[3]), float(x[4]), x[7]))
    return out


def parse_uem(path):
    out = {}
    for line in open(path):
        x = line.split()
        if len(x) >= 4:
            out.setdefault(x[0], []).append((float(x[2]), float(x[3])))
    return out


def load_dir(d, parser):
    out = {}
    for fn in sorted(os.listdir(d)):
        if fn.endswith((".rttm", ".uem")):
            for uri, v in parser(os.path.join(d, fn)).items():
                out.setdefault(uri, []).extend(v)
    return out


def missing_hypotheses(refs, hyps):
    """Reference files with no hypothesis: scored as total miss, which would silently inflate a published DER."""
    return sorted(set(refs) - set(hyps))


def hungarian_max(weights):
    """Assignment maximising the total weight for a rows x cols matrix. Returns {row: col} (rows <= cols after padding)."""
    w = np.asarray(weights, dtype=np.int64)
    n, m = w.shape
    size = max(n, m)
    cost = np.zeros((size, size), dtype=np.int64)
    cost[:n, :m] = w.max() - w if w.size else 0
    # Kuhn-Munkres with potentials (O(size^3)); sizes here are at most a few dozen.
    INF = 1 << 60
    u = [0] * (size + 1)
    v = [0] * (size + 1)
    p = [0] * (size + 1)
    way = [0] * (size + 1)
    for i in range(1, size + 1):
        p[0] = i
        j0 = 0
        minv = [INF] * (size + 1)
        used = [False] * (size + 1)
        while True:
            used[j0] = True
            i0, delta, j1 = p[j0], INF, 0
            for j in range(1, size + 1):
                if not used[j]:
                    cur = int(cost[i0 - 1, j - 1]) - u[i0] - v[j]
                    if cur < minv[j]:
                        minv[j], way[j] = cur, j0
                    if minv[j] < delta:
                        delta, j1 = minv[j], j
            for j in range(size + 1):
                if used[j]:
                    u[p[j]] += delta
                    v[j] -= delta
                else:
                    minv[j] -= delta
            j0 = j1
            if p[j0] == 0:
                break
        while j0:
            j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
    return {p[j] - 1: j - 1 for j in range(1, size + 1) if p[j] - 1 < n and j - 1 < m}


def raster(rows, labels, total):
    mat = np.zeros((len(labels), total), bool)
    index = {l: i for i, l in enumerate(labels)}
    for s, d, spk in rows:
        mat[index[spk], int(round(s / H)):int(round((s + d) / H))] = True
    return mat


def score_file(ref_rows, hyp_rows, uem_intervals, collar):
    """-> dict with seconds of reference speech, miss, false alarm, confusion, and speaker counts."""
    end = max([s + d for s, d, _ in ref_rows] + [s + d for s, d, _ in hyp_rows] + [0.0]) + 1.0
    if uem_intervals:
        end = max(end, max(b for _, b in uem_intervals) + 1.0)
    total = int(end / H) + 2
    mask = np.zeros(total, bool)
    for a, b in (uem_intervals or [(0.0, end)]):
        mask[int(round(a / H)):int(round(b / H))] = True
    if collar > 0:
        for s, d, _ in ref_rows:
            for b in (s, s + d):
                mask[max(0, int(round((b - collar) / H))):int(round((b + collar) / H))] = False
    ref_labels = sorted({r[2] for r in ref_rows})
    hyp_labels = sorted({r[2] for r in hyp_rows})
    R = raster(ref_rows, ref_labels, total)[:, mask]
    Hh = raster(hyp_rows, hyp_labels, total)[:, mask] if hyp_labels else np.zeros((0, int(mask.sum())), bool)
    nr = R.sum(0, dtype=np.int32)
    nh = Hh.sum(0, dtype=np.int32)
    matched = 0
    if len(ref_labels) and len(hyp_labels):
        overlap = np.array([[int((R[i] & Hh[j]).sum()) for j in range(len(hyp_labels))] for i in range(len(ref_labels))])
        matched = int(sum(overlap[i, j] for i, j in hungarian_max(overlap).items()))
    miss = int(np.maximum(nr - nh, 0).sum())
    fa = int(np.maximum(nh - nr, 0).sum())
    conf = int(np.minimum(nr, nh).sum()) - matched
    # Speaker counts use the whole UEM (no collar), so the collar does not change them.
    return dict(ref=float(nr.sum()) * H, miss=miss * H, fa=fa * H, conf=conf * H,
                ref_speakers=ref_labels, hyp_speakers=hyp_labels)


def speaker_counts(ref_rows, hyp_rows, uem_intervals):
    end = max([s + d for s, d, _ in ref_rows] + [s + d for s, d, _ in hyp_rows] + [0.0]) + 1.0
    total = int(end / H) + 2
    mask = np.zeros(total, bool)
    for a, b in (uem_intervals or [(0.0, end)]):
        mask[int(round(a / H)):int(round(b / H))] = True

    def count(rows):
        labels = sorted({r[2] for r in rows})
        if not labels:
            return 0
        mat = raster(rows, labels, total)[:, mask]
        return int((mat.sum(1) * H >= MIN_SPEAKER_SECONDS).sum())
    return count(ref_rows), count(hyp_rows)


def score(refs, hyps, uems):
    per, agg = {}, {c: dict(ref=0.0, miss=0.0, fa=0.0, conf=0.0) for c in (0.0, 0.25)}
    errs = []
    for uri in sorted(refs):
        hyp = hyps.get(uri, [])
        uem = uems.get(uri)
        row = {}
        for c in (0.0, 0.25):
            r = score_file(refs[uri], hyp, uem, c)
            row[c] = r
            for k in ("ref", "miss", "fa", "conf"):
                agg[c][k] += r[k]
        nref, nhyp = speaker_counts(refs[uri], hyp, uem)
        row["spk"] = (nref, nhyp)
        errs.append(nhyp - nref)
        per[uri] = row
    return per, agg, errs


def der(r):
    return 100.0 * (r["miss"] + r["fa"] + r["conf"]) / r["ref"] if r["ref"] else 0.0


def pct(r, k):
    return 100.0 * r[k] / r["ref"] if r["ref"] else 0.0


def table(per, agg, errs):
    n = len(errs)
    lines = ["| file | ref speech (s) | ref spk | hyp spk | DER c0.25 | Miss | FA | Conf | DER c0 | Miss | FA | Conf |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for uri, row in per.items():
        a, b = row[0.25], row[0.0]
        lines.append(f"| {uri} | {b['ref']:.0f} | {row['spk'][0]} | {row['spk'][1]} | {der(a):.1f} | {pct(a, 'miss'):.1f} | {pct(a, 'fa'):.1f} "
                     f"| {pct(a, 'conf'):.1f} | {der(b):.1f} | {pct(b, 'miss'):.1f} | {pct(b, 'fa'):.1f} | {pct(b, 'conf'):.1f} |")
    a, b = agg[0.25], agg[0.0]
    lines.append(f"| **all {n} files** | {b['ref']:.0f} | | | **{der(a):.1f}** | {pct(a, 'miss'):.1f} | {pct(a, 'fa'):.1f} | {pct(a, 'conf'):.1f} "
                 f"| **{der(b):.1f}** | {pct(b, 'miss'):.1f} | {pct(b, 'fa'):.1f} | {pct(b, 'conf'):.1f} |")
    exact = sum(e == 0 for e in errs)
    near = sum(abs(e) <= 1 for e in errs)
    lines += ["", f"Speaker count (speakers with at least {MIN_SPEAKER_SECONDS:.0f} s, both sides): exact {exact}/{n}, within 1: {near}/{n}, "
                 f"mean signed error {sum(errs) / n:+.2f}.",
              "c0.25 = no-score zone of 0.25 s each side of every reference boundary; c0 = no collar. Overlap scored. "
              "Miss, FA and Conf are percent of reference speech time; the total row is weighted by speech time."]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", required=True)
    ap.add_argument("--hyp", required=True)
    ap.add_argument("--uem")
    ap.add_argument("--out")
    ap.add_argument("--json")
    ap.add_argument("--allow-missing", action="store_true",
                    help="score a reference file without a hypothesis as all missed instead of failing")
    a = ap.parse_args()
    refs, hyps = load_dir(a.ref, parse_rttm), load_dir(a.hyp, parse_rttm)
    uems = load_dir(a.uem, parse_uem) if a.uem else {}
    missing = missing_hypotheses(refs, hyps)
    if missing:
        msg = f"no hypothesis for {len(missing)} of {len(refs)} reference file(s): {missing[:5]}"
        if not a.allow_missing:
            sys.exit(f"ERROR: {msg}. A truncated run would publish an inflated DER; pass --allow-missing to score them as all missed.")
        print(f"note: {msg}, counted as all missed", file=sys.stderr)
    per, agg, errs = score(refs, hyps, uems)
    text = table(per, agg, errs)
    print(text)
    if a.out:
        open(a.out, "w").write(text + "\n")
    if a.json:
        json.dump({"files": {u: {"der_c0.25": der(r[0.25]), "der_c0": der(r[0.0]), "ref_speakers": r["spk"][0], "hyp_speakers": r["spk"][1]}
                             for u, r in per.items()},
                   "aggregate": {"der_c0.25": der(agg[0.25]), "der_c0": der(agg[0.0]),
                                 "miss_c0.25": pct(agg[0.25], "miss"), "fa_c0.25": pct(agg[0.25], "fa"), "conf_c0.25": pct(agg[0.25], "conf"),
                                 "miss_c0": pct(agg[0.0], "miss"), "fa_c0": pct(agg[0.0], "fa"), "conf_c0": pct(agg[0.0], "conf"),
                                 "ref_seconds": agg[0.0]["ref"], "files": len(errs)}}, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
