# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Shared DSP helpers (numpy + scipy): VAD, filters, noise, Opus round trip, RTTM writing."""
import hashlib, os, subprocess
import numpy as np
from scipy import signal
import common as C
SR = C.SR

def rng_for(name):
    return np.random.default_rng(int(hashlib.sha256(name.encode()).hexdigest()[:12], 16))

def frame_db(x, win=400, hop=160):
    n = 1 + max(0, (len(x) - win) // hop)
    idx = np.arange(win)[None, :] + hop * np.arange(n)[:, None]
    r = np.sqrt(np.mean(x[idx] ** 2, axis=1) + 1e-12)
    return 20 * np.log10(r)

def vad_runs(x, min_gap=0.1, min_len=0.12):
    """Energy VAD on a clean read/parliament signal -> [(start_s, end_s)]; threshold = p95 level - 32 dB (floor -62 dBFS)."""
    db = frame_db(x)
    thr = max(np.percentile(db, 95) - 32.0, -62.0)
    on = db > thr
    runs, i, n = [], 0, len(on)
    while i < n:
        if on[i]:
            j = i
            while j < n and on[j]: j += 1
            runs.append([i * 0.01, j * 0.01 + 0.015]); i = j
        else: i += 1
    merged = []
    for a, b in runs:
        if merged and a - merged[-1][1] < min_gap: merged[-1][1] = b
        else: merged.append([a, b])
    return [(a, b) for a, b in merged if b - a >= min_len]

def chunks_from(x, gap=0.35, max_len=11.0, min_len=0.5):
    """Split an utterance at pauses >= gap (and the longest inner pause when a chunk is longer than max_len)."""
    runs = vad_runs(x)
    if not runs: return []
    groups, cur = [], [runs[0]]
    for r in runs[1:]:
        if r[0] - cur[-1][1] >= gap: groups.append(cur); cur = [r]
        else: cur.append(r)
    groups.append(cur)
    out = []
    def split(g):
        if g[-1][1] - g[0][0] > max_len and len(g) > 1:
            k = max(range(1, len(g)), key=lambda i: g[i][0] - g[i - 1][1])
            split(g[:k]); split(g[k:])
        else: out.append((g[0][0], g[-1][1]))
    for g in groups: split(g)
    return [(a, b) for a, b in out if b - a >= min_len]

def pink(n, rng):
    w = rng.standard_normal(n)
    f = np.fft.rfft(w); k = np.arange(len(f)); k[0] = 1
    p = np.fft.irfft(f / np.sqrt(k), n)
    return (p / (np.std(p) + 1e-9)).astype(np.float32)

def rms_active(x, intervals=None):
    if intervals is None: return float(np.sqrt(np.mean(x ** 2) + 1e-12))
    m = np.zeros(len(x), bool)
    for a, b in intervals: m[int(a * SR):int(b * SR)] = True
    return float(np.sqrt(np.mean(x[m] ** 2) + 1e-12)) if m.any() else float(np.sqrt(np.mean(x ** 2) + 1e-12))

def bandpass(x, lo, hi, order=2):
    sos = signal.butter(order, [lo, hi], btype="band", fs=SR, output="sos")
    return signal.sosfilt(sos, x).astype(np.float32)

def opus_roundtrip(x, idx, tmp, bitrate=None, internal=None):
    """Same codec simulation as the repo harness: libopus voip VBR; even idx 24k/48 kHz internal, odd 16k/16 kHz."""
    br, ar = ("24k", "48000") if idx % 2 == 0 else ("16k", "16000")
    if bitrate: br = bitrate
    if internal: ar = internal
    w, o, b = tmp + ".wav", tmp + ".opus", tmp + ".dec.wav"
    C.write_wav(w, x)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", w, "-ac", "1", "-ar", ar, "-c:a", "libopus", "-b:a", br,
                    "-application", "voip", "-vbr", "on", o], check=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", o, "-ac", "1", "-ar", str(SR), b], check=True)
    y, sr = C.read_wav(b)
    for f in (w, o, b): os.remove(f)
    return y, f"opus {br} internal-rate {int(ar) // 1000}k"

def write_rttm(path, uri, rows):
    with open(path, "w") as f:
        for s, d, spk in sorted(rows):
            f.write(f"SPEAKER {uri} 1 {s:.3f} {d:.3f} <NA> <NA> {spk} <NA> <NA>\n")

def overlap_fraction(rows, dur):
    n = int(dur * 100) + 1
    cnt = np.zeros(n, np.int16)
    for s, d, _ in rows: cnt[int(s * 100):int((s + d) * 100)] += 1
    sp = (cnt >= 1).sum()
    return float((cnt >= 2).sum() / sp) if sp else 0.0
