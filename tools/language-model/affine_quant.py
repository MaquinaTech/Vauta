# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Reference (numpy) port of Vauta's deterministic 4-bit affine quantizer, group 64.

It mirrors the semantics of MLX's Metal `affine_quantize` kernel (what `mlx_lm convert` runs on the GPU): the group minimum
starts at the bf16 maximum and the group maximum starts at 0, rounding is half away from zero, the scale is clamped at 1e-7,
the quantised values use the float scale and bias, and scales and biases are stored as bf16. All arithmetic is IEEE fp32.
Tool only: it is never shipped. The Swift implementation (AffineQuantizer.swift) must produce the same bytes.
"""
import numpy as np

BF16_MAX = np.float32(3.3895313892515355e38)
GROUP = 64
BITS = 4


def bf16_to_f32(raw_u16):
    return (raw_u16.astype(np.uint32) << 16).view(np.float32)


def f32_to_bf16_bits(x):
    """Round to nearest even; NaN stays NaN."""
    u = np.ascontiguousarray(x, dtype=np.float32).view(np.uint32)
    rounded = (u + np.uint32(0x7FFF) + ((u >> 16) & np.uint32(1))) >> 16
    nan = np.isnan(x)
    return np.where(nan, np.uint32(0x7FC0), rounded).astype(np.uint16)


def round_half_away(x):
    t = np.trunc(x)
    return t + np.sign(x) * ((np.abs(x - t)) >= np.float32(0.5))


def quantize_rows(bf16_bits, cols):
    """bf16_bits: uint16 array [rows, cols] (cols % 64 == 0). Returns (weight uint32 [rows, cols/8], scales u16, biases u16)."""
    rows = bf16_bits.shape[0]
    g = bf16_to_f32(bf16_bits).reshape(-1, GROUP)
    if not np.isfinite(g).all():
        raise ValueError("non-finite weight")
    wmin = np.minimum(BF16_MAX, g.min(axis=1))
    wmax = np.maximum(np.float32(0), g.max(axis=1))
    scale = np.maximum((wmax - wmin) / np.float32(15), np.float32(1e-7))
    side = np.abs(wmin) > np.abs(wmax)
    scale = np.where(side, scale, -scale).astype(np.float32)
    edge = np.where(side, wmin, wmax).astype(np.float32)
    q0 = round_half_away(edge / scale)
    at_zero = q0 == 0
    with np.errstate(divide="ignore", invalid="ignore"):
        scale = np.where(at_zero, scale, edge / np.where(at_zero, np.float32(1), q0)).astype(np.float32)
    bias = np.where(at_zero, np.float32(0), edge).astype(np.float32)
    q = np.clip(round_half_away((g - bias[:, None]) / scale[:, None]), np.float32(0), np.float32(15))
    q = q.astype(np.uint8).reshape(rows, cols // 8, 8).astype(np.uint32)
    shifts = (np.arange(8, dtype=np.uint32) * 4)[None, None, :]
    packed = (q << shifts).sum(axis=2, dtype=np.uint32)
    return packed, f32_to_bf16_bits(scale).reshape(rows, cols // GROUP), f32_to_bf16_bits(bias).reshape(rows, cols // GROUP)
