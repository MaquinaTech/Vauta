# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
# Exact Gemma 4 token counts of the transcripts as the app would render them ("[S<id> <speaker>] <text>" per line).
# Run with the spike venv python (tokenizers 0.23.3): <venv>/bin/python -I scripts/count_tokens.py <tokenizer.json>
import glob, json, os, sys
from tokenizers import Tokenizer
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
tok = Tokenizer.from_file(sys.argv[1])
out = {}
for d in ("ami_long", "es_real"):
    for f in sorted(glob.glob(f"{H}/data/{d}/*.json")):
        if f.endswith("_index.json"): continue
        j = json.load(open(f))
        text = "\n".join(f"[S{p['id']} {p['speaker']}] {p['text']}" for p in j["passages"])
        out[os.path.basename(f)[:-5]] = len(tok.encode(text, add_special_tokens=False).ids)
json.dump(out, open(f"{H}/data/token_counts.json", "w"), indent=1)
print(out)
