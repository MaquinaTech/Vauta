#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""
Writes the small test fixtures of Tests/VautaCoreTests/DiarizationTests (about 0.7 MB). DEV TOOL ONLY.

The references come from independent code, never from the Core ML models under test:
  * fbank       tools/convert-diarization-models/reference_fbank.py (NumPy; checked against torchaudio.kaldi)
  * segmentation  pyannote.audio's own PyanNet class loaded with the community-1 checkpoint (FP32, PyTorch)
  * embedding   pyannote.audio's own WeSpeakerResNet34 with the pinned WeSpeaker checkpoint (FP32, PyTorch)
  * AHC         scipy.cluster.hierarchy.linkage(method="centroid") + fcluster(criterion="distance")

Needs pyannote.audio (4.0.7), torch, numpy, and scipy in a SEPARATE venv from convert.py's
(`pip install pyannote.audio==4.0.7`); run it with `python -I`. Both checkpoints are verified against the
hashes pinned in convert.py first. The audio is a 12 s excerpt of an AMI Meeting Corpus recording (CC BY 4.0, see
NOTICE); it is stored as 16-bit PCM and every reference is computed from exactly those quantised samples.

  python -I export_fixtures.py --audio ES2004a_others.wav --start 240 \
      --seg-checkpoint .../segmentation/pytorch_model.bin --embedding-checkpoint src_wespeaker/pytorch_model.bin
