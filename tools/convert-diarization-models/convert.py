#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""
Reproducible Core ML conversion of the two speaker-diarization models Vauta bundles. DEV TOOL ONLY: it is
never part of the app and the app never runs it.

  embedding     WeSpeaker ResNet34-LM (VoxCeleb) from pyannote/wespeaker-voxceleb-resnet34-LM, CC-BY-4.0.
  segmentation  pyannote community-1 powerset segmentation, CC-BY-4.0. GATED on Hugging Face: the owner accepts
                the conditions with their own account and passes the downloaded checkpoint with --checkpoint.
                This script never downloads it and never uses a token.

Both checkpoints are verified against the SHA-256 pinned below BEFORE they are read; there is no flag to skip or
override the check. Checkpoints are read with safe_load.py (allow-listed unpickler: nothing is executed). Only
torch + coremltools + numpy are needed. The result is FP16, fixed 10 s windows, compiled to .mlmodelc, and its
metadata names the source repo, revision, checkpoint hash, licence and the modifications. The weights checkpoints
are never written anywhere by this script.

Run `python -I convert.py --help`; the exact steps are in README.md.
"""
import argparse, hashlib, shutil, sys, tempfile, urllib.request
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from safe_load import load_checkpoint  # noqa: E402

# ---------------------------------------------------------------------------------------------
# Pinned sources (the SHA-256 values are MANDATORY: a different file is refused)
# ---------------------------------------------------------------------------------------------
SEG_REPO = "pyannote/speaker-diarization-community-1"
SEG_REV = "3533c8cf8e369892e6b79ff1bf80f7b0286a54ee"
SEG_FILE = "segmentation/pytorch_model.bin"
SEG_SHA256 = "7ad24338d844fb95985486eb1a464e32d229f6d7a03c9abe60f978bacf3f816e"

WESPEAKER_REPO = "pyannote/wespeaker-voxceleb-resnet34-LM"
WESPEAKER_REV = "837717ddb9ff5507820346191109dc79c958d614"
WESPEAKER_FILES = {  # file -> sha256 (recorded 2026-10-09 from the pinned revision)
    "pytorch_model.bin": "366edf44f4c80889a3eb7a9d7bdf02c4aede3127f7dd15e274dcdb826b143c56",
    "config.yaml": "6ff718cff3c5d7a4493537ab7f4780cad7e3d32453f59099b4076aefa07a9974",
    "README.md": "ffc47d6f225a9341771a8304c0b8a354f706184956737661cb2c695e310551e3",
}

LICENSE = "CC-BY-4.0"
LICENSE_URL = "https://creativecommons.org/licenses/by/4.0/"
MODIFICATION = "Converted to Core ML; no changes to weights other than FP16 conversion."
SEG_NAME = "Segmentation_community1_fp16.mlmodelc"
EMB_NAME = "WeSpeakerResNet34LM_fp16.mlmodelc"
DEFAULT_OUT = HERE.parent.parent / "Sources" / "VautaCore" / "Resources" / "Models"

# Geometry shared with the Swift pipeline (10 s windows at 16 kHz)
SR = 16000
WIN = 160000                 # samples in a window
FBANK_FRAMES = 998           # 1 + (160000 - 400) // 160  (kaldi snip_edges=True)
SEG_FRAMES = 589             # segmentation output frames per window
EMB_FRAMES = 125             # ResNet34 time downsampling /8: 998 -> 499 -> 250 -> 125
MAX_SPK = 3                  # local speakers per window (powerset: up to 2 simultaneous)
EPS = 1e-6                   # replaces pyannote's 1e-8 (would underflow to 0 in FP16)


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def tree_hash(root: Path) -> str:
    """SHA-256 over every file of a model folder: for each regular file in path order, "<relative path>\n<file sha256>\n".
    The Swift side (DiarizationModels.treeHash) computes exactly this; symlinks and special files are refused."""
    entries = []
    for p in sorted(root.rglob("*"), key=lambda q: q.relative_to(root).as_posix().encode()):
        if p.is_symlink() or not (p.is_file() or p.is_dir()):
            raise SystemExit(f"{p}: only regular files and folders are allowed in a model")
        if p.is_file():
            entries.append(f"{p.relative_to(root).as_posix()}\n{sha256(p)}\n")
    return hashlib.sha256("".join(entries).encode()).hexdigest()


def verified(path: Path, want: str) -> Path:
    got = sha256(path)
    if got != want:
        raise SystemExit(f"SHA-256 mismatch for {path.name}: {got} != pinned {want}. Refusing to convert.")
    return path


def fetch_wespeaker(dest: Path, download: bool) -> Path:
    dest.mkdir(parents=True, exist_ok=True)
    for name, want in WESPEAKER_FILES.items():
        p = dest / name
        if not p.exists():
            if not download:
                raise SystemExit(f"{p} is missing. Put the pinned files there, or pass --download to fetch them "
                                 f"from huggingface.co/{WESPEAKER_REPO} @ {WESPEAKER_REV} (public, no token).")
            url = f"https://huggingface.co/{WESPEAKER_REPO}/resolve/{WESPEAKER_REV}/{name}"
            print("download", url)
            req = urllib.request.Request(url)  # no Authorization header, ever
            with urllib.request.urlopen(req) as r, open(p, "wb") as f:
                f.write(r.read())
        verified(p, want)
    return dest / "pytorch_model.bin"


# ---------------------------------------------------------------------------------------------
# Embedding: WeSpeaker ResNet34 (m_channels=32, feat_dim=80, embed_dim=256, TSTP pooling)
# Parameter names match the checkpoint (resnet.*) so the state dict loads strictly.
# ---------------------------------------------------------------------------------------------
class BasicBlock(nn.Module):
    def __init__(self, cin, c, stride):
        super().__init__()
        self.conv1 = nn.Conv2d(cin, c, 3, stride, 1, bias=False)
        self.bn1 = nn.BatchNorm2d(c)
        self.conv2 = nn.Conv2d(c, c, 3, 1, 1, bias=False)
        self.bn2 = nn.BatchNorm2d(c)
        self.shortcut = nn.Sequential()
        if stride != 1 or cin != c:
            self.shortcut = nn.Sequential(nn.Conv2d(cin, c, 1, stride, bias=False), nn.BatchNorm2d(c))

    def forward(self, x):
        o = F.relu(self.bn1(self.conv1(x)))
        o = self.bn2(self.conv2(o))
        return F.relu(o + self.shortcut(x))


class ResNet34(nn.Module):
    def __init__(self, m=32, feat_dim=80, embed_dim=256, blocks=(3, 4, 6, 3)):
        super().__init__()
        self.conv1 = nn.Conv2d(1, m, 3, 1, 1, bias=False)
        self.bn1 = nn.BatchNorm2d(m)
        cin = m
        layers = []
        for i, (n, stride) in enumerate(zip(blocks, (1, 2, 2, 2))):
            c = m * 2 ** i
            layers.append(nn.Sequential(*[BasicBlock(cin if j == 0 else c, c, stride if j == 0 else 1) for j in range(n)]))
            cin = c
        self.layer1, self.layer2, self.layer3, self.layer4 = layers
        self.seg_1 = nn.Linear(2 * (feat_dim // 8) * m * 8, embed_dim)

    def frames(self, x):  # (B,1,F,T) -> (B,256,F/8,T/8)
        x = F.relu(self.bn1(self.conv1(x)))
        return self.layer4(self.layer3(self.layer2(self.layer1(x))))


class EmbeddingGraph(nn.Module):
    """fbank (1,998,80) + masks (S,589) -> embeddings (S,256).

    * per-window mean normalisation of the fbank over time (what pyannote does) is inside;
    * the ResNet trunk runs once for the window, only the (cheap) masked statistics pooling
      is done per local speaker;
    * masks (589 segmentation frames) are resampled to the 125 trunk frames with the same
      'nearest' rule as torch.nn.functional.interpolate (src = floor(dst * 589 / 125)), baked
      as a constant 0/1 matrix.
    """

    def __init__(self, state_dict):
        super().__init__()
        self.resnet = ResNet34()
        sd = {k[len("resnet."):]: v for k, v in state_dict.items() if k.startswith("resnet.")}
        self.resnet.load_state_dict(sd, strict=True)
        r = torch.zeros(SEG_FRAMES, EMB_FRAMES)
        for d in range(EMB_FRAMES):
            r[int(np.floor(d * SEG_FRAMES / EMB_FRAMES)), d] = 1.0
        self.register_buffer("resample", r)

    def forward(self, fbank, masks):
        x = fbank - fbank.mean(dim=1, keepdim=True)
        x = x.transpose(1, 2).unsqueeze(1)                       # (1,1,80,T)
        x = self.resnet.frames(x)                                # (1,256,10,125)
        x = x.reshape(1, -1, EMB_FRAMES)                         # (1,2560,125)
        w = (masks @ self.resample).unsqueeze(1)                 # (S,1,125)
        v1 = w.sum(dim=-1) + EPS                                 # (S,1)
        mean = (x * w).sum(dim=-1) / v1                          # (S,2560)
        dx2 = (x - mean.unsqueeze(-1)) ** 2
        v2 = (w * w).sum(dim=-1)
        var = (dx2 * w).sum(dim=-1) / (v1 - v2 / v1 + EPS)
        std = torch.sqrt(var)
        return self.resnet.seg_1(torch.cat([mean, std], dim=1))  # (S,256)


# ---------------------------------------------------------------------------------------------
# Segmentation: PyanNet (SincNet -> 4x BiLSTM(128) -> 2x Linear(128) -> Linear(7) -> log-softmax)
# Parameter names follow pyannote's PyanNet so a pyannote checkpoint loads (see load_seg).
# ---------------------------------------------------------------------------------------------
class _FB(nn.Module):  # holder with the same attribute path as asteroid's Encoder.filterbank
    def __init__(self, n=80):
        super().__init__()
        self.low_hz_ = nn.Parameter(torch.zeros(n // 2, 1))
        self.band_hz_ = nn.Parameter(torch.zeros(n // 2, 1))


class _SincConv(nn.Module):
    def __init__(self, n_filters=80, k=251, stride=10, sr=16000, min_low_hz=50, min_band_hz=50):
        super().__init__()
        self.filterbank = _FB(n_filters)
        self.n_filters, self.k, self.stride, self.sr = n_filters, k, stride, sr
        self.min_low_hz, self.min_band_hz = min_low_hz, min_band_hz
        self.half = k // 2
        self.register_buffer("window_", torch.from_numpy(np.hamming(k)[: self.half]).float(), persistent=False)
        self.register_buffer("n_", 2 * np.pi * (torch.arange(-self.half, 0.0).view(1, -1) / sr), persistent=False)
        self.register_buffer("weight", torch.zeros(n_filters, 1, k), persistent=False)

    @torch.no_grad()
    def bake(self):
        low = self.min_low_hz + self.filterbank.low_hz_.abs()
        high = torch.clamp(low + self.min_band_hz + self.filterbank.band_hz_.abs(), self.min_low_hz, self.sr / 2)
        band = (high - low)[:, 0]
        ftl, fth = low @ self.n_, high @ self.n_
        halfn = self.n_ / 2
        out = []
        for kind in ("cos", "sin"):
            if kind == "cos":
                left = ((torch.sin(fth) - torch.sin(ftl)) / halfn) * self.window_
                center = 2 * band.view(-1, 1)
                right = torch.flip(left, dims=[1])
            else:
                left = ((torch.cos(ftl) - torch.cos(fth)) / halfn) * self.window_
                center = torch.zeros_like(band.view(-1, 1))
                right = -torch.flip(left, dims=[1])
            bp = torch.cat([left, center, right], dim=1) / (2 * band[:, None])
            out.append(bp.view(self.n_filters // 2, 1, self.k))
        self.weight.copy_(torch.cat(out, dim=0))

    def forward(self, x):
        return F.conv1d(x, self.weight, stride=self.stride)


class PyanNet(nn.Module):
    def __init__(self, hidden=128, layers=4, num_classes=7):
        super().__init__()
        self.export_logits = False  # True for Core ML: log-softmax is done by the caller in Float (FP16/ANE log-softmax underflows)
        s = nn.Module()
        s.wav_norm1d = nn.InstanceNorm1d(1, affine=True)
        s.conv1d = nn.ModuleList([_SincConv(), nn.Conv1d(80, 60, 5), nn.Conv1d(60, 60, 5)])
        s.norm1d = nn.ModuleList([nn.InstanceNorm1d(80, affine=True), nn.InstanceNorm1d(60, affine=True), nn.InstanceNorm1d(60, affine=True)])
        self.sincnet = s
        self.lstm = nn.LSTM(60, hidden, num_layers=layers, bidirectional=True, batch_first=True)
        self.linear = nn.ModuleList([nn.Linear(2 * hidden, hidden), nn.Linear(hidden, hidden)])
        self.classifier = nn.Linear(hidden, num_classes)

    @torch.no_grad()
    def bake(self):
        """Bake the sinc filters (a function of low_hz_/band_hz_) into a plain conv weight."""
        self.sincnet.conv1d[0].bake()
        return self

    def forward(self, wav):  # (B,1,160000) -> (B,589,7) log-probs
        s = self.sincnet
        x = s.wav_norm1d(wav)
        for c in range(3):
            x = s.conv1d[c](x)
            if c == 0:
                x = x.abs()
            x = F.leaky_relu(s.norm1d[c](F.max_pool1d(x, 3, 3)))
        x, _ = self.lstm(x.transpose(1, 2))
        for lin in self.linear:
            x = F.leaky_relu(lin(x))
        z = self.classifier(x)
        return z if self.export_logits else F.log_softmax(z, dim=-1)


def load_seg(path: Path) -> PyanNet:
    ck = load_checkpoint(str(path))
    sd = ck["state_dict"]
    m = PyanNet()
    missing, unexpected = m.load_state_dict(sd, strict=False)
    # asteroid's window_/n_ buffers are recomputed locally; nothing else may differ
    ok_unexp = {k for k in unexpected if k.endswith(("filterbank.window_", "filterbank.n_"))}
    bad = (set(unexpected) - ok_unexp) | {k for k in missing if not k.endswith("conv1d.0.weight")}
    if bad:
        raise SystemExit(f"state dict mismatch: {sorted(bad)[:10]}")
    return m.eval().bake()


# ---------------------------------------------------------------------------------------------
# Conversion
# ---------------------------------------------------------------------------------------------
def convert_and_compile(module, example_inputs, inputs, outputs, out_name: str, out_dir: Path, meta: dict) -> Path:
    """Traces the module, converts it to an FP16 ML Program, and writes the COMPILED .mlmodelc to out_dir/out_name.
    The intermediate .mlpackage lives in a temporary folder and is discarded."""
    import coremltools as ct
    module = module.eval()
    with torch.no_grad():
        traced = torch.jit.trace(module, example_inputs, check_trace=False)
    ml = ct.convert(
        traced, inputs=inputs, outputs=outputs,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
    )
    ml.short_description = meta["description"]
    ml.license = f"{LICENSE} ({LICENSE_URL})"
    ml.author = meta["author"]
    for k, v in meta["user"].items():
        ml.user_defined_metadata[k] = v
    out_dir.mkdir(parents=True, exist_ok=True)
    target = out_dir / out_name
    if target.exists():
        shutil.rmtree(target)
    with tempfile.TemporaryDirectory() as tmp:
        pkg = Path(tmp) / (out_name.replace(".mlmodelc", ".mlpackage"))
        ml.save(str(pkg))
        compiled = Path(ct.utils.compile_model(str(pkg), destination_path=str(Path(tmp) / "compiled.mlmodelc")))
        shutil.copytree(compiled, target)
    for junk in target.rglob(".DS_Store"):
        junk.unlink()
    return target


def common_meta(repo: str, rev: str, sha: str, what: str) -> dict:
    return {
        "source_repo": repo, "source_revision": rev, "source_checkpoint_sha256": sha,
        "license": LICENSE, "license_url": LICENSE_URL, "modification": MODIFICATION,
        "attribution": what, "precision": "float16",
        "converter": "tools/convert-diarization-models/convert.py (Vauta)",
    }


def report(path: Path):
    size = sum(f.stat().st_size for f in path.rglob("*") if f.is_file())
    print(f"wrote {path}  ({size / 2**20:.2f} MiB)\n  tree sha256 (pin in DiarizationModels.swift): {tree_hash(path)}")


def do_embedding(a):
    import coremltools as ct
    ckpt = fetch_wespeaker(Path(a.src_dir), a.download)
    ck = load_checkpoint(str(ckpt))
    net = EmbeddingGraph(ck["state_dict"]).eval()
    ex = (torch.randn(1, FBANK_FRAMES, 80), (torch.rand(MAX_SPK, SEG_FRAMES) > 0.5).float())
    user = common_meta(WESPEAKER_REPO, WESPEAKER_REV, WESPEAKER_FILES["pytorch_model.bin"],
                       "WeSpeaker ResNet34-LM speaker embedding model (Wang et al., ICASSP 2023), trained on VoxCeleb; "
                       "distributed by pyannote (Bredin) as pyannote/wespeaker-voxceleb-resnet34-LM")
    user.update({"input_fbank": "kaldi fbank of (audio*32768): 80 mel, 25ms hamming, 10ms shift, no dither, no energy; "
                                "mean-normalisation is inside the model",
                 "eps": str(EPS), "vauta_model_id": "wespeaker-resnet34-lm-837717dd-fp16-v1"})
    meta = dict(description="WeSpeaker ResNet34-LM speaker embedding: fbank (1,998,80) + 3 masks (3,589) -> embeddings (3,256). "
                            "Core ML conversion of pyannote/wespeaker-voxceleb-resnet34-LM, CC-BY-4.0; " + MODIFICATION,
                author="WeSpeaker authors (Wang et al.); distributed by pyannote; converted for Vauta", user=user)
    report(convert_and_compile(
        net, ex,
        [ct.TensorType("fbank", shape=(1, FBANK_FRAMES, 80), dtype=np.float32),
         ct.TensorType("masks", shape=(MAX_SPK, SEG_FRAMES), dtype=np.float32)],
        [ct.TensorType("embeddings", dtype=np.float32)], EMB_NAME, Path(a.out_dir), meta))


def do_segmentation(a):
    import coremltools as ct
    net = load_seg(verified(Path(a.checkpoint), SEG_SHA256))
    net.export_logits = True  # the app applies log-softmax in Float (it underflows in FP16 / on the Neural Engine)
    ex = (torch.randn(1, 1, WIN),)
    user = common_meta(SEG_REPO, SEG_REV, SEG_SHA256,
                       "pyannote community-1 speaker segmentation model (Plaquet & Bredin, Interspeech 2023), "
                       f"file {SEG_FILE}")
    user.update({"classes": "powerset: none, {0}, {1}, {2}, {0,1}, {0,2}, {1,2}", "output": "logits (log-softmax is applied by the caller)",
                 "vauta_model_id": "pyannote-community-1-segmentation-3533c8cf-fp16-v1"})
    meta = dict(description="pyannote community-1 powerset segmentation: 10 s of 16 kHz mono audio (1,1,160000) -> logits (1,589,7). "
                            "Core ML conversion, CC-BY-4.0; " + MODIFICATION,
                author="Herve Bredin / pyannote (Plaquet & Bredin); converted for Vauta", user=user)
    report(convert_and_compile(net, ex, [ct.TensorType("audio", shape=(1, 1, WIN), dtype=np.float32)],
                               [ct.TensorType("logits", dtype=np.float32)], SEG_NAME, Path(a.out_dir), meta))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("embedding", help="convert the WeSpeaker embedding model")
    e.add_argument("--src-dir", default=str(HERE / "src_wespeaker"), help="folder with the pinned pytorch_model.bin, config.yaml, README.md")
    e.add_argument("--download", action="store_true", help="fetch the pinned public files that are missing (no token)")
    e.add_argument("--out-dir", default=str(DEFAULT_OUT))
    e.set_defaults(fn=do_embedding)
    s = sub.add_parser("segmentation", help="convert the community-1 segmentation model")
    s.add_argument("--checkpoint", required=True, help=f"{SEG_FILE} of {SEG_REPO}@{SEG_REV[:8]}, obtained by you; its SHA-256 must equal {SEG_SHA256}")
    s.add_argument("--out-dir", default=str(DEFAULT_OUT))
    s.set_defaults(fn=do_segmentation)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
