#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Builds a tiny synthetic Gemma 4 text model (random weights, 4-bit by Vauta's quantizer) and the mlx-lm goldens for it.

usage: make-tiny-model.py <out-dir>

Writes <out-dir>/model.safetensors (the layout of the real assembled file), <out-dir>/tiny_goldens.json and a scratch folder
<out-dir>/mlx (config.json + a link to the weights) that mlx-lm loads. The model has 9 layers (full attention at 2, 5 and 8;
layers 6, 7 and 8 share keys and values), a sliding window of 16, a head dimension of 128 with proportional RoPE on the full
layers, per-layer inputs and a vocabulary of 512. Prompts of 5, 40 and 120 tokens exercise the window wrap of the rotating
cache. Developer-side only. Needs mlx 0.32.3 and mlx-lm 0.32.0.
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import mlx.core as mx
from pathlib import Path
import affine_quant as aq

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
rng = np.random.default_rng(2026)
H, L, NH, NKV, HD_S, HD_F, FF, V, PLE, WIN, SHARED = 128, 9, 4, 2, 64, 128, 256, 512, 64, 16, 6
FULL = {2, 5, 8}

text_config = {
    "model_type": "gemma4_text", "hidden_size": H, "num_hidden_layers": L, "intermediate_size": FF, "num_attention_heads": NH,
    "head_dim": HD_S, "global_head_dim": HD_F, "num_key_value_heads": NKV, "num_kv_shared_layers": L - SHARED,
    "hidden_size_per_layer_input": PLE, "vocab_size": V, "vocab_size_per_layer_input": V, "sliding_window": WIN,
    "max_position_embeddings": 4096, "rms_norm_eps": 1e-6, "final_logit_softcapping": 30.0, "use_double_wide_mlp": False,
    "attention_k_eq_v": False, "tie_word_embeddings": True, "enable_moe_block": False,
    "layer_types": ["full_attention" if i in FULL else "sliding_attention" for i in range(L)],
    "rope_parameters": {"full_attention": {"partial_rotary_factor": 0.25, "rope_theta": 1000000.0, "rope_type": "proportional"},
                        "sliding_attention": {"rope_theta": 10000.0, "rope_type": "default"}},
}


def bf(x):
    return aq.f32_to_bf16_bits(np.asarray(x, dtype=np.float32))


tensors = {}


def put_quant(name, rows, cols, scale):
    w = rng.normal(0, scale, (rows, cols)).astype(np.float32)
    packed, s, b = aq.quantize_rows(bf(w), cols)
    tensors[name + ".weight"] = mx.array(packed)
    tensors[name + ".scales"] = mx.array(s).view(mx.bfloat16)
    tensors[name + ".biases"] = mx.array(b).view(mx.bfloat16)


def put_vec(name, n, mean=1.0, sd=0.1):
    tensors[name] = mx.array(bf(rng.normal(mean, sd, n))).view(mx.bfloat16)


P = "language_model.model."
put_quant(P + "embed_tokens", V, H, 0.6)
put_quant(P + "embed_tokens_per_layer", V, L * PLE, 0.3)
put_quant(P + "per_layer_model_projection", L * PLE, H, 0.1)
put_vec(P + "per_layer_projection_norm.weight", PLE)
put_vec(P + "norm.weight", H)
for i in range(L):
    hd = HD_F if i in FULL else HD_S
    p = P + f"layers.{i}."
    put_quant(p + "self_attn.q_proj", NH * hd, H, 0.08)
    put_quant(p + "self_attn.o_proj", H, NH * hd, 0.05)
    put_vec(p + "self_attn.q_norm.weight", hd)
    if i < SHARED:
        put_quant(p + "self_attn.k_proj", NKV * hd, H, 0.08)
        put_quant(p + "self_attn.v_proj", NKV * hd, H, 0.08)
        put_vec(p + "self_attn.k_norm.weight", hd)
    put_quant(p + "mlp.gate_proj", FF, H, 0.08)
    put_quant(p + "mlp.up_proj", FF, H, 0.08)
    put_quant(p + "mlp.down_proj", H, FF, 0.06)
    put_quant(p + "per_layer_input_gate", PLE, H, 0.1)
    put_quant(p + "per_layer_projection", H, PLE, 0.1)
    for n in ("input_layernorm", "post_attention_layernorm", "pre_feedforward_layernorm", "post_feedforward_layernorm", "post_per_layer_input_norm"):
        put_vec(p + n + ".weight", H)
    tensors[p + "layer_scalar"] = mx.array(bf([float(rng.uniform(0.6, 1.2))])).view(mx.bfloat16)
mx.save_safetensors(str(out / "model.safetensors"), tensors, metadata={"format": "mlx"})

mlx_dir = out / "mlx"
mlx_dir.mkdir(exist_ok=True)
cfg = {"model_type": "gemma4", "text_config": text_config, "vocab_size": V, "quantization": {"group_size": 64, "bits": 4, "mode": "affine"}}
json.dump(cfg, open(mlx_dir / "config.json", "w"), indent=1)
link = mlx_dir / "model.safetensors"
if link.exists() or link.is_symlink():
    link.unlink()
link.symlink_to((out / "model.safetensors").resolve())

from mlx_lm.utils import load_model
from mlx_lm.models.cache import make_prompt_cache
model, _ = load_model(mlx_dir)


def run(ids, chunk):
    cache = make_prompt_cache(model)
    logits = None
    i = 0
    while i < len(ids):
        c = ids[i:i + chunk]
        o = model(mx.array(c)[None], cache=cache)
        mx.eval(o[:, -1, :])
        logits = o[0, -1, :]
        i += len(c)
    return cache, logits.astype(mx.float32)


goldens = []
for n in (5, 40, 120):
    ids = [int(x) for x in rng.integers(3, V, n)]
    cache, logits = run(ids, 512)
    top = [int(t) for t in mx.argsort(-logits)[:20].tolist()]
    greedy, cur = [], logits
    for _ in range(24):
        t = int(mx.argmax(cur).item())
        greedy.append(t)
        o = model(mx.array([[t]]), cache=cache)
        cur = o[0, -1, :].astype(mx.float32)
        mx.eval(cur)
    goldens.append({"n": n, "ids": ids, "top": top, "topValues": [float(logits[t].item()) for t in top], "greedy": greedy,
                    "logitsMax": float(mx.max(mx.abs(logits)).item())})
json.dump({"config": text_config, "goldens": goldens}, open(out / "tiny_goldens.json", "w"))
print("tiny model:", os.path.getsize(out / "model.safetensors"), "bytes;", [g["n"] for g in goldens], "tokens")
