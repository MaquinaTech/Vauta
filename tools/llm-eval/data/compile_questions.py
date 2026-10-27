# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
# Validate and freeze the live-answer question set. python3 -I scripts/compile_questions.py
import glob, json, os, re, hashlib, collections
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def load(m):
    for d in ("ami_long", "es_real"):
        p = f"{H}/data/{d}/{m}.json"
        if os.path.exists(p): return json.load(open(p))
    raise SystemExit("no transcript " + m)
norm = lambda s: re.sub(r"\s+", " ", s.lower())
out, errs = [], []
for f in sorted(glob.glob(f"{H}/data/qsrc/*.json")):
    src = json.load(open(f)); tr = load(src["meeting"]); byid = {p["id"]: p for p in tr["passages"]}
    for i, q in enumerate(src["questions"], 1):
        qid = f"{src['meeting']}-q{i:02d}"
        t = q["t_seg"]
        if t not in byid: errs.append(f"{qid}: t_seg {t} missing"); continue
        ans = q.get("answerable", True)
        for s in q["segs"]:
            if s not in byid: errs.append(f"{qid}: seg {s} missing")
            elif s > t: errs.append(f"{qid}: gold seg {s} after t_seg {t}")
        for s, sub in q.get("must", {}).items():
            if int(s) in byid and norm(sub) not in norm(byid[int(s)]["text"]): errs.append(f"{qid}: '{sub}' not in seg {s}")
        if not ans and q["segs"] and "UNANSWERABLE" not in q["gold"].upper() and "SIN RESPUESTA" not in q["gold"].upper(): errs.append(f"{qid}: gold text should state unanswerable")
        out.append(dict(qid=qid, meeting=src["meeting"], meeting_language=tr["language"], question_language=("es" if re.search(r"[¿¡áéíóúñ]|\b(qué|cómo|cuánto|quién|cuál|hasta|por)\b", q["q"].lower()) else "en"),
                        t_seg=t, t_sec=byid[t]["start"], visible_segments=sum(1 for p in tr["passages"] if p["id"] <= t),
                        question=q["q"], category=q["cat"], answerable=ans, gold_answer=q["gold"], gold_segments=q["segs"]))
if errs: raise SystemExit("\n".join(errs))
p = f"{H}/data/questions.jsonl"
open(p, "w").write("".join(json.dumps(o, ensure_ascii=False) + "\n" for o in out))
sha = hashlib.sha256(open(p, "rb").read()).hexdigest()
c = collections.Counter(o["category"] for o in out)
st = dict(n=len(out), sha256=sha, by_meeting=collections.Counter(o["meeting"] for o in out), by_category=c,
          by_meeting_language=collections.Counter(o["meeting_language"] for o in out), by_question_language=collections.Counter(o["question_language"] for o in out),
          unanswerable=sum(1 for o in out if not o["answerable"]), unanswerable_share=round(sum(1 for o in out if not o["answerable"]) / len(out), 3))
json.dump(st, open(f"{H}/data/questions_manifest.json", "w"), indent=1)
print(json.dumps(st, indent=1))
