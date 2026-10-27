# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
# Build long AMI transcripts (manual words, all speakers, no time cap) with speaker labels.
# python3 -I scripts/build_ami_long.py   (reads src/ami_public_manual_1.6.2.zip, sha pinned in the evaluation pins file)
import json, os, sys, zipfile, hashlib, xml.etree.ElementTree as ET
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAUSE, MIN_WORDS = 1.0, 3   # identical to the minutes evaluation script
zf = zipfile.ZipFile(f"{H}/src/ami_public_manual_1.6.2.zip")
meet = {}
for mt in ET.fromstring(zf.read("corpusResources/meetings.xml")).iter("meeting"):
    meet[mt.get("observation")] = sorted({(s.get("nxt_agent"), s.get("global_name")) for s in mt.iter("speaker")})
def passages(m):
    out, end = [], 0.0
    for letter, _ in meet[m]:
        try: root = ET.fromstring(zf.read(f"words/{m}.{letter}.words.xml"))
        except KeyError: continue
        cur, last = [], None
        for el in root:
            if el.tag != "w" or el.get("trunc") == "true": continue
            s = float(el.get("starttime", "nan"))
            if s != s: continue
            punc = el.get("punc") == "true"
            if cur and not punc and last is not None and s - last > PAUSE:
                out.append((letter, cur)); cur = []
            if not cur and punc: continue
            cur.append((s, float(el.get("endtime", s)), el.text or "", punc)); last = cur[-1][1]
        if cur: out.append((letter, cur))
    res = []
    for letter, w in sorted(out, key=lambda x: x[1][0][0]):
        if sum(1 for t in w if not t[3]) < MIN_WORDS: continue
        text = ""
        for _, _, tok, punc in w: text += tok if punc or not text else " " + tok
        res.append((w[0][0], w[-1][1], letter, text))
    return [dict(id=i + 1, start=round(s, 2), end=round(e, 2), speaker=f"Speaker {ord(l) - 64} (remote)", text=t) for i, (s, e, l, t) in enumerate(res)]
splits = {k: [x.strip() for x in open(f"{H}/src/{k}.meetings.txt") if x.strip()] for k in ("dev", "test")}
os.makedirs(f"{H}/data/ami_long", exist_ok=True)
rows = []
for split, ms in splits.items():
    for m in ms:
        if m not in meet: continue
        ps = passages(m)
        if not ps: continue
        dur = max(p["end"] for p in ps) / 60
        keep = 29.5 <= dur <= 60
        rows.append(dict(meeting=m, split=split, minutes=round(dur, 1), passages=len(ps), words=sum(len(p["text"].split()) for p in ps), kept=keep))
        if keep:
            p = f"{H}/data/ami_long/{m}.json"
            json.dump(dict(meeting=m, split=split, language="en", source="AMI manual transcript 1.6.2 (CC BY 4.0)", passages=ps), open(p, "w"), ensure_ascii=False)
json.dump(rows, open(f"{H}/data/ami_long/_index.json", "w"), indent=1)
for r in rows: print(r)
