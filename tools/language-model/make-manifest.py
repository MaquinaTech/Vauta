#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Derives Vauta's language-model manifest from Google's original file, in ONE streaming pass (see docs/LANGUAGE_MODEL.md).

usage: make-manifest.py --out-dir DIR [--source-file PATH] [--reference PATH] [--workers 4] [--block-size 67108864]

Streams google/gemma-4-E4B-it@ee0ef602 model.safetensors (16 GB, never stored) with HTTP Range, and in that single pass:
  * hashes the whole file (must equal the LFS oid), the header, every 64 MiB block of the language-model span and every
    source tensor;
  * quantises each language_model tensor to 4-bit affine (group 64) with the numpy port of Vauta's CPU algorithm
    (affine_quant.py), writing the output tensors at their final offsets of DIR/vauta.safetensors;
  * compares every quantised chunk with mx.quantize on the GPU and on the CPU (mlx 0.32.3) and counts the differences;
  * hashes every output tensor and the assembled file, and compares them with an mlx-community reference conversion.
It writes DIR/manifest.json. Developer-side only: never run against user data, never shipped.
"""
import argparse, concurrent.futures as cf, hashlib, http.client, json, os, struct, sys, threading, time, urllib.parse, urllib.request
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import affine_quant as aq

REPO = "google/gemma-4-E4B-it"
REV = "ee0ef6023621cff504d758262d4e04895a5af4a2"
SRC_FILE = "model.safetensors"
SRC_SIZE = 15992595884
SRC_SHA = "cfbd3d2f1cd71bd471c37fe2bf8546d5028d41e5736f64e1ca6c6b8893125503"
CDN_HOSTS = {"us.aws.cdn.hf.co"}
SMALL_FILES = ["tokenizer.json", "config.json", "chat_template.jinja", "generation_config.json", "LICENSE", "README.md"]
CHUNK_BYTES = 16 << 20
PREFIX_SRC = "model.language_model."
PREFIX_OUT = "language_model.model."
DTYPE_BYTES = {"BF16": 2, "F32": 4, "U32": 4, "F16": 2}


def canonical_header(entries, fmt="mlx"):
    """entries: {name: (dtype, shape, start, end)}. Same writer as SearchModelSpec.headerBytes."""
    items = [(n, '{"data_offsets":[%d,%d],"dtype":"%s","shape":[%s]}' % (s, e, d, ",".join(map(str, sh))))
             for n, (d, sh, s, e) in entries.items()]
    items.append(("__metadata__", '{"format":"%s"}' % fmt))
    items.sort(key=lambda kv: kv[0].encode())
    body = ("{" + ",".join('"%s":%s' % kv for kv in items) + "}").encode()
    while len(body) % 8:
        body += b" "
    return struct.pack("<Q", len(body)) + body


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


class Source:
    """Range reads from Hugging Face (resolved through the 302 with the CDN host allowlist) or from a local file."""

    def __init__(self, path=None):
        self.path = path
        self.url = None
        self.lock = threading.Lock()
        self.opener = urllib.request.build_opener(NoRedirect)

    def resolve(self, name=SRC_FILE):
        req = urllib.request.Request(f"https://huggingface.co/{REPO}/resolve/{REV}/{name}", headers={"Range": "bytes=0-0", "Accept-Encoding": "identity"})
        try:
            self.opener.open(req, timeout=60)
            raise RuntimeError("expected a 302")
        except urllib.error.HTTPError as e:
            if e.code != 302:
                raise
            h = e.headers
            if h.get("X-Repo-Commit") != REV:
                raise RuntimeError("revision pin mismatch")
            if name == SRC_FILE and (h.get("X-Linked-Size") != str(SRC_SIZE) or h.get("X-Linked-Etag", "").strip('"') != SRC_SHA):
                raise RuntimeError("size/etag pin mismatch")
            loc = urllib.parse.urlparse(h["Location"])
            if loc.scheme != "https" or loc.hostname not in CDN_HOSTS or (loc.port not in (None, 443)):
                raise RuntimeError("CDN host not allowed: %s" % loc.hostname)
            return h["Location"]

    def read(self, start, end, name=SRC_FILE):
        """Bytes [start, end) of the file."""
        if self.path:
            with open(self.path, "rb") as f:
                f.seek(start)
                b = f.read(end - start)
            if len(b) != end - start:
                raise RuntimeError("short local read")
            return b
        last = None
        for attempt in range(10):
            try:
                with self.lock:
                    if self.url is None:
                        self.url = self.resolve(name)
                    url = self.url
                req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end - 1}", "Accept-Encoding": "identity"})
                with self.opener.open(req, timeout=90) as r:
                    if r.status != 206 or r.headers.get("Content-Range") != f"bytes {start}-{end - 1}/{SRC_SIZE}":
                        raise RuntimeError("bad range answer %s %s" % (r.status, r.headers.get("Content-Range")))
                    buf = bytearray()
                    while len(buf) < end - start:
                        c = r.read(min(1 << 20, end - start - len(buf)))
                        if not c:
                            break
                        buf += c
                if len(buf) != end - start:
                    raise RuntimeError("short body")
                return bytes(buf)
            except Exception as e:  # noqa
                last = e
                with self.lock:
                    self.url = None
                time.sleep(min(30, 2 * (attempt + 1)))
        raise RuntimeError("range %d-%d failed: %r" % (start, end, last))

    def fetch_whole(self, name):
        """A small file at the pinned revision (tokenizer.json etc.). 307 to a path of the same host and the 302 to the CDN
        allowlist are followed; anything else is an error."""
        url = f"https://huggingface.co/{REPO}/resolve/{REV}/{name}"
        meta = {}
        for _ in range(4):
            req = urllib.request.Request(url, headers={"Accept-Encoding": "identity"})
            try:
                with self.opener.open(req, timeout=300) as r:
                    return r.read(), meta
            except urllib.error.HTTPError as e:
                if e.code not in (302, 307):
                    raise
                for k in ("X-Linked-Etag", "x-linked-etag"):
                    if e.headers.get(k):
                        meta["X-Linked-Etag"] = e.headers[k]
                loc = e.headers["Location"]
                if loc.startswith("/"):
                    url = "https://huggingface.co" + loc
                    continue
                u = urllib.parse.urlparse(loc)
                if u.scheme != "https" or u.hostname not in CDN_HOSTS:
                    raise RuntimeError("redirect host not allowed: %s" % u.hostname)
                url = loc
        raise RuntimeError("too many redirects")


def sha(b):
    return hashlib.sha256(b).hexdigest()


class Quantizer:
    """Runs (a) numpy port, (b) mx GPU, (c) mx CPU on a chunk; counts differences; returns the (a) arrays."""

    def __init__(self):
        import mlx.core as mx
        self.mx = mx
        self.lock = threading.Lock()
        self.stats = {"chunks": 0, "gpu_word_diff": 0, "gpu_scale_diff": 0, "gpu_bias_diff": 0, "cpu_word_diff": 0, "cpu_scale_diff": 0,
                      "cpu_bias_diff": 0, "words": 0, "groups": 0}

    def run(self, bits, cols):
        ours = aq.quantize_rows(bits, cols)
        mx = self.mx
        with self.lock:
            a = mx.array(bits).view(mx.bfloat16)
            res = {}
            for dn, dev in (("gpu", mx.gpu), ("cpu", mx.cpu)):
                with mx.stream(dev):
                    w, s, b = mx.quantize(a, group_size=64, bits=4, mode="affine")
                    mx.eval(w, s, b)
                res[dn] = (np.array(w), np.array(s.view(mx.uint16)), np.array(b.view(mx.uint16)))
            st = self.stats
            st["chunks"] += 1
            st["words"] += ours[0].size
            st["groups"] += ours[1].size
            for dn in ("gpu", "cpu"):
                st[dn + "_word_diff"] += int((ours[0] != res[dn][0]).sum())
                st[dn + "_scale_diff"] += int((ours[1] != res[dn][1]).sum())
                st[dn + "_bias_diff"] += int((ours[2] != res[dn][2]).sum())
        return ours


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--source-file")
    ap.add_argument("--reference")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--block-size", type=int, default=64 << 20)
    ap.add_argument("--no-pin-check", action="store_true", help="tests with a small synthetic file")
    a = ap.parse_args()
    os.makedirs(a.out_dir, exist_ok=True)
    src = Source(a.source_file)
    t0 = time.time()

    # 1. Small files
    small = {}
    if not a.source_file:
        for n in SMALL_FILES:
            try:
                data, hdrs = src.fetch_whole(n)
            except urllib.error.HTTPError as e:
                small[n] = {"unavailable": e.code}
                print("small", n, small[n], flush=True)
                continue
            small[n] = {"size": len(data), "sha256": sha(data), "linkedEtag": (hdrs.get("X-Linked-Etag") or hdrs.get("x-linked-etag") or "").strip('"')}
            if n == "README.md":
                # The licence is stated in the model card's front matter (there is no LICENSE file at the pinned revision).
                front = data.decode("utf-8", "replace").split("---")[1] if data.startswith(b"---") else ""
                for line in front.splitlines():
                    if line.startswith("license:"): small[n]["license"] = line.split(":", 1)[1].strip()
                    if line.startswith("license_link:"): small[n]["licenseLink"] = line.split(":", 1)[1].strip()
            if n == "tokenizer.json":
                open(os.path.join(a.out_dir, "tokenizer.json"), "wb").write(data)
            print("small", n, small[n], flush=True)

    # 2. Header
    head8 = src.read(0, 8)
    hlen = struct.unpack("<Q", head8)[0]
    header_raw = src.read(0, 8 + hlen)
    header_sha = sha(header_raw)
    hjson = json.loads(header_raw[8:])
    data0 = 8 + hlen
    src_tensors = []
    for name, m in hjson.items():
        if name == "__metadata__":
            continue
        if name.startswith(PREFIX_SRC):
            src_tensors.append((m["data_offsets"][0] + data0, m["data_offsets"][1] + data0, name, m["dtype"], m["shape"]))
    src_tensors.sort()
    assert all(t[3] == "BF16" for t in src_tensors), "non-BF16 language tensor"
    span_start, span_end = src_tensors[0][0], src_tensors[-1][1]
    cur = span_start
    for s, e, n, d, sh in src_tensors:
        assert s == cur, "gap in span at " + n
        assert e - s == 2 * int(np.prod(sh)), "size mismatch " + n
        cur = e
    foreign = [n for n, m in hjson.items() if n != "__metadata__" and not n.startswith(PREFIX_SRC) and span_start < m["data_offsets"][0] + data0 < span_end]
    assert not foreign, "foreign tensors inside the span"
    file_size = SRC_SIZE if not a.source_file else os.path.getsize(a.source_file)
    print(f"header {hlen}, {len(src_tensors)} language tensors, span [{span_start},{span_end}) = {span_end - span_start}", flush=True)

    # 3. Output layout
    drop_layers = int(os.environ.get("VAUTA_FIRST_SHARED_LAYER", "24"))

    def dropped(name):
        if ".layers." not in name:
            return False
        idx = int(name.split(".layers.")[1].split(".")[0])
        rest = name.split(".layers.")[1].split(".", 1)[1]
        return idx >= drop_layers and (rest.startswith("self_attn.k_proj") or rest.startswith("self_attn.v_proj") or rest.startswith("self_attn.k_norm"))

    plan = {}  # src name -> dict
    out_entries = {}  # out name -> (dtype, shape)
    for s, e, n, d, sh in src_tensors:
        base = PREFIX_OUT + n[len(PREFIX_SRC):]
        if dropped(n):
            plan[n] = {"kind": "drop"}
        elif len(sh) == 2 and sh[1] % 64 == 0 and n.endswith(".weight"):
            stem = base[: -len(".weight")]
            plan[n] = {"kind": "quantize", "stem": stem, "rows": sh[0], "cols": sh[1]}
            out_entries[stem + ".weight"] = ("U32", [sh[0], sh[1] // 8])
            out_entries[stem + ".scales"] = ("BF16", [sh[0], sh[1] // 64])
            out_entries[stem + ".biases"] = ("BF16", [sh[0], sh[1] // 64])
        else:
            plan[n] = {"kind": "copy", "out": base}
            out_entries[base] = ("BF16", list(sh))
    layout = {}
    cur = 0
    for n in sorted(out_entries, key=lambda x: x.encode()):
        d, sh = out_entries[n]
        size = DTYPE_BYTES[d] * int(np.prod(sh))
        layout[n] = (d, sh, cur, cur + size)
        cur += size
    out_header = canonical_header(layout)
    out_data_size = cur
    out_total = len(out_header) + out_data_size
    print(f"outputs {len(layout)} tensors, data {out_data_size} B, assembled {out_total} B", flush=True)
    out_path = os.path.join(a.out_dir, "vauta.safetensors")
    fd = os.open(out_path, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o600)
    os.ftruncate(fd, out_total)
    os.pwrite(fd, out_header, 0)
    base_off = len(out_header)

    # 4. Pieces: head, span blocks, tail
    BS = a.block_size
    pieces = []
    p = 0
    while p < span_start:
        q = min(span_start, p + BS)
        pieces.append(("head", p, q))
        p = q
    nblocks = (span_end - span_start + BS - 1) // BS
    for i in range(nblocks):
        pieces.append(("block", span_start + i * BS, min(span_end, span_start + (i + 1) * BS)))
    p = span_end
    while p < file_size:
        q = min(file_size, p + BS)
        pieces.append(("tail", p, q))
        p = q

    quant = Quantizer()
    pool = cf.ThreadPoolExecutor(max_workers=6)
    jobs = []
    jobs_lock = threading.Lock()
    src_sha = {}
    whole = hashlib.sha256()
    block_hashes = []
    cur_block = hashlib.sha256()
    chunk_state = {}  # tensor name -> (rows_done)
    pending_bytes = bytearray()  # bytes of the current chunk being assembled
    tensor_hash = {}
    out_written = {}
    done_chunks = {}

    # per-tensor iteration state
    ti = 0
    tensor_pos = {}  # name -> bytes consumed
    tensor_list = src_tensors

    def row_chunk(sh):
        if len(sh) != 2:
            return None
        rowb = sh[1] * 2
        return max(1, min(sh[0], CHUNK_BYTES // rowb))

    def submit_chunk(name, row0, rows, raw):
        pl = plan[name]

        def job():
            if pl["kind"] == "quantize":
                bits = np.frombuffer(raw, dtype=np.uint16).reshape(rows, pl["cols"])
                w, s, b = quant.run(bits, pl["cols"])
                stem = pl["stem"]
                for suf, arr in ((".weight", w), (".scales", s), (".biases", b)):
                    d, sh, o0, o1 = layout[stem + suf]
                    rowbytes = (o1 - o0) // sh[0]
                    os.pwrite(fd, np.ascontiguousarray(arr).tobytes(), base_off + o0 + row0 * rowbytes)
            else:
                d, sh, o0, o1 = layout[pl["out"]]
                rowbytes = (o1 - o0) // sh[0] if len(sh) == 2 else 0
                os.pwrite(fd, raw, base_off + o0 + row0 * rowbytes)
            return name

        with jobs_lock:
            jobs.append(pool.submit(job))

    # fetch in order with a bounded read-ahead
    results = {}
    fetch_pool = cf.ThreadPoolExecutor(max_workers=a.workers)
    ahead = a.workers * 2
    futs = {}
    next_submit = 0

    def fetch(i):
        k, s, e = pieces[i]
        return src.read(s, e)

    cur_tensor = 0
    t_start = tensor_list[0][0]
    asm = {"name": None}
    consumed_total = 0
    for i in range(len(pieces)):
        while next_submit < len(pieces) and next_submit < i + ahead:
            futs[next_submit] = fetch_pool.submit(fetch, next_submit)
            next_submit += 1
        kind, s, e = pieces[i]
        data = futs.pop(i).result()
        assert len(data) == e - s
        whole.update(data)
        if kind == "block":
            cur_block = hashlib.sha256(data)
            block_hashes.append(cur_block.hexdigest())
            # feed tensors
            mv = memoryview(data)
            pos = s
            while pos < e:
                ts, te, tn, td, tsh = tensor_list[cur_tensor]
                take = min(e, te) - pos
                chunk = mv[pos - s: pos - s + take]
                if tn not in tensor_pos:
                    tensor_pos[tn] = 0
                    tensor_hash[tn] = hashlib.sha256()
                    asm["buf"] = bytearray()
                    rc = row_chunk(tsh) if plan[tn]["kind"] != "drop" else None
                    asm["rowchunk"] = rc
                    asm["row"] = 0
                tensor_hash[tn].update(chunk)
                if plan[tn]["kind"] != "drop":
                    buf = asm["buf"]
                    buf += chunk
                    rc = asm["rowchunk"]
                    rowb = tsh[1] * 2 if len(tsh) == 2 else None
                    if rc is None:
                        if pos + take == te:
                            submit_chunk(tn, 0, 1, bytes(buf))
                            asm["buf"] = bytearray()
                    else:
                        while len(asm["buf"]) >= rc * rowb:
                            raw = bytes(asm["buf"][: rc * rowb])
                            del asm["buf"][: rc * rowb]
                            submit_chunk(tn, asm["row"], rc, raw)
                            asm["row"] += rc
                        if pos + take == te and len(asm["buf"]) > 0:
                            rem = len(asm["buf"]) // rowb
                            submit_chunk(tn, asm["row"], rem, bytes(asm["buf"]))
                            asm["buf"] = bytearray()
                pos += take
                tensor_pos[tn] += take
                if pos == te:
                    src_sha[tn] = tensor_hash.pop(tn).hexdigest()
                    cur_tensor += 1
                    if cur_tensor >= len(tensor_list):
                        break
            # bound memory: wait when too many jobs are queued
            with jobs_lock:
                pend = [j for j in jobs if not j.done()]
                jobs[:] = pend
            while len(pend) > 12:
                pend[0].result()
                pend = [j for j in pend if not j.done()]
        if i % 10 == 0 or i == len(pieces) - 1:
            el = time.time() - t0
            done = e
            print(f"piece {i + 1}/{len(pieces)} {done / 1e9:.2f} GB, {el:.0f}s, {done / max(el, 1) / 1e6:.1f} MB/s, jobs {len(jobs)}", flush=True)
    for j in jobs:
        j.result()
    pool.shutdown()
    fetch_pool.shutdown()
    file_sha = whole.hexdigest()
    print("whole-file sha256", file_sha, flush=True)
    if not a.no_pin_check:
        assert file_sha == SRC_SHA, "whole-file hash differs from the LFS oid"
    assert cur_tensor == len(tensor_list)
    os.fsync(fd)

    # 5. Output hashes
    out_tensors = []
    for n in sorted(layout, key=lambda x: x.encode()):
        d, sh, o0, o1 = layout[n]
        h = hashlib.sha256()
        pos = o0
        while pos < o1:
            q = min(o1, pos + (64 << 20))
            h.update(os.pread(fd, q - pos, base_off + pos))
            pos = q
        out_tensors.append({"name": n, "dtype": d, "shape": sh, "offset": o0, "size": o1 - o0, "sha256": h.hexdigest()})
    asm_h = hashlib.sha256()
    pos = 0
    while pos < out_total:
        q = min(out_total, pos + (64 << 20))
        asm_h.update(os.pread(fd, q - pos, pos))
        pos = q
    os.close(fd)

    # 6. Reference comparison
    ref_report = None
    if a.reference:
        with open(a.reference, "rb") as f:
            n = struct.unpack("<Q", f.read(8))[0]
            rh = json.loads(f.read(n))
            rbase = 8 + n
            same, diff, missing, extra = 0, [], [], 0
            ours = {t["name"]: t for t in out_tensors}
            for t in out_tensors:
                r = rh.get(t["name"])
                if r is None:
                    missing.append(t["name"])
                    continue
                f.seek(rbase + r["data_offsets"][0])
                rd = f.read(r["data_offsets"][1] - r["data_offsets"][0])
                if sha(rd) == t["sha256"]:
                    same += 1
                else:
                    diff.append(t["name"])
            extra = len([k for k in rh if k.startswith("language_model.") and k not in ours])
            ref_report = {"identical": same, "different": diff[:50], "differentCount": len(diff), "missingInReference": missing, "extraInReference": extra}
            print("reference comparison", {k: (v if k != "different" else len(diff)) for k, v in ref_report.items()}, flush=True)

    manifest = {
        "repository": REPO, "revision": REV, "sourceFile": SRC_FILE, "sourceSize": file_size, "sourceSHA256": file_sha,
        "sourceHeaderSize": 8 + hlen, "sourceHeaderSHA256": header_sha,
        "spanStart": span_start, "spanEnd": span_end, "blockSize": BS, "blocks": block_hashes,
        "tensors": [{"name": n, "dtype": d, "shape": sh, "offset": s - span_start, "size": e - s, "sha256": src_sha[n],
                     "action": plan[n]["kind"]} for s, e, n, d, sh in src_tensors],
        "outputHeaderSize": len(out_header), "outputHeaderSHA256": sha(out_header),
        "outputs": out_tensors, "assembledSize": out_total, "assembledSHA256": asm_h.hexdigest(),
        "small": small, "quantizerStats": quant.stats, "reference": ref_report,
        "firstSharedLayer": drop_layers, "elapsedSeconds": round(time.time() - t0),
    }
    with open(os.path.join(a.out_dir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    print("assembled sha256", manifest["assembledSHA256"], out_total, "stats", quant.stats, flush=True)


if __name__ == "__main__":
    main()
