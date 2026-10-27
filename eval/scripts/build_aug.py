# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Realistic-call augmentation of a subset of the clean sets -> $VAUTA_EVAL_WORK/sets/aug_calls (3 profiles x 8 files).

  python3 -I eval/scripts/build_aug.py

Chain per profile (seeded by file+profile): additive noise at a target SNR over reference speech (pink + brown rumble +
50/60 Hz hum + sparse keyboard-click bursts) -> AGC (20 ms level, 20 ms attack / 600 ms release, +-gain limits: breathing
that lifts the noise floor in pauses) -> optional narrowband (300-3400 Hz, 8 kHz, mu-law) -> codec (Opus voip, or none for
the PSTN profile) -> network impairments on 20 ms frames: Gilbert-Elliott packet loss with a crude concealment (repeat the last
good frame, decay x0.5 per lost frame) and jitter-buffer under-run gaps (muted 0.2-0.8 s).
Profiles: A wideband_voip (SNR 20 dB, 2% loss, 1 gap per ~120 s), B pstn_narrowband (SNR 12 dB, G.711-like, 4% loss),
C mobile_poor (SNR 8 dB, Opus 12 kbps, 8% bursty loss, 1 gap per ~45 s).
The reference RTTM is unchanged (time aligned). uem/ = original scored region; uem_nodrop/ = the same minus every muted
region (lost runs >= 60 ms and gaps, +-50 ms), i.e. the audible part. These are simulations, not recordings of real calls.
"""
import json, os, shutil, sys
import numpy as np
from scipy import signal
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C, hpins as P
from audiolib import *

SUBSET = [("ami_dev_others", "ES2011a_others"), ("ami_dev_others", "IS1008c_others"), ("ami_dev_others", "TS3004a_others"),
          ("es_conv", "es_conv04_vp_3spk"), ("es_conv", "es_conv06_vp_4spk"), ("es_conv", "es_conv07_mls_5spk"),
          ("voxconverse_heldout", None), ("voxconverse_heldout", None)]
PROFILES = {
    "A_wideband_voip": dict(snr=20, loss=0.02, burst=1.5, gap_every=120, agc_max=12, nb=False, codec=("24k", "48000")),
    "B_pstn_narrowband": dict(snr=12, loss=0.04, burst=2.0, gap_every=90, agc_max=18, nb=True, codec=None),
    "C_mobile_poor": dict(snr=8, loss=0.08, burst=4.0, gap_every=45, agc_max=24, nb=False, codec=("12k", "16000")),
}

def noise(n, rng):
    br = np.cumsum(rng.standard_normal(n)); br = signal.sosfilt(signal.butter(2, 120, "hp", fs=SR, output="sos"), br)
    x = pink(n, rng) + 0.5 * (br / (np.std(br) + 1e-9))
    t = np.arange(n) / SR; f0 = 50.0 if rng.random() < 0.5 else 60.0
    x += 0.15 * (np.sin(2 * np.pi * f0 * t) + 0.5 * np.sin(2 * np.pi * 2 * f0 * t))
    for k in range(int(n / SR / rng.uniform(2, 8))):
        s = int(rng.uniform(0, n - 2000)); L = int(rng.uniform(300, 900))
        x[s:s + L] += rng.standard_normal(L) * np.exp(-6 * np.arange(L) / L) * rng.uniform(1.5, 4.0)
    return (x / (np.std(x) + 1e-9)).astype(np.float32)

def agc(x, max_gain_db, target_db=-26.0):
    hop = int(0.02 * SR); n = len(x) // hop
    lvl = 20 * np.log10(np.sqrt(np.mean(x[:n * hop].reshape(n, hop) ** 2, axis=1)) + 1e-7)
    g = np.zeros(n); cur = 0.0
    a_att, a_rel = 1 - np.exp(-0.02 / 0.02), 1 - np.exp(-0.02 / 0.6)
    for i in range(n):
        want = float(np.clip(target_db - lvl[i], -12.0, max_gain_db))
        cur += (want - cur) * (a_att if want < cur else a_rel)
        g[i] = cur
    gs = np.interp(np.arange(len(x)), (np.arange(n) + 0.5) * hop, 10 ** (g / 20))
    return (x * gs).astype(np.float32)

def narrowband(x):
    x = bandpass(x, 300, 3400, 4)
    y = signal.resample_poly(x, 1, 2).astype(np.float32)
    mu = 255.0
    c = np.sign(y) * np.log1p(mu * np.abs(np.clip(y, -1, 1))) / np.log1p(mu)
    c = np.round(c * 127) / 127
    y = np.sign(c) * (np.expm1(np.abs(c) * np.log1p(mu)) / mu)
    return signal.resample_poly(y, 2, 1).astype(np.float32)

def network(x, prof, rng):
    """-> (impaired signal, muted intervals in seconds that last >= 60 ms)."""
    fr = int(0.02 * SR); n = len(x) // fr
    p_bad = prof["loss"]; p_bg = 1.0 / prof["burst"]; p_gb = p_bad * p_bg / max(1e-6, 1 - p_bad)
    lost, bad = np.zeros(n, bool), False
    for i in range(n):
        bad = (rng.random() >= p_bg) if bad else (rng.random() < p_gb)
        lost[i] = bad
    y = x.copy(); run = 0; muted = []
    for i in range(n):
        s = slice(i * fr, (i + 1) * fr)
        if lost[i]:
            run += 1
            y[s] = y[(i - 1) * fr:i * fr] * 0.5 if i > 0 else 0   # repeat the previous (already concealed) frame, decay
        else:
            if run >= 3: muted.append(((i - run) * 0.02, i * 0.02))
            run = 0
    if run >= 3: muted.append(((n - run) * 0.02, n * 0.02))
    nga = int(len(x) / SR / prof["gap_every"])
    for _ in range(nga):
        d = rng.uniform(0.2, 0.8); a = rng.uniform(5, len(x) / SR - 5)
        y[int(a * SR):int((a + d) * SR)] = 0; muted.append((a, a + d))
    return y, muted

def subtract(base, cut):
    out = []
    for a, b in base:
        cur = a
        for c, d in sorted(cut):
            if d <= cur or c >= b: continue
            if c > cur: out.append((cur, c))
            cur = max(cur, d)
        if cur < b: out.append((cur, b))
    return out

def main():
    for d in ("audio", "rttm", "uem", "uem_nodrop"): os.makedirs(f"{P.SETS}/aug_calls/{d}", exist_ok=True)
    tmp = f"{P.SETS}/_tmpaug"; os.makedirs(tmp, exist_ok=True)
    vox = sorted(os.listdir(f"{P.SETS}/voxconverse_heldout/audio"))
    # choose the vox files with 3 and 6 reference speakers (deterministic)
    import score_der as sd
    cand = {}
    for fn in vox:
        u = fn[:-4]; rows = sd.parse_rttm(f"{P.SETS}/voxconverse_heldout/rttm/{u}.rttm")[u]
        cand.setdefault(len({r[2] for r in rows}), u)
    picks = [cand[k] for k in (3, 6) if k in cand] or vox[:2]
    sub = [(s, u) for s, u in SUBSET if u]
    sub += [("voxconverse_heldout", u) for u in picks]
    info = {}
    for si, (sset, uri) in enumerate(sub):
        x, sr = C.read_wav(f"{P.SETS}/{sset}/audio/{uri}.wav"); assert sr == SR
        rows = sd.parse_rttm(f"{P.SETS}/{sset}/rttm/{uri}.rttm")[uri]
        uem = sd.parse_uem(f"{P.SETS}/{sset}/uem/{uri}.uem")[uri] if os.path.exists(f"{P.SETS}/{sset}/uem/{uri}.uem") else [(0.0, len(x) / SR)]
        for pi, (pname, prof) in enumerate(PROFILES.items()):
            rng = rng_for(f"{uri}|{pname}")
            sp = rms_active(x, [(s, s + d) for s, d, _ in rows])
            nz = noise(len(x), rng) * sp * 10 ** (-prof["snr"] / 20)
            y = agc(x + nz, prof["agc_max"])
            if prof["nb"]: y = narrowband(y)
            codec = "g711-like mu-law 8 kHz"
            if prof["codec"]: y, codec = opus_roundtrip(y, 0, f"{tmp}/{uri}_{pname}", *prof["codec"])
            y, muted = network(y[:len(x)], prof, rng)
            pk = np.abs(y).max()
            if pk > 0.95: y *= 0.95 / pk
            name = f"{uri}__{pname}"
            C.write_wav(f"{P.SETS}/aug_calls/audio/{name}.wav", y)
            write_rttm(f"{P.SETS}/aug_calls/rttm/{name}.rttm", name, rows)
            dur = len(y) / SR
            u0 = [(a, min(b, dur)) for a, b in uem]
            with open(f"{P.SETS}/aug_calls/uem/{name}.uem", "w") as f:
                for a, b in u0: f.write(f"{name} 1 {a:.3f} {b:.3f}\n")
            nod = subtract(u0, [(a - 0.05, b + 0.05) for a, b in muted])
            with open(f"{P.SETS}/aug_calls/uem_nodrop/{name}.uem", "w") as f:
                for a, b in nod: f.write(f"{name} 1 {a:.3f} {b:.3f}\n")
            info[name] = dict(source_set=sset, source=uri, profile=pname, snr_db=prof["snr"], codec=codec, loss_rate=prof["loss"],
                              muted_seconds=round(sum(b - a for a, b in muted), 1), scored_seconds_nodrop=round(sum(b - a for a, b in nod), 1), duration=round(dur, 1))
            C.log(name, info[name]["muted_seconds"], "s muted", codec)
    json.dump(info, open(f"{P.SETS}/aug_calls/info.json", "w"), indent=1)
    shutil.rmtree(tmp)

if __name__ == "__main__":
    main()
