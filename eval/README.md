# Evaluation harness

Reproducible measurements of Vauta's speaker separation (diarization error rate, DER) and transcription (word error
rate, WER) on public corpora. The numbers and their limits are in [docs/BENCHMARKS.md](../docs/BENCHMARKS.md). **No audio,
recogniser output or model checkpoint is committed; the only transcripts committed are the public reference texts under
`eval/heldout/` (with their attribution)**: everything downloaded or generated goes to `eval/work/` (git-ignored)
or to the directory named by `VAUTA_EVAL_WORK`. Text only is committed under `eval/heldout/` (references, scored regions, Spanish reference texts with their attribution, results): the held-out English, Spanish and call-impaired sets, described in [heldout/README.md](heldout/README.md).

## What it uses

| Source | Used for | Licence | Pin |
|---|---|---|---|
| AMI Meeting Corpus, IHM headset audio (official mirror, 10 meetings x 4 headsets) | audio | CC BY 4.0 | SHA-256 of each file in `manifests/AMI_AUDIO.sha256.txt` |
| `pyannote/AMI-diarization-setup` (only_words RTTMs, UEMs, split lists) | reference speaker turns | repo Apache-2.0, labels derive from AMI (CC BY 4.0) | git commit in `pins.json` |
| AMI manual annotations 1.6.2 (`ami_public_manual_1.6.2.zip`) | speaker-to-headset map and the manual word transcripts | CC BY 4.0 | SHA-256 in `pins.json` |
| VoxConverse test set (8 wavs, read by HTTP range requests from the official zip) | comparability with published diarization numbers | CC BY 4.0 (copyright stays with the video owners) | SHA-256 of each file in `manifests/VOXCONVERSE_AUDIO.sha256.txt` |
| `joonson/voxconverse` (test RTTMs, corrected labels) | reference speaker turns | CC BY 4.0 | git commit in `pins.json` |

Attribution (CC BY 4.0): AMI Meeting Corpus (Carletta et al.), VoxConverse (Chung et al.). The derived audio built here
(level-normalised, summed, Opus-coded) is an adaptation and must carry the same attribution if you redistribute it; do
not commit it. A download whose hash does not match is deleted and the run stops. The reference RTTMs and UEMs built
from the pins are checked against `manifests/REFERENCES.sha256.txt`.

## Setup

```sh
python3 -m venv eval/.venv                                    # Python 3.12 or later (numpy 2.5.3 requires it)
eval/.venv/bin/pip install --only-binary=:all: --require-hashes -r eval/requirements.txt   # numpy only, pinned by hash; everything else is the standard library
brew install ffmpeg                                      # libopus is needed to simulate the conferencing codec
swift build -c release --arch arm64
.build/release/Vauta install-speech-assets --locale en-US   # Apple's model, for WER
```

## Run

```sh
eval/run_all.sh                       # downloads (about 2.8 GB, plus about 4 GB for the held-out sets), builds the sets, diarizes, scores DER, transcribes, scores WER; --skip-heldout leaves the held-out sets out
```

or step by step (each script says what it does at the top):

```sh
eval/.venv/bin/python -I eval/scripts/fetch.py [--only ami|vox|ann|refs] [--jobs 4]
eval/.venv/bin/python -I eval/scripts/build_sets.py
eval/.venv/bin/python -I eval/scripts/run_diarization.py --bin .build/release/Vauta [--tag name] [--threshold 0.70]
eval/.venv/bin/python -I eval/scripts/run_wer.py --bin .build/release/Vauta [--locale en-US]
eval/.venv/bin/python -I eval/scripts/check_doc_tables.py <run dir>                                               # the per-file tables of docs/BENCHMARKS.md equal the run's (run it after editing them)
eval/.venv/bin/python -I eval/scripts/compare_runs.py --sets-dir <sets> --before <run dir> --after <run dir>                  # paired DER comparison of two runs (pooled, per-file change, bootstrap interval); --sets-dir eval/heldout/sets for the held-out groups, the main harness's $VAUTA_EVAL_WORK/sets for the tuning_set group
eval/.venv/bin/python -I eval/scripts/overlap_shares.py <run dir> [<run dir> ...]   # share of each speaker's time that another speaker also covers (the voice-recognition gate)
eval/.venv/bin/python -I eval/scripts/score_der.py --ref <rttm dir> --hyp <rttm dir> [--uem <uem dir>]   # score any diarizer
eval/.venv/bin/python -I -m unittest discover -s eval/tests                                              # scorer tests, and those of tools/llm-eval/stats.py (that file alone needs no numpy)
eval/.venv/bin/python -I eval/scripts/run_minutes.py --bin .build/release/Vauta --seconds 180 [--tag name]   # minutes for the 10 AMI windows (3-minute headline; --seconds 600 for the 10-minute table) (Apple's on-device model), then the citation checks below
eval/.venv/bin/python -I eval/scripts/score_minutes.py --minutes m.json --transcript t.json                       # citation checks on minutes of a PUBLIC transcript (rubric: eval/rubric/)
```

`Vauta diarize` and `Vauta transcribe-file` are offline evaluation commands: they read one file, never contact a network
and never write audio. `run_wer.py` uses `transcribe-file --show-text --i-understand` on a **public** corpus; never do
that with a real meeting (see [AGENTS.md](../AGENTS.md)).

Results land in `$VAUTA_EVAL_WORK/runs/<tag>/`: the RTTMs, `timings_*.json`, `der_*.md`, `summary.json`, `wer.json`, `wer.md`.

## The scorers

`score_der.py` is independent of the app and of pyannote (standard library and numpy). It works on a 10 ms grid in the NIST
form (miss, false alarm and confusion in frames, with the Hungarian one-to-one speaker mapping), scores overlap, and
reports DER with and without the 0.25 s collar. It was cross-checked once (10 October 2026) against
pyannote.metrics 4.1 and a second frame-based scorer on the same engine output: the per-file figures agree to 0.1 point (see
BENCHMARKS.md). Those cross-check scripts are not committed, so the harness does not reproduce that check.
`score_wer.py` documents its text normalisation at the top of the file. `run_wer.py` mutes the audio outside the scored speakers' reference turns before transcribing ("oracle masking", explained at the top of the script) and also reports the unmasked figure.

## Limits

The 18-file tuning set is English only (the held-out sets add Spanish: read speech and synthetic conversations, no real meeting); simulated conferencing codec (Opus), not real calls; close-talk headsets, easier than a speakerphone in a room;
headsets contain faint cross-talk, which is why a second UEM ("no-bleed") is reported next to the plain one; no real Spanish or
other-language meeting set (no suitably licensed one was found; see BENCHMARKS.md).
