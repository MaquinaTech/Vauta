# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Spanish WER of `Vauta transcribe-file --locale es-ES` on sets/es_wer (MLS CC-BY-4.0, VoxPopuli CC0).
  python3 -I eval/scripts/run_wer_es.py --bin <Vauta> --tag <name>
Output $VAUTA_EVAL_WORK/runs/<tag>/wer_es.json, wer_es.md (strict and accent-folded WER per file and per source)."""
import argparse, json, os, re, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hpins as P, common as C, score_wer_es as S

def transcribe(binary, wav, locale):
    p = subprocess.run([binary, "transcribe-file", wav, "--locale", locale, "--show-text", "--i-understand"], capture_output=True, text=True)
    if p.returncode != 0: raise SystemExit(f"transcribe-file failed: {p.stderr[-300:]}")
    out = []
    for line in p.stderr.splitlines():
        m = re.match(r"^\[([\d:]+)\]\s?(.*)$", line)
        if m: out.append(m.group(2))
    return " ".join(out)

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--bin", required=True); ap.add_argument("--tag", required=True)
    ap.add_argument("--set", default="es_wer"); ap.add_argument("--locale", default="es-ES"); a = ap.parse_args()
    base = os.path.join(P.RUNS, a.tag); os.makedirs(base, exist_ok=True)
    info = json.load(open(f"{P.SETS}/{a.set}/info.json")); rows = []; tot = {}
    for name in sorted(info):
        ref = open(f"{P.SETS}/{a.set}/ref/{name}.txt").read()
        t0 = time.time(); hyp = transcribe(a.bin, f"{P.SETS}/{a.set}/audio/{name}.wav", a.locale); wall = time.time() - t0
        r = {"strict": S.wer(ref, hyp), "folded": S.wer(ref, hyp, True)}
        rows.append(dict(file=name, source=info[name]["source"], seconds=info[name]["seconds"], wall_s=round(wall, 1), **r))
        for src in (info[name]["source"], "all"):
            for k, v in r.items():
                t = tot.setdefault((src, k), dict(sub=0, dele=0, ins=0, words=0))
                for f in t: t[f] += v[f]
        C.log(name, f"strict {r['strict']['wer']:.1f}% folded {r['folded']['wer']:.1f}% ({wall:.0f}s)")
    summ = {f"{s}_{k}": dict(**t, wer=100.0 * (t['sub'] + t['dele'] + t['ins']) / t['words']) for (s, k), t in tot.items()}
    json.dump(dict(locale=a.locale, files=rows, summary=summ), open(f"{base}/wer_es.json", "w"), indent=1)
    L = ["| file | source | min | ref words | S | D | I | WER strict % | WER folded % |", "|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        g = r["strict"]; L.append(f"| {r['file']} | {r['source']} | {r['seconds']/60:.1f} | {g['words']} | {g['sub']} | {g['dele']} | {g['ins']} | {g['wer']:.1f} | {r['folded']['wer']:.1f} |")
    for s in ("voxpopuli", "mls", "all"):
        g, f = summ[f"{s}_strict"], summ[f"{s}_folded"]
        L.append(f"| **{s}** | | | {g['words']} | {g['sub']} | {g['dele']} | {g['ins']} | **{g['wer']:.1f}** | **{f['wer']:.1f}** |")
    open(f"{base}/wer_es.md", "w").write("\n".join(L) + "\n"); print("\n".join(L))

if __name__ == "__main__":
    main()