"""
import argparse, json, sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from reference_fbank import fbank  # noqa: E402
from safe_load import load_checkpoint  # noqa: E402

DEFAULT_OUT = HERE.parent.parent / "Tests" / "VautaCoreTests" / "Fixtures" / "Diarization"
SR, WIN, FRAMES, STEP_S = 16000, 160000, 589, 270 / 16000
WINDOW_STARTS_S = (0.0, 1.0, 2.0)          # three overlapping windows of a 12 s clip
CLIP_SECONDS = 12
MIN_EMBED_SECONDS = 1.0
MASK = [0b000, 0b001, 0b010, 0b100, 0b011, 0b101, 0b110]


def read_pcm16(path, start_s, seconds):
    """Samples [start, start+seconds) of a 16-bit mono PCM WAV as float32 in [-1, 1) (standard library only)."""
    import wave
    with wave.open(str(path), "rb") as w:
        assert w.getsampwidth() == 2 and w.getnchannels() == 1 and w.getframerate() == SR, "need 16 kHz mono 16-bit PCM"
        w.setpos(int(start_s * SR))
        raw = w.readframes(int(seconds * SR))
    return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0


def sha256(p):
    import hashlib
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def check_pinned():
    import convert  # needs torch and coremltools importable; only the pinned constants are used
    return convert.SEG_SHA256, convert.WESPEAKER_FILES["pytorch_model.bin"]


def load_segmentation(path):
    import torch
    from pyannote.audio.models.segmentation import PyanNet
    from pyannote.audio.core.task import Specifications, Problem, Resolution
    ck = load_checkpoint(str(path))
    m = PyanNet(sincnet={"stride": 10}, lstm={"hidden_size": 128, "num_layers": 4, "bidirectional": True, "monolithic": True, "dropout": 0.5},
                linear={"hidden_size": 128, "num_layers": 2})
    m.specifications = Specifications(problem=Problem.MONO_LABEL_CLASSIFICATION, resolution=Resolution.FRAME, duration=10.0,
                                      classes=["speaker#1", "speaker#2", "speaker#3"], powerset_max_classes=2, permutation_invariant=True)
    m.build()
    m.load_state_dict(ck["state_dict"], strict=True)
    return m.eval()


def load_embedding(path):
    from pyannote.audio.models.embedding.wespeaker import WeSpeakerResNet34
    m = WeSpeakerResNet34()
    m.load_state_dict(load_checkpoint(str(path))["state_dict"], strict=True)
    return m.eval()


def masks_from_classes(classes):
    """Same rule as MaskBuilder in Swift: frames where the speaker is alone, else all their frames if too short."""
    active = np.zeros((3, FRAMES), np.float32)
    alone = np.zeros((3, FRAMES), np.float32)
    for t, c in enumerate(classes):
        bits = MASK[c]
        for s in range(3):
            if bits & (1 << s):
                active[s, t] = 1
                if bin(bits).count("1") == 1:
                    alone[s, t] = 1
    masks, seconds = [], []
    for s in range(3):
        if alone[s].sum() * STEP_S >= MIN_EMBED_SECONDS:
            masks.append(alone[s]); seconds.append(float(alone[s].sum() * STEP_S))
        else:
            masks.append(active[s]); seconds.append(float(active[s].sum() * STEP_S))
    return np.stack(masks), seconds


def windows_of(clip_i16):
    x = clip_i16.astype(np.float32) / 32768.0
    return [x[int(s * SR): int(s * SR) + WIN] for s in WINDOW_STARTS_S]


def references(clip_i16, seg_ckpt, emb_ckpt):
    import torch
    seg, emb = load_segmentation(seg_ckpt), load_embedding(emb_ckpt)
    out = []
    with torch.no_grad():
        for start, w in zip(WINDOW_STARTS_S, windows_of(clip_i16)):
            wav = torch.from_numpy(w)[None, None, :]
            logp = seg(wav)[0].numpy()
            classes = logp.argmax(-1)
            masks, seconds = masks_from_classes(classes)
            e = emb(wav, weights=torch.from_numpy(masks)[None])[0].numpy()
            out.append({"start_s": start, "classes": [int(c) for c in classes], "usable_seconds": seconds,
                        "embeddings": [e[s].tolist() if seconds[s] >= MIN_EMBED_SECONDS else None for s in range(3)]})
    return out


def ahc_fixture(out_dir):
    """Synthetic L2-normalised 'embeddings' with realistic spread (same-speaker cosine about 0.7) so that the cut
    height matters; labels from scipy at several cut heights. Heights too close to a cut are rejected, since a
    float32 vs float64 difference could legitimately flip such a merge."""
    from scipy.cluster.hierarchy import linkage, fcluster
    rng = np.random.default_rng(20261011)
    d, sizes = 256, [40, 32, 24, 16, 10, 6]
    base = rng.standard_normal((len(sizes), d))
    base[1] = 0.55 * base[0] + 0.83 * base[1]          # two speakers with similar voices
    base[4] = 0.40 * base[2] + 0.92 * base[4]
    base /= np.linalg.norm(base, axis=1, keepdims=True)
    pts = np.concatenate([base[i] + 0.03 * rng.standard_normal((n, d)) for i, n in enumerate(sizes)])
    pts /= np.linalg.norm(pts, axis=1, keepdims=True)
    order = rng.permutation(len(pts))
    pts = pts[order].astype(np.float32)
    z = linkage(pts.astype(np.float64), method="centroid", metric="euclidean")
    cuts = [0.5, 0.7, 0.9, 1.0, 1.1, 1.25]
    for c in cuts:
        gap = np.abs(z[:, 2] - c).min()
        assert gap > 2e-3, f"a merge height is within {gap} of the cut {c}: change the seed"
    labels = {str(c): [int(v) for v in fcluster(z, c, criterion="distance")] for c in cuts}
    pts.tofile(out_dir / "ahc_vectors.f32")
    (out_dir / "ahc_labels.json").write_text(json.dumps({"dimension": d, "count": len(pts), "labels": labels,
                                                         "generator": "export_fixtures.py ahc_fixture, seed 20261011"}))
    print("ahc clusters per cut", {c: len(set(v)) for c, v in labels.items()})


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--audio", required=True, help="16 kHz mono WAV (AMI excerpt source)")
    ap.add_argument("--start", type=float, required=True, help="start of the 12 s excerpt, seconds")
    ap.add_argument("--seg-checkpoint", required=True)
    ap.add_argument("--embedding-checkpoint", required=True)
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT))
    a = ap.parse_args()
    seg_hash, emb_hash = check_pinned()
    for p, want in ((a.seg_checkpoint, seg_hash), (a.embedding_checkpoint, emb_hash)):
        if sha256(p) != want:
            raise SystemExit(f"{p}: SHA-256 differs from the pinned one")
    out = Path(a.out_dir); out.mkdir(parents=True, exist_ok=True)
    audio = read_pcm16(a.audio, a.start, CLIP_SECONDS)
    assert len(audio) == CLIP_SECONDS * SR
    clip = np.clip(np.round(audio * 32768.0), -32768, 32767).astype("<i2")
    clip.tofile(out / "clip.i16")
    fb = fbank(clip[:WIN].astype(np.float32) / 32768.0)
    assert np.abs(fb).max() < 32.0
    np.round(fb * 1000.0).astype("<i2").tofile(out / "fbank0.i16")
    refs = references(clip, a.seg_checkpoint, a.embedding_checkpoint)
    (out / "reference.json").write_text(json.dumps({
        "source": f"AMI Meeting Corpus (CC BY 4.0), {Path(a.audio).name}, {CLIP_SECONDS} s from {a.start} s, 16-bit PCM",
        "fbank": {"file": "fbank0.i16", "scale": 1000.0, "frames": int(fb.shape[0]), "bins": int(fb.shape[1]), "window_start_s": 0.0},
        "windows": refs}))
    ahc_fixture(out)
    for p in sorted(out.iterdir()):
        print(f"{p.name:22s} {p.stat().st_size:8d} bytes")


if __name__ == "__main__":
    main()
