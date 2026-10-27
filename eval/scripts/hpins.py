# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Pins of the held-out evaluation data (eval/heldout/README.md). Every download is checked against a SHA-256: the
LFS oid of a pinned Hugging Face revision, a pinned zip hash, a pinned git commit, or (AMI audio and VoxConverse wavs,
which have no publisher hash list) a hash recorded in eval/manifests/heldout/ on the first verified download and
checked on every later one."""
import os

from common import EVAL, RUNS, SETS, SR, SRC  # noqa: F401  (re-exported for the held-out scripts)

MANIFESTS = os.path.join(EVAL, "manifests", "heldout")
ROOT = EVAL

AMI_SETUP = ("https://github.com/pyannote/AMI-diarization-setup", "67c2d539286e89f68952d5dcf83912bd9f01dfae")
VOX_ANN = ("https://github.com/joonson/voxconverse", "24bf60be297701cd7e4ef18550c6d390c1b87365")
AMI_ANN_URL = "https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip"
AMI_ANN_SHA = "b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d"
AMI_BASE = "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus"
# Held out: none of these series is in the app's 18-file tuning set (eval/pins.json). They are AMI "dev" split series.
# Caveat: pyannote's own training used AMI, so "unseen by the app", not "unseen by every model".
AMI_MEETINGS = ["ES2011a", "ES2011c", "IS1008a", "IS1008c", "IS1008d", "TS3004a", "TS3004c", "TS3004d"]
VOX_ZIP = "https://www.robots.ox.ac.uk/~vgg/data/voxconverse/data/voxconverse_test_wav.zip"
HF = "https://huggingface.co/datasets/{repo}/resolve/{rev}/{path}"
MLS = ("facebook/multilingual_librispeech", "2e83e61823b4c47dcbcb1980bb88601274127609")
VOXPOPULI = ("facebook/voxpopuli", "42f01879c780b4a2e90ec0b4f616c2ece526e4f1")
# MLS Spanish speaker tarballs (test + dev splits; one speaker/book per tarball). Ids are MLS speaker ids.
MLS_TARS = {
    "test": ["10667_6706_000", "11168_11991_000", "11266_10604_000", "12249_11991_000", "1448_567_000",
             "3468_1378_000", "3503_2162_000", "4096_1378_000", "5691_4369_000", "5870_4006_000",
             "7678_7613_000", "8306_7405_000"],
    "dev": ["1075_567_000", "13257_11991_000", "2308_1378_000", "3796_2162_000", "6223_5079_000", "7331_6706_000"],
}
