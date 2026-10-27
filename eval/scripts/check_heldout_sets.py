# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Compare the built held-out sets with eval/manifests/heldout/SETS_MANIFEST.sha256.txt.

  python3 -I eval/scripts/check_heldout_sets.py [--sets-dir DIR] [--strict]

References, UEMs, info files and Spanish texts are deterministic text: any difference is an error. The audio is
deterministic given the same ffmpeg/libopus build; a different build can change the bytes, so an audio difference is a
warning unless --strict is given. Missing files are errors."""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import EVAL, SETS, sha256_file  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sets-dir", default=SETS)
    ap.add_argument("--strict", action="store_true")
    a = ap.parse_args()
    bad_text, bad_audio, missing, ok = [], [], [], 0
    for line in open(os.path.join(EVAL, "manifests", "heldout", "SETS_MANIFEST.sha256.txt")):
        parts = line.split()
        if len(parts) != 2:
            continue
        sha, rel = parts[0], parts[1].removeprefix("./")
        path = os.path.join(a.sets_dir, rel)
        if rel.startswith("REFERENCES.sha256.txt"):
            continue
        if not os.path.exists(path):
            missing.append(rel)
        elif sha256_file(path) != sha:
            (bad_audio if rel.endswith(".wav") else bad_text).append(rel)
        else:
            ok += 1
    print(f"held-out sets: {ok} files match; {len(missing)} missing; {len(bad_text)} text differ; {len(bad_audio)} audio differ")
    for rel in missing + bad_text + bad_audio:
        print("  ", rel)
    if missing or bad_text or (bad_audio and a.strict):
        sys.exit(1)


if __name__ == "__main__":
    main()
