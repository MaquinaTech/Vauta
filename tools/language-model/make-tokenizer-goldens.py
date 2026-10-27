#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Writes the Gemma 4 tokenizer goldens: 2,000 strings and the ids Hugging Face `tokenizers` gives them (no bos/eos).

usage: make-tokenizer-goldens.py <tokenizer.json> <sets-dir> <w9b-goldens.jsonl> <out.jsonl> [--check]

Strings: the 487 self-written strings of the search-model goldens, lines of public AMI meeting sets (English), their machine
translations if present, and generated Unicode (emoji, CJK, combining marks, whitespace runs, control-token text, code,
numbers). `--check` re-reads <out.jsonl> and compares it with a fresh encoding. Developer-side only.
"""
import glob, json, os, random, sys
from tokenizers import Tokenizer

tokp, sets, w9b, out = sys.argv[1:5]
tok = Tokenizer.from_file(tokp)


def enc(t):
    return tok.encode(t, add_special_tokens=False).ids


if "--check" in sys.argv:
    bad = 0
    for line in open(out, encoding="utf-8"):
        g = json.loads(line)
        if enc(g["text"]) != g["ids"]:
            bad += 1
            print("MISMATCH", g["tag"], repr(g["text"][:60]))
    print("mismatches:", bad)
    sys.exit(1 if bad else 0)

rng = random.Random(11)
rows = []
for line in open(w9b, encoding="utf-8"):
    g = json.loads(line)
    rows.append((g["tag"], g["text"]))
for f in sorted(glob.glob(os.path.join(sets, "*_600.json"))):
    d = json.load(open(f, encoding="utf-8"))
    for p in d["passages"]:
        if 15 < len(p["text"]) < 400:
            rows.append(("ami", p["text"]))
rng.shuffle(rows)
rows = rows[:1500]
alphabet = list("abcdefghijklmnopqrstuvwxyzáéíóúñüßçàèìòùâêîôûäöëïœæøåÇÑÀÉ0123456789 .,;:!?()[]{}<>|/\\-_+=*&^%$#@\"'`~\n\t日本語中文한국어привет мир🙂🚀😀…—–·")
specials = ["<turn|>", "<|turn>", "<bos>", "<eos>", "<pad>", "<unk>", "<|think|>", "<start_of_turn>", "<end_of_turn>", "<0x41>", "<unused12>", "▁", "<mask>"]
while len(rows) < 2000:
    kind = rng.choice(["rand", "ws", "spec", "num", "code", "cjk"])
    if kind == "rand":
        t = "".join(rng.choice(alphabet) for _ in range(rng.randint(1, 120)))
    elif kind == "ws":
        t = "".join(rng.choice([" ", "  ", "\n", "\t", " ", "　", "a", "b"]) for _ in range(rng.randint(1, 40)))
    elif kind == "spec":
        t = " ".join(rng.choice(specials + ["text", "more", "x"]) for _ in range(rng.randint(1, 8)))
    elif kind == "num":
        t = " ".join(str(rng.randint(0, 10 ** rng.randint(1, 12))) for _ in range(rng.randint(1, 6))) + rng.choice(["", "%", " EUR", "€"])
    elif kind == "code":
        t = rng.choice(['{"a": [1, 2, {"b": null}]}', "def f(x):\n    return x + 1", "SELECT * FROM t WHERE id = 3;", "https://example.org/a?b=c#d", "path/to/file_name-v2.txt"]) + rng.choice(["", "\n", " "])
    else:
        t = "".join(chr(rng.randint(0x4E00, 0x9FFF)) for _ in range(rng.randint(1, 40)))
    rows.append((kind, t))
with open(out, "w", encoding="utf-8") as f:
    for tag, t in rows:
        f.write(json.dumps({"tag": tag, "text": t, "ids": enc(t)}, ensure_ascii=False) + "\n")
print(len(rows), "strings written")
