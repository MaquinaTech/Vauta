# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""NumPy re-statement of the Kaldi fbank used by WeSpeaker/pyannote (the algorithm the Swift/Accelerate
port must implement).  80 mel bins, 25 ms Hamming window, 10 ms shift, snip_edges, DC removal,
pre-emphasis 0.97, 512-pt FFT, power spectrum, mel 20 Hz..Nyquist, natural log with float32-eps floor.
Input: float audio in [-1,1] (scaled by 32768 internally, like pyannote)."""
import numpy as np

def mel_banks(n_mel=80, n_fft=512, sr=16000, low=20.0, high=8000.0):
    mel = lambda f: 1127.0 * np.log(1.0 + f / 700.0)
    inv = lambda m: 700.0 * (np.exp(m / 1127.0) - 1.0)
    nb = n_fft // 2
    bw = sr / n_fft
    ml, mh = mel(low), mel(high)
    d = (mh - ml) / (n_mel + 1)
    b = np.arange(n_mel)[:, None]
    left, ctr, right = ml + b * d, ml + (b + 1) * d, ml + (b + 2) * d
    m = mel(bw * np.arange(nb))[None, :]
    up = (m - left) / (ctr - left)
    dn = (right - m) / (right - ctr)
    banks = np.maximum(0.0, np.minimum(up, dn))
    return np.pad(banks, ((0, 0), (0, 1))).astype(np.float64)  # (80, 257)

_BANKS = mel_banks()
_WIN = (0.54 - 0.46 * np.cos(2 * np.pi * np.arange(400) / 399))

def fbank(audio, scale=32768.0):
    x = np.asarray(audio, dtype=np.float64) * scale
    n = 1 + (len(x) - 400) // 160
    idx = np.arange(400)[None, :] + 160 * np.arange(n)[:, None]
    f = x[idx]
    f = f - f.mean(axis=1, keepdims=True)
    prev = np.concatenate([f[:, :1], f[:, :-1]], axis=1)
    f = (f - 0.97 * prev) * _WIN
    f = np.pad(f, ((0, 0), (0, 112)))
    p = np.abs(np.fft.rfft(f, axis=1)) ** 2
    e = p @ _BANKS.T
    return np.log(np.maximum(e, np.finfo(np.float32).eps)).astype(np.float32)  # (n, 80)
