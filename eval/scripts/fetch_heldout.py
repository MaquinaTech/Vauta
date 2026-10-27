# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Download held-out sources at pinned revisions with SHA-256 verification (stdlib only).

  python3 -I eval/scripts/fetch_heldout.py --only refs|ann|ami|vox|mls|vp [--jobs 3]

A hash mismatch deletes the file and stops. Hashes are only ever appended to the committed manifests with --record. AMI audio and VoxConverse wavs have no publisher hash list: their
SHA-256 is recorded in eval/manifests/heldout/*.sha256.txt on first download (and the size must equal Content-Length) and checked on
every later download (also for the Hugging Face files that are not LFS, such as segments.txt and LICENSE, against the hash in hf_*.sha256.txt). HF files are checked against the LFS oid of the pinned revision (eval/manifests/heldout/hf_*.sha256.txt).
"""
import argparse, hashlib, io, json, os, shutil, subprocess, sys, time, urllib.request, urllib.error, zipfile
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hpins as P

UA = {"User-Agent": "vauta-eval-held-out/1"}
MAN = P.MANIFESTS


def log(*a): print(*a, file=sys.stderr, flush=True)


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        while b := f.read(1 << 20): h.update(b)
    return h.hexdigest()


def load_manifest(name):
    d = {}
    p = os.path.join(MAN, name)
    if os.path.exists(p):
        for l in open(p):
            x = l.split()
            if len(x) >= 2: d[x[1]] = x[0]
    return d


RECORD = False   # --record: append the hash of a source that has none yet to the committed manifest


def record(name, key, sha, dest=None):
    if not RECORD:
        # A file with no pinned hash is never accepted unverified: remove it and stop.
        if dest and os.path.exists(dest): os.remove(dest)
        raise SystemExit(f"{key}: no hash in {name}; refusing to use an unverified file (run once with --record to add it, then review the diff)")
    with open(os.path.join(MAN, name), "a") as f: f.write(f"{sha}  {key}\n")


def download(url, dest, sha=None, retries=6):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if sha and os.path.exists(dest) and sha256_file(dest) == sha: return "cached", sha
    part = dest + ".part"
    for k in range(1, retries + 1):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=180) as r, open(part, "wb") as f:
                n = int(r.headers.get("Content-Length", -1))
                shutil.copyfileobj(r, f, 1 << 20)
            if n >= 0 and os.path.getsize(part) != n: raise urllib.error.URLError("short read")
            break
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if k == retries: raise
            log(f"{os.path.basename(dest)}: {e}; retry {k}"); time.sleep(15 * k)
    got = sha256_file(part)
    if sha and got != sha:
        os.remove(part); raise SystemExit(f"HASH MISMATCH {url}\n expected {sha}\n got {got}")
    os.replace(part, dest)
    return "downloaded", got


def clone(repo, commit, dest):
    if not os.path.isdir(os.path.join(dest, ".git")):
        subprocess.run(["git", "clone", "--quiet", repo, dest], check=True)
    subprocess.run(["git", "-C", dest, "-c", "advice.detachedHead=false", "checkout", "--quiet", commit], check=True)
    head = subprocess.run(["git", "-C", dest, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    if head != commit: raise SystemExit(f"{repo}: expected {commit} got {head}")
    log(os.path.basename(dest), head)


def tofu(manifest, key, url, dest):
    """Trust-on-first-use for sources without a publisher hash: record then verify."""
    man = load_manifest(manifest)
    status, got = download(url, dest, man.get(key))
    if key not in man: record(manifest, key, got, dest)
    return status


def fetch_ami(jobs):
    jobs_ = []
    for m in P.AMI_MEETINGS:
        for c in range(4):
            n = f"{m}.Headset-{c}.wav"
            jobs_.append((n, f"{P.AMI_BASE}/{m}/audio/{n}", os.path.join(P.SRC, "ami-audio", m, n)))
    with ThreadPoolExecutor(jobs) as ex:
        for (n, _, _), st in zip(jobs_, ex.map(lambda j: tofu("AMI_AUDIO.sha256.txt", j[0], j[1], j[2]), jobs_)):
            log("ami", n, st)


def fetch_hf(repo_rev, paths, manifest, outdir, shas):
    repo, rev = repo_rev
    for p in paths:
        url = P.HF.format(repo=repo, rev=rev, path=p)
        # The LFS oid when the repository has one; else the hash recorded earlier (files that are not LFS: texts, licences).
        expected = shas.get(p) or load_manifest(manifest).get(p)
        st, got = download(url, os.path.join(outdir, p), expected)
        if expected is None: record(manifest, p, got, os.path.join(outdir, p))
        log("hf", p, st)


class RangeFile(io.RawIOBase):
    def __init__(self, url):
        self.url, self.pos = url, 0
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA, method="HEAD"), timeout=60) as r:
            self.size = int(r.headers["Content-Length"])
    def seekable(self): return True
    def readable(self): return True
    def tell(self): return self.pos
    def seek(self, off, whence=0):
        self.pos = {0: off, 1: self.pos + off, 2: self.size + off}[whence]; return self.pos
    def readinto(self, b):
        d = self.read(len(b)); b[:len(d)] = d; return len(d)
    def read(self, n=-1):
        if n < 0: n = self.size - self.pos
        n = min(n, self.size - self.pos)
        out = bytearray()
        while len(out) < n:
            lo = self.pos + len(out)
            req = urllib.request.Request(self.url, headers={**UA, "Range": f"bytes={lo}-{self.pos + n - 1}"})
            with urllib.request.urlopen(req, timeout=120) as r: c = r.read()
            if not c: break
            out += c
        self.pos += len(out); return bytes(out)


def fetch_vox(ids):
    out = os.path.join(P.SRC, "voxconverse-audio"); os.makedirs(out, exist_ok=True)
    z = zipfile.ZipFile(RangeFile(P.VOX_ZIP))
    mem = {os.path.basename(i.filename)[:-4]: i for i in z.infolist() if i.filename.endswith(".wav") and "__MACOSX" not in i.filename}
    man = load_manifest("VOXCONVERSE_AUDIO.sha256.txt")
    for f in ids:
        dest = f"{out}/{f}.wav"
        if os.path.exists(dest) and f + ".wav" in man and sha256_file(dest) == man[f + ".wav"]: continue
        with z.open(mem[f]) as s, open(dest + ".part", "wb") as o: shutil.copyfileobj(s, o, 1 << 20)
        got = sha256_file(dest + ".part")   # zipfile also verified the member CRC32 while reading
        if f + ".wav" in man and got != man[f + ".wav"]:
            os.remove(dest + ".part"); raise SystemExit("HASH MISMATCH vox " + f)
        os.replace(dest + ".part", dest)
        if f + ".wav" not in man: record("VOXCONVERSE_AUDIO.sha256.txt", f + ".wav", got, dest)
        log("vox", f, "downloaded")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", required=True)
    ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--vox", nargs="*", default=[])
    ap.add_argument("--record", action="store_true", help="add the hash of a source without one to the committed manifests")
    a = ap.parse_args()
    global RECORD
    RECORD = a.record
    os.makedirs(MAN, exist_ok=True)
    if a.only == "refs":
        clone(*P.AMI_SETUP, os.path.join(P.SRC, "ami-setup")); clone(*P.VOX_ANN, os.path.join(P.SRC, "voxconverse-ann"))
    elif a.only == "ann":
        st, _ = download(P.AMI_ANN_URL, os.path.join(P.SRC, "ann", "ami_public_manual_1.6.2.zip"), P.AMI_ANN_SHA); log("ann", st)
    elif a.only == "ami": fetch_ami(a.jobs)
    elif a.only == "vox": fetch_vox(a.vox)
    elif a.only in ("mls", "vp"):
        # LFS oids come from the HF tree API at the pinned revision (hf_oids.json written by list_hf.py)
        oids = json.load(open(os.path.join(MAN, "hf_oids.json")))
        if a.only == "mls":
            paths = [f"data/mls_spanish/{s}/audio/{t}.tar.gz" for s, ts in P.MLS_TARS.items() for t in ts]
            for s in ("dev", "test"):
                paths += [f"data/mls_spanish/{s}/transcripts.txt", f"data/mls_spanish/{s}/segments.txt"]
            paths += ["data/mls_spanish/LICENSE", "data/mls_spanish/metainfo.txt"]
            fetch_hf(P.MLS, paths, "hf_mls.sha256.txt", os.path.join(P.SRC, "mls"), oids["mls"])
        else:
            fetch_hf(P.VOXPOPULI, ["es/test-00000-of-00001.parquet"], "hf_voxpopuli.sha256.txt", os.path.join(P.SRC, "voxpopuli"), oids["voxpopuli"])
            fetch_hf(P.VOXPOPULI, ["README.md"], "hf_voxpopuli.sha256.txt", os.path.join(P.SRC, "voxpopuli"), {})


if __name__ == "__main__":
    main()
