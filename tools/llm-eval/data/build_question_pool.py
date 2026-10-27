# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""The pool of sentences the live-question labelling draws from. python3 -I build_question_pool.py <sentences.jsonl> <out-dir> [--seed 7]

Input: the file `Vauta llm-eval --tasks live-questions --sentences <file> --providers apple --sets <dir>` writes (every sentence of every
transcript with its cue score at the app's own scorer). Rule of the design (docs/LANGUAGE_MODEL.md, "Live answers to questions heard in the meeting"): every sentence with a question
mark; every sentence whose score is 0.2 or more (the More answers threshold is 0.35); a random 10% of the rest (to estimate the questions
that carry no cue at all). Meetings are split by name, 40% development and 60% test, by a hash that does not depend on the order (the test
split is frozen: its SHA-256 is written to the manifest and never changes after the first labelling pass).

Output: pool.<split>.jsonl (one sentence per line, with the lines around it and the labelling form to fill), manifest.json (counts, hashes).
The labels are written by the labelling passes (two blind model passes and an adjudication, with no human review; a human spot check is pending): see
rubric/QUESTION_LABEL_RUBRIC.md. This script labels nothing.
"""
import collections, hashlib, json, os, random, sys

src, out = sys.argv[1], sys.argv[2]
seed = int(sys.argv[sys.argv.index("--seed") + 1]) if "--seed" in sys.argv else 7
rows = [json.loads(l) for l in open(src)]
os.makedirs(out, exist_ok=True)
rng = random.Random(seed)


def split(meeting):
    h = int(hashlib.sha256(("vauta-w10:" + meeting).encode()).hexdigest(), 16) % 100
    return "dev" if h < 40 else "test"


kept, rest = [], []
for r in rows:
    (kept if r["hasQuestionMark"] or r["score"] >= 0.2 else rest).append(r)
sampled = [r for r in rest if rng.random() < 0.10]
pool = sorted(kept + sampled, key=lambda r: (r["meeting"], r["t"], r["index"]))
for r in pool:
    r["id"] = f'{r["meeting"]}:{r["line"]}:{r["index"]}'
    r["split"] = split(r["meeting"])
    r["why"] = "mark" if r["hasQuestionMark"] else "score" if r["score"] >= 0.2 else "random"
    # The form the labelling passes fill (see the rubric); nothing is pre-filled.
    r["label"] = {"kind": None, "answerable": None, "answered_aloud": None, "gold_answer": None, "gold_segments": None, "language": None}
files = {}
for sp in ("dev", "test"):
    p = os.path.join(out, f"pool.{sp}.jsonl")
    with open(p, "w") as f:
        for r in pool:
            if r["split"] == sp:
                f.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")
    files[sp] = hashlib.sha256(open(p, "rb").read()).hexdigest()
manifest = {
    "source": os.path.basename(src), "seed": seed, "sentences": len(rows), "with_question_mark": sum(r["hasQuestionMark"] for r in rows),
    "pool": len(pool), "pool_by_reason": collections.Counter(r["why"] for r in pool), "pool_by_split": collections.Counter(r["split"] for r in pool),
    "meetings_by_split": {sp: sorted({r["meeting"] for r in pool if r["split"] == sp}) for sp in ("dev", "test")},
    "sha256": files,
}
json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"), indent=1, sort_keys=True)
print(json.dumps({k: v for k, v in manifest.items() if k != "meetings_by_split"}, indent=1, sort_keys=True))
