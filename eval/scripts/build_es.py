# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Build the Spanish sets from the verified MLS (CC BY 4.0) and VoxPopuli (CC0) downloads. Deterministic (seeded by name).

  python3 -I eval/scripts/build_es.py

$VAUTA_EVAL_WORK/sets/es_wer/audio/*.wav, ref/*.txt, info.json     ~35 min of read/parliament Spanish with exact transcripts
$VAUTA_EVAL_WORK/sets/es_conv/audio/*.wav, rttm/, uem/, info.json  12 synthetic multi-speaker conversations (2-6 speakers), exact RTTM
Conversation model: speakers' utterances are cut at pauses (energy VAD) into chunks; turns of 1-4 chunks, Markov speaker
change, inter-turn gaps (log-normal ~0.45 s; 35% overlaps of 0.4-2.5 s; 6% long pauses), 35% turns get a short interjection
from another speaker overlapped inside the turn. Each speaker track gets its own level (-8..+3 dB), band-limiting, a noise
floor and (50%) a small synthetic room, the tracks are summed and coded with Opus as in the repo harness. RTTM = the VAD speech
interval of every placed chunk (pauses < 0.35 s inside a chunk count as speech), so it is exact for this construction.
"""
import io, json, os, sys, tarfile
import numpy as np
import soundfile as sf
import pyarrow.parquet as pq
from scipy import signal
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C, hpins as P
from audiolib import *

MLS_DIR = f"{P.SRC}/mls/data/mls_spanish"
VP = f"{P.SRC}/voxpopuli/es/test-00000-of-00001.parquet"
OUT = P.SETS
def mk(*p):
    d = os.path.join(OUT, *p); os.makedirs(d, exist_ok=True); return d

# ---------------------------------------------------------------- loading
def load_mls(rng):
    """-> pool {spk: [(utt_id, float32 audio, text)]} with up to 40 random utterances per speaker; meta gender."""
    gender = {}
    for l in open(f"{MLS_DIR}/metainfo.txt").read().splitlines()[1:]:
        x = [t.strip() for t in l.split("|")]
        if len(x) >= 3: gender[x[0]] = {"M": "male", "F": "female"}.get(x[1], x[1])
    texts = {}
    for s in ("dev", "test"):
        for l in open(f"{MLS_DIR}/{s}/transcripts.txt"):
            k, t = l.rstrip("\n").split("\t"); texts[k] = t
    pool = {}
    for split, tars in P.MLS_TARS.items():
        for t in tars:
            spk = t.split("_")[0]
            with tarfile.open(f"{MLS_DIR}/{split}/audio/{t}.tar.gz") as tf:
                names = sorted(m.name for m in tf.getmembers() if m.isfile() and m.name.endswith(".flac") and m.name == os.path.basename(m.name))
                pick = sorted(rng.choice(len(names), size=min(40, len(names)), replace=False))
                for i in pick:
                    n = names[i]; d, sr = sf.read(io.BytesIO(tf.extractfile(n).read()), dtype="float32")
                    assert sr == SR and d.ndim == 1, (n, sr, d.shape)
                    uid = os.path.basename(n)[:-5]
                    pool.setdefault(spk, []).append((uid, d, texts[uid]))
    return pool, gender

def load_vp(rng):
    """-> pool {spk: [(audio_id, audio, text)]} gold transcripts, speakers with >= 12 utterances (<= 30 kept), gender."""
    f = pq.ParquetFile(VP)
    meta = f.read(columns=["audio_id", "speaker_id", "normalized_text", "gender", "is_gold_transcript"]).to_pylist()
    by = {}
    for i, r in enumerate(meta):
        if r["is_gold_transcript"]: by.setdefault(r["speaker_id"], []).append(i)
    keep = {}
    for spk in sorted(by):
        if len(by[spk]) >= 12:
            keep[spk] = sorted(rng.choice(by[spk], size=min(30, len(by[spk])), replace=False))
    # extra random gold utterances (any speaker) for the WER set
    allowed = {i for v in keep.values() for i in v}
    others = [i for i, r in enumerate(meta) if r["is_gold_transcript"] and i not in allowed]
    wer_ids = set(rng.choice(others, size=min(120, len(others)), replace=False).tolist())
    want = allowed | wer_ids
    audio = {}
    row = 0
    for g in range(f.metadata.num_row_groups):
        n = f.metadata.row_group(g).num_rows
        rows = [i for i in range(row, row + n) if i in want]
        if rows:
            col = f.read_row_group(g, columns=["audio"]).column("audio").to_pylist()
            for i in rows:
                d, sr = sf.read(io.BytesIO(col[i - row]["bytes"]), dtype="float32"); assert sr == SR and d.ndim == 1
                audio[i] = d
        row += n
    pool = {spk: [(meta[i]["audio_id"], audio[i], meta[i]["normalized_text"]) for i in idx] for spk, idx in keep.items()}
    gender = {spk: meta[idx[0]]["gender"] for spk, idx in keep.items()}
    wer = [(meta[i]["audio_id"], audio[i], meta[i]["normalized_text"], meta[i]["speaker_id"]) for i in sorted(wer_ids)]
    return pool, gender, wer

# ---------------------------------------------------------------- WER set
def build_wer(vp_wer, mls_pool):
    ad, rd = mk("es_wer", "audio"), mk("es_wer", "ref")
    info = {}
    rng = rng_for("es_wer")
    files = []
    mls_utts = [(uid, d, t, spk) for spk, v in mls_pool.items() for uid, d, t in v]
    order = rng.permutation(len(mls_utts)); mls_utts = [mls_utts[i] for i in order]
    for src, utts, prefix in (("voxpopuli", vp_wer, "es_vp_wer"), ("mls", mls_utts, "es_mls_wer")):
        nfile = 4 if src == "voxpopuli" else 3
        cur, k, dur = [], 1, 0.0
        for u in utts:
            cur.append(u); dur += len(u[1]) / SR + 0.5
            if dur >= 300:
                files.append((f"{prefix}{k}", src, cur)); cur, k, dur = [], k + 1, 0.0
                if k > nfile: break
    for name, src, utts in files:
        parts, text = [], []
        for uid, d, t, spk in utts:
            parts += [d, np.zeros(int(0.5 * SR), np.float32)]; text.append(t)
        x = np.concatenate(parts)
        C.write_wav(f"{ad}/{name}.wav", x)
        open(f"{rd}/{name}.txt", "w").write(" ".join(text) + "\n")
        info[name] = dict(source=src, seconds=round(len(x) / SR, 1), utterances=[u[0] for u in utts],
                          speakers=sorted({u[3] for u in utts}), licence="CC0-1.0" if src == "voxpopuli" else "CC-BY-4.0")
    json.dump(info, open(f"{OUT}/es_wer/info.json", "w"), indent=1)
    C.log("es_wer:", {k: v["seconds"] for k, v in info.items()}, "total min", sum(v["seconds"] for v in info.values()) / 60)

# ---------------------------------------------------------------- conversations
def chunk_bank(utts):
    """[(audio_with_pad, speech_start_in_chunk, speech_dur)] from a speaker's utterances."""
    bank = []
    pad = int(0.06 * SR)
    for uid, d, _ in utts:
        for a, b in chunks_from(d):
            s0, s1 = max(0, int(a * SR) - pad), min(len(d), int(b * SR) + pad)
            seg = d[s0:s1].copy()
            fade = int(0.01 * SR); seg[:fade] *= np.linspace(0, 1, fade); seg[-fade:] *= np.linspace(1, 0, fade)
            bank.append((seg, a - s0 / SR, b - a))
    return bank

def room(rng):
    rt60 = rng.uniform(0.15, 0.45); n = int(rt60 * SR)
    ir = rng.standard_normal(n) * np.exp(-6.9 * np.arange(n) / n)
    ir[0] = 4.0 * np.max(np.abs(ir[1:]))
    return (ir / np.sqrt(np.sum(ir ** 2))).astype(np.float32), rt60

def make_conv(cid, idx, nspk, source, pool, gender, target, tmpdir):
    rng = rng_for(cid)
    spks = sorted(pool)
    # mix genders when possible
    f = [s for s in spks if gender[s] == "female"]; m = [s for s in spks if gender[s] == "male"]
    chosen = []
    for i in range(nspk):
        grp = (f if i % 2 == 0 else m) or spks
        cand = [s for s in grp if s not in chosen] or [s for s in spks if s not in chosen]
        chosen.append(cand[int(rng.integers(len(cand)))])
    banks = {s: chunk_bank(pool[s]) for s in chosen}
    ptr = {s: list(rng.permutation(len(banks[s]))) for s in chosen}
    def take(s, short=False):
        for _ in range(len(banks[s]) * 2):
            if not ptr[s]: ptr[s] = list(rng.permutation(len(banks[s])))
            i = ptr[s].pop(); seg, a, d = banks[s][i]
            if (short and d < 1.8) or (not short and d >= 0.8): return seg, a, d
        return banks[s][0]
    w = rng.dirichlet(np.ones(nspk) * 1.3); w = np.maximum(w, 0.08); w /= w.sum()
    T = target + 5
    tracks = {s: np.zeros(int(T * SR), np.float32) for s in chosen}
    rows, cursor, cur = [], 0.5, int(rng.choice(nspk, p=w))
    def place(s, seg, a, d, at):
        st = int(at * SR)
        if st < 0 or st + len(seg) > len(tracks[s]): return False
        tracks[s][st:st + len(seg)] += seg
        rows.append((at + a, d, s)); return True
    while cursor < target:
        s = chosen[cur]; k = int(rng.choice([1, 2, 3, 4], p=[.35, .3, .2, .15]))
        t0, last_end, lastdur = cursor, cursor, 1.0
        for j in range(k):
            seg, a, d = take(s)
            if not place(s, seg, a, d, cursor): break
            last_end = cursor + a + d; lastdur = d
            cursor = cursor + len(seg) / SR + float(rng.uniform(0.12, 0.6))
        if nspk > 1 and rng.random() < 0.35 and last_end - t0 > 3.0:
            o = chosen[int(rng.choice([i for i in range(nspk) if i != cur]))]
            seg, a, d = take(o, short=True)
            if last_end - d - 0.2 > t0 + 1.0: place(o, seg, a, d, float(rng.uniform(t0 + 1.0, last_end - d - 0.2)) - a)
        pw = np.array([w[i] for i in range(nspk) if i != cur]); pw /= pw.sum()
        nxt = int(rng.choice([i for i in range(nspk) if i != cur], p=pw)) if nspk > 1 else cur
        u = rng.random()
        if u < 0.35: gap = -float(rng.uniform(0.4, min(2.5, max(0.5, 0.8 * lastdur))))
        elif u < 0.41: gap = float(rng.uniform(1.5, 4.0))
        else: gap = float(np.clip(rng.lognormal(np.log(0.45), 0.5), 0.1, 1.6))
        cursor = last_end + gap; cur = nxt
    dur = max(r[0] + r[1] for r in rows) + 0.7
    n = int(dur * SR)
    mix = np.zeros(n, np.float32); prof = {}
    for s in chosen:
        x = np.pad(tracks[s][:n], (0, max(0, n - len(tracks[s]))))
        sp = [(a, a + d) for a, d, ss in rows if ss == s]
        x = x * (0.05 * 10 ** (rng.uniform(-8, 3) / 20) / rms_active(x, sp))
        lo, hi = float(rng.uniform(70, 180)), float(rng.uniform(5500, 7600))
        x = bandpass(x, lo, hi)
        rr = None
        if rng.random() < 0.5:
            ir, rr = room(rng); x = signal.fftconvolve(x, ir)[:n].astype(np.float32)
        nl = float(rng.uniform(-52, -40))
        x = x + pink(n, rng) * 10 ** (nl / 20)
        mix += x; prof[s] = dict(gender=gender[s], hp_hz=round(lo), lp_hz=round(hi), room_rt60=None if rr is None else round(rr, 2), noise_dbfs=round(nl, 1))
    pk = np.abs(mix).max()
    if pk > 0.9: mix *= 0.9 / pk
    mix, codec = opus_roundtrip(mix, idx, os.path.join(tmpdir, cid))
    mix = mix[:n] if len(mix) >= n else np.pad(mix, (0, n - len(mix)))
    names = {s: f"{source}_{s}" for s in chosen}
    rows = [(a, d, names[s]) for a, d, s in rows if a < dur]
    rows = [(a, min(d, dur - a), s) for a, d, s in rows]
    C.write_wav(f"{OUT}/es_conv/audio/{cid}.wav", mix)
    write_rttm(f"{OUT}/es_conv/rttm/{cid}.rttm", cid, rows)
    open(f"{OUT}/es_conv/uem/{cid}.uem", "w").write(f"{cid} 1 0.000 {len(mix) / SR:.3f}\n")
    return dict(source=source, n_speakers=nspk, duration=round(len(mix) / SR, 1), codec=codec, overlap_frac_of_speech=round(overlap_fraction(rows, len(mix) / SR), 3),
                speech_frac=None, speakers={names[s]: prof[s] for s in chosen}, licence="CC-BY-4.0" if source == "mls" else "CC0-1.0")

def main():
    for d in ("audio", "rttm", "uem"): mk("es_conv", d)
    tmp = mk("_tmp")
    C.log("loading MLS ..."); mls_pool, mls_gender = load_mls(rng_for("mls_pool"))
    C.log("loading VoxPopuli ..."); vp_pool, vp_gender, vp_wer = load_vp(rng_for("vp_pool"))
    C.log("MLS speakers", len(mls_pool), "VP speakers", len(vp_pool), "VP wer utts", len(vp_wer))
    build_wer(vp_wer, mls_pool)
    plan = [("mls", 2, 540), ("vp", 2, 540), ("mls", 3, 600), ("vp", 3, 600), ("mls", 4, 660), ("vp", 4, 660),
            ("mls", 5, 660), ("vp", 5, 660), ("mls", 6, 720), ("vp", 6, 720), ("mls", 3, 900), ("vp", 4, 900)]
    info = {}
    for i, (src, n, target) in enumerate(plan):
        cid = f"es_conv{i + 1:02d}_{src}_{n}spk"
        pool, gender = (mls_pool, mls_gender) if src == "mls" else (vp_pool, vp_gender)
        info[cid] = make_conv(cid, i, n, src, pool, gender, target, tmp)
        C.log(cid, info[cid]["duration"], "s overlap", info[cid]["overlap_frac_of_speech"], info[cid]["codec"])
    json.dump(info, open(f"{OUT}/es_conv/info.json", "w"), indent=1)
    os.rmdir(tmp)

if __name__ == "__main__":
    main()
