# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Download the evaluation sources at pinned revisions and verify every hash.

  python3 -I eval/scripts/fetch.py [--only ami|vox|ann|refs] [--jobs 4]

Everything goes under $VAUTA_EVAL_WORK (default eval/work, git-ignored). A file whose SHA-256 does not match
eval/manifests/*.sha256.txt is deleted and the run fails; nothing unverified is ever used. Nothing is committed.
  - AMI IHM headset audio (40 files, about 2.7 GB) from the official mirror (CC BY 4.0).
  - AMI manual annotations 1.6.2 (zip, SHA-256 pinned): speaker-to-headset map and the word transcripts.
  - pyannote/AMI-diarization-setup and joonson/voxconverse at pinned git commits (reference RTTMs/UEMs).
  - VoxConverse test wavs: 8 members read by HTTP range requests from the official zip (no 4.2 GB download).
"""
import argparse
import io
import os
import shutil
import sys
import time
import urllib.error
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import PINS, SRC, log, read_manifest, run, sha256_file  # noqa: E402

UA = {"User-Agent": "vauta-eval/1 (+https://github.com/MaquinaTech/Vauta)"}


def download(url, dest, sha, size):
    if os.path.exists(dest) and sha256_file(dest) == sha:
        return "cached"
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    part = dest + ".part"
    for attempt in range(1, 7):  # the mirror rate-limits (403/429): wait and try again
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120) as r, open(part, "wb") as f:
                shutil.copyfileobj(r, f, 1 << 20)
            break
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as e:
            if attempt == 6:
                raise
            log(f"{os.path.basename(dest)}: {e}; retry {attempt} in {20 * attempt} s")
            time.sleep(20 * attempt)
    got = sha256_file(part)
    if got != sha:
        os.remove(part)
        raise SystemExit(f"HASH MISMATCH for {url}\n  expected {sha}\n  got      {got}")
    os.replace(part, dest)
    return "downloaded"


def fetch_ami(jobs):
    man = read_manifest("AMI_AUDIO.sha256.txt")
    todo = []
    for m in PINS["ami_meetings"]:
        for c in range(4):
            name = f"{m}.Headset-{c}.wav"
            sha, size, url = man[name]
            todo.append((url, os.path.join(SRC, "ami-audio", m, name), sha, size))
    with ThreadPoolExecutor(jobs) as ex:
        for (url, dest, _, _), status in zip(todo, ex.map(lambda t: download(*t), todo)):
            log(f"ami {os.path.basename(dest)}: {status}")


def fetch_annotations():
    a = PINS["ami_manual_annotations"]
    dest = os.path.join(SRC, "ann", "ami_public_manual_1.6.2.zip")
    log("ami annotations:", download(a["url"], dest, a["sha256"], 0))


def clone(repo, commit, dest):
    if not os.path.isdir(os.path.join(dest, ".git")):
        run(["git", "clone", "--quiet", repo, dest])
    run(["git", "-C", dest, "fetch", "--quiet", "origin", commit])
    run(["git", "-C", dest, "-c", "advice.detachedHead=false", "checkout", "--quiet", commit])
    head = run(["git", "-C", dest, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    if head != commit:
        raise SystemExit(f"{repo}: expected commit {commit}, got {head}")
    log(f"{os.path.basename(dest)} at {head}")


class RangeFile(io.RawIOBase):
    """Read-only seekable file over an HTTP URL (Range requests), so zipfile can pick single members."""

    def __init__(self, url):
        self.url, self.pos = url, 0
        req = urllib.request.Request(url, headers=UA, method="HEAD")
        with urllib.request.urlopen(req, timeout=60) as r:
            self.size = int(r.headers["Content-Length"])
            if "bytes" not in r.headers.get("Accept-Ranges", ""):
                raise SystemExit("the server does not support range requests")

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, off, whence=0):
        self.pos = {0: off, 1: self.pos + off, 2: self.size + off}[whence]
        return self.pos

    def readinto(self, b):
        data = self.read(len(b))
        b[:len(data)] = data
        return len(data)

    def read(self, n=-1):
        if n < 0:
            n = self.size - self.pos
        n = min(n, self.size - self.pos)
        if n <= 0:
            return b""
        out = bytearray()
        while len(out) < n:  # a server may return less than asked
            lo = self.pos + len(out)
            req = urllib.request.Request(self.url, headers={**UA, "Range": f"bytes={lo}-{self.pos + n - 1}"})
            with urllib.request.urlopen(req, timeout=120) as r:
                chunk = r.read()
            if not chunk:
                break
            out += chunk
        self.pos += len(out)
        return bytes(out)


def fetch_vox():
    man = read_manifest("VOXCONVERSE_AUDIO.sha256.txt")
    outdir = os.path.join(SRC, "voxconverse-audio")
    os.makedirs(outdir, exist_ok=True)
    need = [f for f in PINS["voxconverse_files"] if not (os.path.exists(f"{outdir}/{f}.wav") and sha256_file(f"{outdir}/{f}.wav") == man[f + ".wav"][0])]
    if need:
        z = zipfile.ZipFile(RangeFile(PINS["voxconverse_audio_zip"]))
        members = {os.path.basename(i.filename)[:-4]: i for i in z.infolist() if i.filename.endswith(".wav") and "__MACOSX" not in i.filename}
        for f in need:
            dest = f"{outdir}/{f}.wav"
            with z.open(members[f]) as src, open(dest + ".part", "wb") as out:
                shutil.copyfileobj(src, out, 1 << 20)
            if sha256_file(dest + ".part") != man[f + ".wav"][0]:
                os.remove(dest + ".part")
                raise SystemExit(f"HASH MISMATCH for voxconverse {f}.wav")
            os.replace(dest + ".part", dest)
            log(f"vox {f}.wav: downloaded")
    else:
        log("vox: all cached and verified")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=["ami", "vox", "ann", "refs"])
    ap.add_argument("--jobs", type=int, default=4)
    a = ap.parse_args()
    if a.only in (None, "refs"):
        clone(PINS["ami_setup"]["repo"], PINS["ami_setup"]["commit"], os.path.join(SRC, "ami-setup"))
        clone(PINS["voxconverse_annotations"]["repo"], PINS["voxconverse_annotations"]["commit"], os.path.join(SRC, "voxconverse-ann"))
    if a.only in (None, "ann"):
        fetch_annotations()
    if a.only in (None, "vox"):
        fetch_vox()
    if a.only in (None, "ami"):
        fetch_ami(a.jobs)
    log("fetch: OK (every file matches its pinned hash or commit)")


if __name__ == "__main__":
    main()
