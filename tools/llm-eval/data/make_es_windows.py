# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
# Cut a window of ~N minutes from a source MP3 at silence boundaries, transcribe + diarize with Vauta's own CLI, merge to a transcript JSON.
# python3 -I scripts/make_es_windows.py <src.mp3 basename> <start_min> <dur_min> <window id>
import json, os, re, subprocess, sys
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VAUTA = f"{H}/build/release/Vauta"
src, start_min, dur_min, wid = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
LOCALE = os.environ.get("ES_LOCALE", "es-ES")
mp3 = f"{H}/audio/src/{src}"
def snap(t, span=90):
    """nearest silence (>=0.8 s, -35 dB) midpoint within +-span s of t, else t"""
    a = max(0, t - span)
    p = subprocess.run(["ffmpeg", "-nostats", "-ss", str(a), "-t", str(2 * span), "-i", mp3, "-af", "silencedetect=noise=-35dB:d=0.8", "-f", "null", "-"], capture_output=True, text=True).stderr
    st = [float(x) for x in re.findall(r"silence_start: ([\d.]+)", p)]; en = [float(x) for x in re.findall(r"silence_end: ([\d.]+)", p)]
    mids = [a + (s + e) / 2 for s, e in zip(st, en)]
    return min(mids, key=lambda m: abs(m - t)) if mids else t
s = snap(start_min * 60) if start_min > 0 else 0.0
e = snap((start_min + dur_min) * 60)
wav = f"{H}/build_tmp/{wid}.wav"; flac = f"{H}/audio/{wid}.flac"
subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{s:.2f}", "-to", f"{e:.2f}", "-i", mp3, "-ac", "1", "-ar", "16000", wav], check=True)
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", wav, "-c:a", "flac", flac], check=True)
dur = e - s
tr = subprocess.run([VAUTA, "transcribe-file", wav, "--locale", LOCALE, "--show-text", "--i-understand"], capture_output=True, text=True)
segs = []
for line in tr.stderr.splitlines():
    m = re.match(r"\[((?:\d+:)?\d+:\d\d)\] ?(.*)", line)
    if m:
        parts = [int(x) for x in m.group(1).split(":")]
        t = sum(p * 60 ** i for i, p in enumerate(reversed(parts)))
        segs.append([t, m.group(2).strip()])
    elif segs and line.strip() and not line.startswith("WARNING"):
        segs[-1][1] += " " + line.strip()   # continuation (shouldn't happen)
summary = tr.stdout.strip()
subprocess.run([VAUTA, "diarize", wav, "--rttm", f"{H}/build_tmp/{wid}.rttm"], capture_output=True, text=True, check=True)
turns = []
for l in open(f"{H}/build_tmp/{wid}.rttm"):
    f = l.split(); turns.append((float(f[3]), float(f[3]) + float(f[4]), f[7]))
order = {}
def speaker(a, b):
    ov = {}
    for ts, te, sp in turns:
        o = min(b, te) - max(a, ts)
        if o > 0: ov[sp] = ov.get(sp, 0) + o
    if not ov: return None
    sp = max(ov, key=ov.get)
    order.setdefault(sp, len(order) + 1)
    return sp
ps = []
for i, (t, text) in enumerate(segs):
    nxt = segs[i + 1][0] if i + 1 < len(segs) else min(dur, t + 30)
    end = max(t + 1, min(nxt, t + 60))
    ps.append(dict(id=i + 1, start=float(t), end=float(end), spk=speaker(t, end), text=text))
for p in ps:
    p["speaker"] = f"Speaker {order[p.pop('spk')]}" if p["spk"] else "Speaker ?"
words = sum(len(p["text"].split()) for p in ps)
out = dict(meeting=wid, language="es", source_file=src, window_start_s=round(s, 1), window_end_s=round(e, 1), duration_min=round(dur / 60, 1),
           asr=f"Vauta transcribe-file --locale {LOCALE} (Apple on-device speech), diarization Vauta diarize (segment timing at 1 s resolution)",
           cli_summary=summary, words=words, speakers=len(order), passages=ps)
os.makedirs(f"{H}/data/es_real", exist_ok=True)
json.dump(out, open(f"{H}/data/es_real/{wid}.json", "w"), ensure_ascii=False)
os.remove(wav)
print(wid, f"{dur/60:.1f} min", len(ps), "segments", words, "words", len(order), "speakers", summary)
