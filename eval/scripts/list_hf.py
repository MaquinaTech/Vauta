# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Write manifests/hf_oids.json: LFS SHA-256 (oid) of the pinned-revision files, from the HF tree API."""
import json, os, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hpins as P

def tree(repo, rev, prefix):
    u = f"https://huggingface.co/api/datasets/{repo}/tree/{rev}/{prefix}?recursive=true&expand=true"; out = {}
    while u:
        r = urllib.request.urlopen(u)
        for f in json.load(r):
            if f["type"] == "file": out[f["path"]] = (f.get("lfs") or {}).get("oid")
        l = r.headers.get("Link"); u = l.split("<")[1].split(">")[0] if l and 'rel="next"' in l else None
    return {k: v for k, v in out.items() if v}
d = {"mls": tree(*P.MLS, "data/mls_spanish"), "voxpopuli": tree(*P.VOXPOPULI, "es")}
json.dump(d, open(os.path.join(P.MANIFESTS, "hf_oids.json"), "w"), indent=0)
print({k: len(v) for k, v in d.items()})
