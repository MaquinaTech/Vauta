# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Run the app's `diarize` command over the 18-file set and score the result with score_der.py.

  python3 -I eval/scripts/run_diarization.py [--bin .build/release/Vauta] [--tag <name>] [--threshold 0.70]

Needs a release build (`swift build -c release --arch arm64`), the sets from build_sets.py and numpy. `Vauta diarize`
is an evaluation command: offline, no network, it writes only the RTTM named with --rttm and never audio. Output:
$VAUTA_EVAL_WORK/runs/<tag>/{ami_others,voxconverse}/*.rttm, timings.json and der.md / der.json per set.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_der as sd  # noqa: E402
from common import EVAL, PINS, RUNS, SETS, environment, log  # noqa: E402

DEFAULT_BIN = os.path.join(os.path.dirname(EVAL), ".build", "release", "Vauta")


def run_set(binary, name, out, extra):
    audio_dir = os.path.join(SETS, name, "audio")
    os.makedirs(out, exist_ok=True)
    timings = {}
    for fn in sorted(os.listdir(audio_dir)):
        uri = fn[:-4]
        rttm = os.path.join(out, uri + ".rttm")
        t0 = time.time()
        p = subprocess.run([binary, "diarize", os.path.join(audio_dir, fn), "--rttm", rttm] + extra, capture_output=True, text=True)
        wall = time.time() - t0
        if p.returncode != 0:
            raise SystemExit(f"diarize failed on {fn}: {p.stderr[-400:]}")
        m = re.search(r"(\d+) speakers", p.stderr)
        # The RTTM names files after the audio file; the references use the same ids (<m>_others, <id>).
        timings[uri] = dict(wall_s=round(wall, 2), speakers=int(m.group(1)) if m else None)
        log(f"{name}/{uri}: {p.stderr.strip().splitlines()[-1] if p.stderr.strip() else ''} (wall {wall:.1f} s)")
    return timings


def audio_seconds(path):
    import wave
    with wave.open(path, "rb") as w:
        return w.getnframes() / w.getframerate()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=DEFAULT_BIN)
    ap.add_argument("--tag", default=time.strftime("%Y%m%d-%H%M%S"))
    ap.add_argument("--threshold")
    ap.add_argument("--allow-missing", action="store_true", help="score files without a hypothesis RTTM as all missed")
    ap.add_argument("--no-run", action="store_true", help="only score the RTTMs already in the run directory")
    a = ap.parse_args()
    extra = ["--threshold", a.threshold] if a.threshold else []
    base = os.path.join(RUNS, a.tag)
    summary, raw, per_file = {}, {}, {}
    os.makedirs(base, exist_ok=True)
    json.dump(environment(a.bin), open(os.path.join(base, "environment.json"), "w"), indent=1)
    for name, uem_dirs in (("ami_others", ["uem", "uem_nobleed"]), ("voxconverse", [None])):
        out = os.path.join(base, name)
        timings = {}
        if not a.no_run:
            timings = run_set(a.bin, name, out, extra)
            for uri in timings:
                timings[uri]["audio_s"] = round(audio_seconds(os.path.join(SETS, name, "audio", uri + ".wav")), 1)
            json.dump(timings, open(os.path.join(base, f"timings_{name}.json"), "w"), indent=1)
        refs = sd.load_dir(os.path.join(SETS, name, "rttm"), sd.parse_rttm)
        hyps = sd.load_dir(out, sd.parse_rttm)
        missing = sd.missing_hypotheses(refs, hyps)
        if missing and not a.allow_missing:
            sys.exit(f"ERROR: {name}: no hypothesis RTTM for {len(missing)} of {len(refs)} files ({missing[:5]}); "
                     "a partial run would be scored as total miss. Rerun without --no-run, or pass --allow-missing.")
        for uem_dir in uem_dirs:
            uems = sd.load_dir(os.path.join(SETS, name, uem_dir), sd.parse_uem) if uem_dir else {}
            per, agg, errs = sd.score(refs, hyps, uems)
            label = f"{name}{'_' + uem_dir if uem_dir else ''}"
            raw[label] = agg
            per_file[label] = per
            text = sd.table(per, agg, errs)
            open(os.path.join(base, f"der_{label}.md"), "w").write(text + "\n")
            summary[label] = dict(files=len(errs), der_c025=sd.der(agg[0.25]), der_c0=sd.der(agg[0.0]),
                                  miss_c025=sd.pct(agg[0.25], "miss"), fa_c025=sd.pct(agg[0.25], "fa"), conf_c025=sd.pct(agg[0.25], "conf"),
                                  ref_s=agg[0.0]["ref"], exact=sum(e == 0 for e in errs), within1=sum(abs(e) <= 1 for e in errs))
            print(f"\n## {label}\n{text}")
            # Context: what "all remote speech is one speaker" (no separation, oracle speech detection) would score.
            one = {u: [(st, d, "one") for st, d, _ in rows] for u, rows in refs.items()}
            _, bl, _ = sd.score(refs, one, uems)
            summary[label]["one_speaker_baseline_der_c025"] = sd.der(bl[0.25])
            raw[label + "_baseline"] = bl
    # All 18 files pooled (speech-time weighted), with each AMI UEM variant.
    for ami in ("ami_others_uem", "ami_others_uem_nobleed"):
        pooled = {c: {k: raw[ami][c][k] + raw["voxconverse"][c][k] for k in ("ref", "miss", "fa", "conf")} for c in (0.0, 0.25)}
        summary[f"pooled_18_{ami}"] = dict(der_c025=sd.der(pooled[0.25]), der_c0=sd.der(pooled[0.0]))
        bl = {c: {k: raw[ami + "_baseline"][c][k] + raw["voxconverse_baseline"][c][k] for k in ("ref", "miss", "fa", "conf")} for c in (0.0, 0.25)}
        summary[f"pooled_18_{ami}"]["one_speaker_baseline_der_c025"] = sd.der(bl[0.25])
        print(f"pooled 18 files with {ami}: DER c0.25 {sd.der(pooled[0.25]):.2f}, c0 {sd.der(pooled[0.0]):.2f} (one-speaker baseline {sd.der(bl[0.25]):.2f})")
    # The two fixed halves of pins.json (AMI scored on the no-bleed region), pooled by speech time.
    pool = {**per_file["ami_others_uem_nobleed"], **per_file["voxconverse"]}
    for half, uris in ((h, PINS["diarization_halves"][h]) for h in ("half_a", "half_b")):
        agg = {c: {k: sum(pool[u][c][k] for u in uris) for k in ("ref", "miss", "fa", "conf")} for c in (0.0, 0.25)}
        summary[half] = dict(files=len(uris), uris=uris, der_c025=sd.der(agg[0.25]), der_c0=sd.der(agg[0.0]))
        print(f"{half} ({len(uris)} files): DER c0.25 {sd.der(agg[0.25]):.2f}, c0 {sd.der(agg[0.0]):.2f}")
    json.dump(summary, open(os.path.join(base, "summary.json"), "w"), indent=1)
    print("\nrun directory:", base)


if __name__ == "__main__":
    main()
