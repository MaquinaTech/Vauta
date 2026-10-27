# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Run `Vauta diarize` over one or more sets and score with score_der.py (the repo's scorer).
  python3 -I eval/scripts/run_diar_sets.py --bin <Vauta> --tag baseline --sets ami_dev_others es_conv ... [--uem-dirs uem uem_nobleed] [--threshold 0.70]
Per set: $VAUTA_EVAL_WORK/runs/<tag>/<set>/*.rttm, timings_<set>.json, der_<set>[_<uem>].md / .json."""
import argparse, json, os, re, subprocess, sys, time, wave
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_der as sd, hpins as P, common as C

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True); ap.add_argument("--tag", required=True)
    ap.add_argument("--sets", nargs="+", required=True); ap.add_argument("--threshold")
    ap.add_argument("--no-run", action="store_true"); a = ap.parse_args()
    extra = ["--threshold", a.threshold] if a.threshold else []
    base = os.path.join(P.RUNS, a.tag); os.makedirs(base, exist_ok=True)
    json.dump(C.environment(a.bin), open(f"{base}/environment.json", "w"), indent=1)
    summary = {}
    for name in a.sets:
        sdir = f"{P.SETS}/{name}"; out = f"{base}/{name}"; os.makedirs(out, exist_ok=True)
        timings = {}
        for fn in sorted(os.listdir(f"{sdir}/audio")):
            uri = fn[:-4]; rttm = f"{out}/{uri}.rttm"
            if a.no_run and os.path.exists(rttm): continue
            t0 = time.time()
            p = subprocess.run([a.bin, "diarize", f"{sdir}/audio/{fn}", "--rttm", rttm] + extra, capture_output=True, text=True)
            if p.returncode: raise SystemExit(f"diarize failed {fn}: {p.stderr[-300:]}")
            with wave.open(f"{sdir}/audio/{fn}") as w: dur = w.getnframes() / w.getframerate()
            m = re.search(r"(\d+) speakers", p.stderr)
            timings[uri] = dict(wall_s=round(time.time() - t0, 2), audio_s=round(dur, 1), speakers=int(m.group(1)) if m else None)
            C.log(name, uri, timings[uri])
        if timings: json.dump(timings, open(f"{base}/timings_{name}.json", "w"), indent=1)
        refs = sd.load_dir(f"{sdir}/rttm", sd.parse_rttm); hyps = sd.load_dir(out, sd.parse_rttm)
        miss = sd.missing_hypotheses(refs, hyps)
        if miss: sys.exit(f"missing hypotheses {miss[:4]}")
        uem_dirs = [d for d in sorted(os.listdir(sdir)) if d.startswith("uem")] or [None]
        for ud in uem_dirs:
            uems = sd.load_dir(f"{sdir}/{ud}", sd.parse_uem) if ud else {}
            per, agg, errs = sd.score(refs, hyps, uems)
            label = f"{name}__{ud or 'nouem'}"
            open(f"{base}/der_{label}.md", "w").write(sd.table(per, agg, errs) + "\n")
            one = {u: [(s, d, "one") for s, d, _ in r] for u, r in refs.items()}
            _, bl, _ = sd.score(refs, one, uems)
            summary[label] = dict(files=len(errs), der_c025=round(sd.der(agg[0.25]), 2), der_c0=round(sd.der(agg[0.0]), 2),
                                  miss=round(sd.pct(agg[0.25], "miss"), 2), fa=round(sd.pct(agg[0.25], "fa"), 2), conf=round(sd.pct(agg[0.25], "conf"), 2),
                                  ref_s=round(agg[0.0]["ref"]), exact_count=sum(e == 0 for e in errs), within1=sum(abs(e) <= 1 for e in errs),
                                  mean_count_err=round(sum(errs) / len(errs), 2), one_speaker_baseline_der_c025=round(sd.der(bl[0.25]), 2),
                                  per_file={u: dict(der_c025=round(sd.der(r[0.25]), 1), ref_spk=r["spk"][0], hyp_spk=r["spk"][1]) for u, r in per.items()})
            C.log(label, {k: v for k, v in summary[label].items() if k != "per_file"})
    old = json.load(open(f"{base}/summary.json")) if os.path.exists(f"{base}/summary.json") else {}
    old.update(summary); json.dump(old, open(f"{base}/summary.json", "w"), indent=1)

if __name__ == "__main__":
    main()
