# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
# Collect hashes, sizes, sources and licences into MANIFEST.json. python3 -I scripts/make_manifest.py
import glob, hashlib, json, os, subprocess
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
tok = json.load(open(f"{H}/data/token_counts.json"))
man = {"generated": subprocess.run(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], capture_output=True, text=True).stdout.strip()}
wt = os.environ.get("VAUTA_SOURCE_TREE", os.getcwd())   # the Vauta source tree the CLI was built from
g = lambda *a: subprocess.run(["git", "-C", wt, *a], capture_output=True, text=True).stdout.strip()
man["vauta_build"] = dict(source_worktree="(read-only)", commit=g("rev-parse", "HEAD"), commit_subject=g("log", "-1", "--format=%s"), dirty_files=len(g("status", "--porcelain").splitlines()),
                          binary=f"{H}/build/release/Vauta", binary_sha256=sha(f"{H}/build/release/Vauta"), scratch_build="swift build -c release --product Vauta -Xswiftc -gnone --scratch-path build",
                          uname=subprocess.run(["uname", "-a"], capture_output=True, text=True).stdout.strip())
ami = {r["meeting"]: r for r in json.load(open(f"{H}/data/ami_long/_index.json"))}
man["ami_long"] = []
for f in sorted(glob.glob(f"{H}/data/ami_long/*.json")):
    m = os.path.basename(f)[:-5]
    if m == "_index": continue
    r = ami[m]; man["ami_long"].append(dict(meeting=m, split=r["split"], minutes=r["minutes"], passages=r["passages"], words=r["words"], gemma4_tokens=tok[m], sha256=sha(f), file=f"data/ami_long/{m}.json"))
src = json.load(open(f"{H}/data/es_sources.json"))
man["es_sources"] = src
man["es_windows"] = []
for f in sorted(glob.glob(f"{H}/data/es_real/*.json")):
    j = json.load(open(f)); m = j["meeting"]
    if m.endswith("_abc"): continue
    man["es_windows"].append(dict(window=m, source_file=j["source_file"], source_id=[k for k, v in src.items() if v["file"] == j["source_file"]][0], start_s=j["window_start_s"], end_s=j["window_end_s"], minutes=j["duration_min"],
                                  segments=len(j["passages"]), words=j["words"], speakers=j["speakers"], unlabelled_segments=sum(1 for p in j["passages"] if p["speaker"] == "Speaker ?"), gemma4_tokens=tok[m],
                                  cli_summary=j["cli_summary"], audio=f"audio/{m}.flac", audio_sha256=sha(f"{H}/audio/{m}.flac"), audio_bytes=os.path.getsize(f"{H}/audio/{m}.flac"), sha256=sha(f), file=f"data/es_real/{m}.json"))
man["stress"] = dict(transcript="data/es_real/cdm191218_abc.json", transcript_sha256=sha(f"{H}/data/es_real/cdm191218_abc.json"), gemma4_tokens=tok["cdm191218_abc"], minutes=135.0, questions="data/questions_stress.jsonl", questions_sha256=sha(f"{H}/data/questions_stress.jsonl"), n_questions=sum(1 for _ in open(f"{H}/data/questions_stress.jsonl")), derived_from="windows cdm191218_a,b,c")
man["questions"] = dict(file="data/questions.jsonl", **json.load(open(f"{H}/data/questions_manifest.json")))
man["rubrics"] = {os.path.basename(f): sha(f) for f in sorted(glob.glob(f"{H}/rubric/*.md"))}
man["scripts"] = {os.path.basename(f): sha(f) for f in sorted(glob.glob(f"{H}/scripts/*"))}
man["ami_source"] = dict(zip="src/ami_public_manual_1.6.2.zip", sha256=sha(f"{H}/src/ami_public_manual_1.6.2.zip"), url="https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip",
                         lists_commit="pyannote/AMI-diarization-setup@67c2d539286e89f68952d5dcf83912bd9f01dfae lists/{dev,test}.meetings.txt", licence="CC BY 4.0 (AMI corpus)")
json.dump(man, open(f"{H}/MANIFEST.json", "w"), indent=1, ensure_ascii=False)
print(len(man["ami_long"]), "ami", len(man["es_windows"]), "es windows", man["questions"]["n"], "questions")
