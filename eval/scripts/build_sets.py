# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Build the evaluation sets from the verified downloads (run fetch.py first). Deterministic.

  python3 -I eval/scripts/build_sets.py

Outputs under $VAUTA_EVAL_WORK/sets:
  ami_others/   audio/<m>_others.wav  rttm/<m>_others.rttm  uem/<m>_others.uem  uem_nobleed/<m>_others.uem  info.json
                headset/<m>_headset.wav  (the first wer_seconds of the raw headset of the most talkative speaker, for WER)
  voxconverse/  audio/<id>.wav  rttm/<id>.rttm   (the original audio and references; no UEM)

The "others" set imitates the remote side of a call, which is what the app diarizes as the Others channel
(Me is the user's own microphone and is never separated by the app):
 1. "me" = one participant, chosen by meeting index mod 4 over descending talk time (chatty and quiet "me" both occur).
 2. Every headset is gain-normalised to RMS 0.05 over that speaker's own reference-speech samples (gain capped +30 dB).
 3. The remote headsets (everyone except "me") are summed, peak-limited to 0.9.
 4. The sum goes through ffmpeg libopus (voip, VBR), alternating by meeting index: even = 24 kbps with a 48 kHz internal
    rate, odd = 16 kbps with a 16 kHz internal rate, then is decoded to 16 kHz mono. This simulates a conferencing codec;
    it is not a recording of a real call (no packet loss, jitter, AGC or room acoustics).
 5. References: the AMI only_words RTTM without the "me" speaker. UEM = 0 to the shorter of the AMI UEM end and the audio.
    The "no-bleed" UEM also excludes the time when only "me" (or nobody of the remote speakers) speaks over the
    headsets' cross-talk, because a diarizer rightly hears the faint "me" bleed that the reference of the remote side lacks.
"""
import json
import os
import subprocess
import sys
import shutil
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np  # noqa: E402
from common import PINS, SETS, SR, SRC, log, read_wav, sha256_file, write_wav  # noqa: E402

AMI_SET = PINS.get("ami_set", "ami_others")      # the held-out pins name their sets differently
VOX_SET = PINS.get("vox_set", "voxconverse")

SETUP = f"{SRC}/ami-setup/only_words"
split_of = {}


def mk(*p):
    path = os.path.join(SETS, *p)
    os.makedirs(path, exist_ok=True)
    return path


def read_rttm_rows(path):
    rows = []
    for line in open(path):
        x = line.split()
        if x:
            rows.append((float(x[3]), float(x[4]), x[7]))
    return rows


def write_rttm(path, uri, rows):
    with open(path, "w") as f:
        for s, d, spk in sorted(rows):
            f.write(f"SPEAKER {uri} 1 {s:.3f} {d:.3f} <NA> <NA> {spk} <NA> <NA>\n")


def union(intervals):
    out = []
    for a, b in sorted(intervals):
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out


def subtract(base, cut):
    """base minus cut, both lists of disjoint sorted [a, b]."""
    out = []
    for a, b in base:
        cur = a
        for c, d in cut:
            if d <= cur or c >= b:
                continue
            if c > cur:
                out.append([cur, c])
            cur = max(cur, d)
        if cur < b:
            out.append([cur, b])
    return out


def active_gain(x, rows, target=0.05):
    m = np.zeros(len(x), bool)
    for s, d, _ in rows:
        m[int(s * SR):int((s + d) * SR)] = True
    r = np.sqrt(np.mean(x[m] ** 2)) if m.any() else np.sqrt(np.mean(x ** 2))
    return min(target / max(r, 1e-6), 31.6)


def opus(x, idx, tmp):
    br, ar = ("24k", "48000") if idx % 2 == 0 else ("16k", "16000")
    w, o, b = tmp + ".wav", tmp + ".opus", tmp + ".dec.wav"
    write_wav(w, x)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", w, "-ac", "1", "-ar", ar, "-c:a", "libopus", "-b:a", br,
                    "-application", "voip", "-vbr", "on", o], check=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", o, "-ac", "1", "-ar", str(SR), b], check=True)
    y, sr = read_wav(b)
    assert sr == SR
    for f in (w, o, b):
        os.remove(f)
    return y, f"opus {br} internal-rate {int(ar) // 1000}k"


def main():
    if shutil.which("ffmpeg") is None:
        raise SystemExit("ffmpeg with libopus is required (brew install ffmpeg)")
    for s in ("test", "dev", "train"):
        for m in open(f"{SRC}/ami-setup/lists/{s}.meetings.txt").read().split():
            split_of[m] = s
    chan = {}
    with zipfile.ZipFile(f"{SRC}/ann/ami_public_manual_1.6.2.zip") as zf:
        meetings_xml = zf.read("corpusResources/meetings.xml")
    for mt in ET.fromstring(meetings_xml).iter("meeting"):
        chan[mt.get("observation")] = {s.get("global_name"): int(s.get("channel")) for s in mt.iter("speaker")}
    tmpd = mk("tmp")
    info_all = {}
    for idx, m in enumerate(PINS["ami_meetings"]):
        rows = read_rttm_rows(f"{SETUP}/rttms/{split_of[m]}/{m}.rttm")
        uem = open(f"{SRC}/ami-setup/uems/{split_of[m]}/{m}.uem").read().split()
        end = float(uem[3])
        talk = {}
        for s, d, spk in rows:
            talk[spk] = talk.get(spk, 0) + d
        order = sorted(talk, key=lambda k: (-talk[k], k))
        me = order[idx % 4]
        remote = [s for s in order if s != me]
        heads = []
        for c in range(4):
            x, sr = read_wav(f"{SRC}/ami-audio/{m}/{m}.Headset-{c}.wav")
            assert sr == SR, sr
            heads.append(x)
        n = min(int(end * SR), *[len(h) for h in heads])
        sig = {}
        for spk in order:
            x = heads[chan[m][spk]][:n]
            sig[spk] = x * active_gain(x, [r for r in rows if r[2] == spk])
        mix = sum(sig[s] for s in remote)
        pk = np.abs(mix).max()
        if pk > 0.9:
            mix = mix * 0.9 / pk
        mix, codec = opus(mix.astype(np.float32), idx, os.path.join(tmpd, m))
        dur = n / SR
        uri = f"{m}_others"
        write_wav(os.path.join(mk(AMI_SET, "audio"), uri + ".wav"), mix)
        # WER clean condition: the raw headset (no gain, no codec) of whoever talks most in the first wer_seconds.
        win = PINS["wer_seconds"]
        wtalk = {}
        for s0, d0, spk in rows:
            if s0 < win:
                wtalk[spk] = wtalk.get(spk, 0) + min(d0, win - s0)
        top = sorted(wtalk, key=lambda k: (-wtalk[k], k))[0]
        write_wav(os.path.join(mk(AMI_SET, "headset"), f"{m}_headset.wav"), heads[chan[m][top]][:int(win * SR)])
        rrows = [r for r in rows if r[2] in remote and r[0] < dur]
        write_rttm(os.path.join(mk(AMI_SET, "rttm"), uri + ".rttm"), uri, rrows)
        open(os.path.join(mk(AMI_SET, "uem"), uri + ".uem"), "w").write(f"{uri} 1 0.000 {dur:.3f}\n")
        # No-bleed UEM: drop time when a non-remote headset speaks and no remote speaker does.
        remote_u = union([(s, s + d) for s, d, _ in rrows])
        other_u = union([(s, s + d) for s, d, spk in rows if spk not in remote])
        bleed = subtract(other_u, remote_u)
        keep = subtract([[0.0, dur]], bleed)
        with open(os.path.join(mk(AMI_SET, "uem_nobleed"), uri + ".uem"), "w") as f:
            for a, b in keep:
                f.write(f"{uri} 1 {a:.3f} {b:.3f}\n")
        info_all[uri] = dict(headset_speaker=top, meeting=m, split=split_of[m], me_speaker=me, me_talk_rank=order.index(me) + 1, remote=remote,
                             codec=codec, duration=dur, scored_seconds_nobleed=sum(b - a for a, b in keep))
        log(m, codec, "me =", me, "remote =", remote, f"{dur:.0f} s")
    json.dump(info_all, open(os.path.join(SETS, AMI_SET, "info.json"), "w"), indent=1)
    shutil.rmtree(tmpd, ignore_errors=True)

    # VoxConverse: original audio and reference RTTMs.
    for f in PINS["voxconverse_files"]:
        shutil.copyfile(f"{SRC}/voxconverse-audio/{f}.wav", os.path.join(mk(VOX_SET, "audio"), f + ".wav"))
        shutil.copyfile(f"{SRC}/voxconverse-ann/test/{f}.rttm", os.path.join(mk(VOX_SET, "rttm"), f + ".rttm"))

    # Reference check: the RTTMs and UEMs are plain text and deterministic, so they have a committed hash list.
    man = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       PINS.get("references_manifest", "manifests/REFERENCES.sha256.txt"))
    lines = []
    for sub in (f"{AMI_SET}/rttm", f"{AMI_SET}/uem", f"{AMI_SET}/uem_nobleed", f"{VOX_SET}/rttm"):
        for fn in sorted(os.listdir(os.path.join(SETS, sub))):
            lines.append(f"{sha256_file(os.path.join(SETS, sub, fn))}  {sub}/{fn}\n")
    if os.path.exists(man):
        want = open(man).readlines()
        if want != lines:
            bad = sorted(set(want) ^ set(lines))
            raise SystemExit("reference files differ from manifests/REFERENCES.sha256.txt:\n" + "".join(bad[:10]))
        log("references: all", len(lines), "files match manifests/REFERENCES.sha256.txt")
    else:
        open(os.path.join(SETS, "REFERENCES.sha256.txt"), "w").writelines(lines)
        log("no committed reference manifest; wrote", os.path.join(SETS, "REFERENCES.sha256.txt"))


if __name__ == "__main__":
    main()
