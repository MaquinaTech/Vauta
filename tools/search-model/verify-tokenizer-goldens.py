#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Checks Tests/VautaCoreTests/Fixtures/SearchModel/tokenizer_goldens.jsonl against Hugging Face's tokenizer.

usage: verify-tokenizer-goldens.py <tokenizer-dir> [goldens.jsonl]

`<tokenizer-dir>` holds the pinned tokenizer.json (and tokenizer_config.json) of google/embeddinggemma-2 at revision
914f7f89142e33e77833254d9c9b90c3cef7303b. Needs `pip install transformers==5.18.0` (a developer-side step, never run against
user data). Each line of the fixture is {"tag", "text", "ids" (bos + tokens cut to 512 + eos), "n" (tokens without bos/eos,
uncut)}; the strings are self-written (Italian and Portuguese sentences, emoji, numbers, whitespace, special-token text, code and
random Unicode). The fixture was produced with the same tokenizer for spike 9c; this script reproduces its ids.
"""
import json, sys
from pathlib import Path
from transformers import AutoTokenizer

tok = AutoTokenizer.from_pretrained(sys.argv[1])
path = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).resolve().parents[2] / "Tests/VautaCoreTests/Fixtures/SearchModel/tokenizer_goldens.jsonl"
bad = 0
for line in path.read_text(encoding="utf-8").splitlines():
    g = json.loads(line)
    ids = tok(g["text"], truncation=True, max_length=512)["input_ids"]
    full = tok(g["text"], truncation=False)["input_ids"]
    if ids != g["ids"] or len(full) - 2 != g["n"]:
        bad += 1
        print("MISMATCH", g["tag"], repr(g["text"][:60]))
print("mismatches:", bad)
sys.exit(1 if bad else 0)
