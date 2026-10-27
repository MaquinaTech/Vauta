#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Logit and greedy goldens of the integrated language model, from mlx-lm Python on the SAME assembled file.

usage: make-goldens.py <model-folder> <chat_template.jinja> <sets-dir> <out.jsonl|-> [<long-out.jsonl>]

<model-folder> holds Vauta's assembled `model.safetensors`, `tokenizer.json` and a `config.json` (Google's, plus
`"quantization": {"group_size": 64, "bits": 4, "mode": "affine"}`), so mlx-lm runs on exactly the weights Vauta runs on.
8 fixed prompts built from self-written text and public AMI meeting text. Per prompt it stores the prompt ids (rendered with
the pinned chat template and HF tokenizers), the first 64 greedy ids (stopping at a stop id) and the top 20 ids and values of
the last-position logits after the soft cap. Prefill uses the same chunking as Vauta (512 tokens). Developer-side only.
With <long-out.jsonl> it also writes one golden of about 30,000 tokens (`ami_30k`: public AMI text, passages repeated in turn) with the
top 20 last-position logits and no greedy ids, which `Vauta llm-selftest --model --long` checks: the many-chunk growth of the
full-attention caches and the windowed masks past the 8.5k tokens of the other goldens.
Needs mlx 0.32.3, mlx-lm 0.32.0, tokenizers, jinja2 (requirements-tools.txt).
"""
import json, os, sys, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pathlib import Path
import mlx.core as mx
from mlx_lm.utils import load_model
from mlx_lm.models.cache import make_prompt_cache
from gemma_chat import GemmaChat

folder, template, sets, out = sys.argv[1:5]
long_out = sys.argv[5] if len(sys.argv) > 5 else None
chat = GemmaChat(os.path.join(folder, "tokenizer.json"), template)
model, _ = load_model(Path(folder))
STOP = {1, 106, 50}
CHUNK = 512


def amI(name, upto=None):
    d = json.load(open(os.path.join(sets, name), encoding="utf-8"))
    lines = [p["text"] for p in d["passages"]]
    return lines


def transcript(files, tokens):
    text = []
    n = 0
    for f in files:
        for l in amI(f):
            k = len(chat.tok.encode(l, add_special_tokens=False).ids) + 3
            if n + k > tokens:
                return "\n".join(text)
            text.append("Speaker %d: %s" % (1 + n % 4, l))
            n += k
    return "\n".join(text)


SYSTEM = "You write faithful meeting minutes. Use only what the transcript says."
prompts = [
    ("en_short", [("system", "You are a helpful assistant."), ("user", "Explain in three sentences why the sky is blue.")]),
    ("es_short", [("user", "Resume en tres frases por qué las reuniones largas suelen ser poco productivas.")]),
    ("de_short", [("user", "Nenne drei Vorteile von regelmäßigen Teambesprechungen.")]),
    ("ja_short", [("user", "会議の議事録を書くときに大切なことを三つ挙げてください。")]),
    ("multi_turn", [("system", "Answer in one short sentence."), ("user", "Name a planet."), ("assistant", "Mars."), ("user", "Name another one, and say how far it is from the sun.")]),
    ("ami_2k", [("system", SYSTEM), ("user", transcript(["ami_EN2002a_600.json"], 1900) + "\n\nList the decisions that were made."), ]),
    ("ami_8k", [("system", SYSTEM), ("user", transcript(["ami_EN2002a_600.json", "ami_EN2002b_600.json", "ami_IS1009a_600.json", "ami_ES2004a_600.json"], 7900) + "\n\nWrite a title and a summary of three sentences.")]),
    ("minutes_json", [("system", SYSTEM + ' Reply with one JSON object {"title": string, "summary": string, "decisions": [{"text": string}], "tasks": [{"text": string, "owner": string|null}]} and nothing else.'),
                      ("user", transcript(["ami_ES2004c_180.json"], 1500))]),
]


def run(ids):
    cache = make_prompt_cache(model)
    last = None
    i = 0
    while i < len(ids):
        c = ids[i:i + CHUNK]
        o = model(mx.array(c)[None], cache=cache)
        mx.eval(o[:, -1, :])
        last = o[0, -1, :]
        i += len(c)
    return cache, last


if out != "-":  # "-" skips the 8 standard goldens (only the long one is made)
    with open(out, "w", encoding="utf-8") as f:
        for name, msgs in prompts:
            m = [{"role": r, "content": c} for r, c in msgs]
            ids, text = chat.ids(m)
            cache, logits = run(ids)
            l32 = logits.astype(mx.float32)
            top = mx.argsort(-l32)[:20]
            topv = l32[top]
            greedy, finished = [], False
            cur = l32
            for _ in range(64):
                t = int(mx.argmax(cur).item())
                if t in STOP:
                    finished = True
                    break
                greedy.append(t)
                o = model(mx.array([[t]]), cache=cache)
                cur = o[0, -1, :].astype(mx.float32)
                mx.eval(cur)
            rec = {"name": name, "messages": msgs, "ids": ids, "greedy": greedy, "finished": finished,
                   "top20": [[int(a), float(b)] for a, b in zip(top.tolist(), topv.tolist())], "logitsDType": str(logits.dtype)}
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            f.flush()
            print(name, len(ids), "tokens;", len(greedy), "greedy;", rec["logitsDType"], flush=True)

if long_out:
    files = sorted(glob.glob(os.path.join(sets, "ami_*_600.json")))
    passages = [l for f in files for l in amI(os.path.basename(f))]
    parts, n, i = [], 0, 0
    while n < 29_500:
        l = passages[i % len(passages)]
        parts.append("Speaker %d: %s" % (1 + i % 4, l))
        n += len(chat.tok.encode(l, add_special_tokens=False).ids) + 3
        i += 1
    msgs = [("system", SYSTEM), ("user", "\n".join(parts) + "\n\nList the decisions that were made.")]
    ids, text = chat.ids([{"role": r, "content": c} for r, c in msgs])
    cache, logits = run(ids)
    l32 = logits.astype(mx.float32)
    top = mx.argsort(-l32)[:20]
    topv = l32[top]
    rec = {"name": "ami_30k", "messages": msgs, "ids": ids, "greedy": [], "finished": False,
           "top20": [[int(a), float(b)] for a, b in zip(top.tolist(), topv.tolist())], "logitsDType": str(logits.dtype)}
    with open(long_out, "w", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print("ami_30k", len(ids), "tokens;", rec["logitsDType"], flush=True)
