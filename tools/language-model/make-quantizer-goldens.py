#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Goldens for AffineQuantizer: bf16 rows and the bytes mlx's GPU `mx.quantize` (group 64, 4 or 8 bits, affine) gives for them.

usage: make-quantizer-goldens.py <out.json> [bits]   (4 by default: quantizer_goldens.json; 8: quantizer_goldens_8bit.json)

Rows cover random groups, all-negative, all-positive, all-zero, constant, values on rounding ties, extremes near the bf16
maximum and subnormals. Each row has 128 columns (two groups). The expected scales/biases/words come from mlx (GPU) and are
checked here against the numpy port (affine_quant.py) that produced the manifest. Developer-side only.
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import mlx.core as mx
import affine_quant as aq

BITS = int(sys.argv[2]) if len(sys.argv) > 2 else 4
rng = np.random.default_rng(5)
rows = []
for _ in range(40):
    rows.append(rng.normal(0, rng.choice([0.002, 0.02, 0.2, 2.0]), 128))
for _ in range(10):
    rows.append(-np.abs(rng.normal(0, 0.05, 128)))
for _ in range(10):
    rows.append(np.abs(rng.normal(0, 0.05, 128)))
rows.append(np.zeros(128)); rows.append(np.ones(128) * 0.5); rows.append(-np.ones(128) * 0.25)
tie = np.concatenate([np.arange(64) * (1 / 30.0), -np.arange(64) * (1 / 30.0)]); rows.append(tie)
rows.append(np.concatenate([np.linspace(0, 15, 64), np.linspace(-15, 0, 64)]))
rows.append(np.concatenate([np.linspace(-1, 1, 64), np.linspace(0, 0.9, 64)]))
big = np.full(128, 3.0e38); big[0] = -3.0e38; big[70] = 1.0e38; rows.append(big)
sub = rng.normal(0, 1e-39, 128); rows.append(sub)
tiny = np.concatenate([rng.normal(0, 1e-8, 64), rng.normal(0, 1e-3, 64)]); rows.append(tiny)
m = np.array(rows, dtype=np.float32)
bits = aq.f32_to_bf16_bits(m)
ours = aq.quantize_rows(bits, 128, BITS)
a = mx.array(bits).view(mx.bfloat16)
w, s, b = mx.quantize(a, group_size=64, bits=BITS, mode="affine")
mx.eval(w, s, b)
assert (np.array(w) == ours[0]).all() and (np.array(s.view(mx.uint16)) == ours[1]).all() and (np.array(b.view(mx.uint16)) == ours[2]).all()
json.dump({"bits": BITS, "cols": 128, "rows": int(bits.shape[0]), "input": [[int(x) for x in r] for r in bits],
           "weights": [[int(x) for x in r] for r in ours[0]], "scales": [[int(x) for x in r] for r in ours[1]],
           "biases": [[int(x) for x in r] for r in ours[2]]}, open(sys.argv[1], "w"), separators=(",", ":"))
print(bits.shape[0], "rows,", BITS, "bits; numpy port == mx GPU")
