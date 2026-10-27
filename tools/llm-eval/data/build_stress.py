# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
# Long-context stress variant: the three consecutive 45-min windows of the 2019-12-18 session concatenated (135 min of a real continuous
# session with two ~10-min gaps removed), ids renumbered. Questions of the three windows are re-mapped (answerable ones, plus the
# unanswerable ones of the FIRST window, whose status cannot change). python3 -I scripts/build_stress.py
import json, os
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
parts = [json.load(open(f"{H}/data/es_real/cdm191218_{s}.json")) for s in "abc"]
ps, off, t0, offs = [], 0, 0.0, {}
for s, j in zip("abc", parts):
    offs[f"cdm191218_{s}"] = (off, t0)
    for p in j["passages"]:
        ps.append(dict(p, id=p["id"] + off, start=p["start"] + t0, end=p["end"] + t0, speaker=f"Speaker {p['speaker'].split()[-1]} (win {s})" if p["speaker"] != "Speaker ?" else p["speaker"]))
    off += len(j["passages"]); t0 += j["duration_min"] * 60
out = dict(meeting="cdm191218_abc", language="es", source_file=parts[0]["source_file"], duration_min=round(t0 / 60, 1), words=sum(len(p["text"].split()) for p in ps),
           note="Concatenation of windows a,b,c. Diarization labels are per window (suffix 'win a/b/c'): the same number in two windows is NOT the same person.", passages=ps)
json.dump(out, open(f"{H}/data/es_real/cdm191218_abc.json", "w"), ensure_ascii=False)
qs = []
for l in open(f"{H}/data/questions.jsonl"):
    q = json.loads(l)
    if q["meeting"] not in offs: continue
    o, t = offs[q["meeting"]]
    if not q["answerable"] and q["meeting"] != "cdm191218_a": continue
    q.update(qid=q["qid"].replace("cdm191218_", "cdm191218_abc-"), meeting="cdm191218_abc", t_seg=q["t_seg"] + o, t_sec=q["t_sec"] + t, gold_segments=[s + o for s in q["gold_segments"]])
    q["visible_segments"] = q["t_seg"]
    qs.append(q)
open(f"{H}/data/questions_stress.jsonl", "w").write("".join(json.dumps(q, ensure_ascii=False) + "\n" for q in qs))
print(len(ps), "segments", out["duration_min"], "min", out["words"], "words;", len(qs), "stress questions")
