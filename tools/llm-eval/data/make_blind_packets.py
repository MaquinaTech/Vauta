# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
# Build blind A/B judging packets with a sealed key.
# python3 -I scripts/make_blind_packets.py --task minutes|answers --a apple.jsonl --b gemma.jsonl --seed 7 --out dir
# Input JSONL (one per case): minutes {"case","summary","decisions":[{"text","quote"}],"tasks":[{"text","owner","due"}],"open_questions":[]}
#                             answers {"case","answer","citations":[seg ids]}  (ids are replaced by transcript text in the packet)
# Output: packets/<case>.json (neutral rendering, random A/B), key.json (sealed), key.sha256 (commit this BEFORE judging).
import argparse, hashlib, json, os, random
ap = argparse.ArgumentParser()
for k in ("--task", "--a", "--b", "--out"): ap.add_argument(k, required=True)
ap.add_argument("--seed", type=int, default=7); ap.add_argument("--names", default="apple,integrated")
ap.add_argument("--transcripts", default=None, help="dir with <meeting>.json to resolve citation ids (answers)")
a = ap.parse_args()
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
rd = lambda p: {j["case"]: j for j in map(json.loads, open(p))}
A, B = rd(a.a), rd(a.b)
rnd = random.Random(a.seed)
def seg_text(case, ids):
    meeting = case.rsplit("-q", 1)[0]
    for d in ("ami_long", "es_real"):
        p = f"{H}/data/{d}/{meeting}.json"
        if os.path.exists(p):
            by = {x["id"]: x for x in json.load(open(p))["passages"]}
            return [f"[{by[i]['speaker']}] {by[i]['text']}" for i in ids if i in by]
    return []
def render(task, case, o):
    if task == "minutes":
        L = ["## Summary", o.get("summary", ""), "", "## Decisions"] + [f"- {d['text']}" for d in o.get("decisions", [])]
        L += ["", "## Tasks"] + [f"- {t['text']}" + (f" (owner: {t['owner']})" if t.get("owner") else "") + (f" (due: {t['due']})" if t.get("due") else "") for t in o.get("tasks", [])]
        L += ["", "## Open questions"] + [f"- {q}" for q in o.get("open_questions", [])]
        return "\n".join(L)
    return {"answer": o.get("answer", ""), "cited_text": seg_text(case, o.get("citations", []))}
key, n = {}, 0
os.makedirs(f"{a.out}/packets", exist_ok=True)
names = a.names.split(",")
for case in sorted(set(A) & set(B)):
    flip = rnd.random() < 0.5
    first, second = (B[case], A[case]) if flip else (A[case], B[case])
    key[case] = {"A": names[1] if flip else names[0], "B": names[0] if flip else names[1]}
    json.dump({"case": case, "task": a.task, "A": render(a.task, case, first), "B": render(a.task, case, second)}, open(f"{a.out}/packets/{case}.json", "w"), ensure_ascii=False, indent=1)
    n += 1
s = json.dumps(key, sort_keys=True, indent=1)
open(f"{a.out}/key.json", "w").write(s); open(f"{a.out}/key.sha256", "w").write(hashlib.sha256(s.encode()).hexdigest() + "\n")
print(n, "packets; key sha256", open(f"{a.out}/key.sha256").read().strip())
