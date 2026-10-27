# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Shared paths, pins and small helpers for the evaluation scripts (standard library plus numpy)."""
import hashlib
import json
import os
import subprocess
import sys
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
EVAL = os.path.dirname(HERE)
# VAUTA_EVAL_PINS selects another pin file (eval/heldout/pins_heldout.json: the held-out meetings and set names).
PINS = json.load(open(os.environ.get("VAUTA_EVAL_PINS", os.path.join(EVAL, "pins.json"))))
WORK = os.path.abspath(os.environ.get("VAUTA_EVAL_WORK", os.path.join(EVAL, "work")))
SR = 16000

SRC = os.path.join(WORK, "src")
SETS = os.path.join(WORK, "sets")
RUNS = os.path.join(WORK, "runs")


def sha256_file(path, chunk=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while block := f.read(chunk):
            h.update(block)
    return h.hexdigest()


def read_manifest(name):
    """Lines of `<sha256>  <file>  <n> bytes  ...` -> {file: (sha256, bytes, url)}."""
    out = {}
    for line in open(os.path.join(EVAL, "manifests", name)):
        parts = [p for p in line.rstrip("\n").split("  ") if p]
        if len(parts) < 3:
            continue
        sha, fname = parts[0], parts[1]
        size = int(parts[2].split()[0])
        url = parts[-1] if parts[-1].startswith("http") else None
        out[fname] = (sha, size, url)
    return out


def read_wav(path):
    """16-bit PCM mono WAV -> (float32 numpy array in [-1, 1), sample rate)."""
    import numpy as np
    with wave.open(path, "rb") as w:
        if w.getsampwidth() != 2:
            raise ValueError(f"{path}: expected 16-bit PCM")
        n, ch, sr = w.getnframes(), w.getnchannels(), w.getframerate()
        data = np.frombuffer(w.readframes(n), dtype="<i2")
    if ch > 1:
        data = data.reshape(-1, ch)[:, 0]
    return data.astype(np.float32) / 32768.0, sr


def write_wav(path, x, sr=SR):
    import numpy as np
    pcm = np.clip(np.rint(x * 32767.0), -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def environment(binary):
    """Facts that go with a result: machine, OS, tools, the app build and the repository state."""
    def out(*cmd):
        try:
            return subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout.strip()
        except Exception:
            return "unknown"
    return {
        "date": out("date", "-u", "+%Y-%m-%dT%H:%M:%SZ"),
        "chip": out("sysctl", "-n", "machdep.cpu.brand_string"),
        "memory_gb": round(int(out("sysctl", "-n", "hw.memsize") or 0) / 2**30),
        "macos": out("sw_vers", "-productVersion") + " (" + out("sw_vers", "-buildVersion") + ")",
        "app_version": out(binary, "version"),
        "git_commit": out("git", "-C", EVAL, "rev-parse", "--short", "HEAD"),
        "git_dirty": bool(out("git", "-C", EVAL, "status", "--porcelain", "--", "..")),
        "ffmpeg": (out("ffmpeg", "-version").splitlines() or ["unknown"])[0],
        "python": sys.version.split()[0],
        "numpy": __import__("numpy").__version__,
    }
