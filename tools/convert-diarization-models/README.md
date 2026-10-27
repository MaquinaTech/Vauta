# convert-diarization-models

Dev-only tool that makes the two Core ML models Vauta bundles for speaker separation. The app never runs it
and nothing here is built into Vauta. The results are committed as compiled models in
`Sources/VautaCore/Resources/Models/`:

| Folder | Model | Size |
|---|---|---|
| `Segmentation_community1_fp16.mlmodelc` | pyannote community-1 powerset segmentation, 10 s window | 2.9 MiB |
| `WeSpeakerResNet34LM_fp16.mlmodelc` | WeSpeaker ResNet34-LM masked embedding, 3 masks per window | 12.9 MiB |

Both are CC BY 4.0 (see `NOTICE`). **Never commit a weights checkpoint** (`pytorch_model.bin` and similar); only the
converted `.mlmodelc` folders. The checkpoints are not in this repository and must never be.

## What is pinned

`convert.py` refuses a checkpoint whose SHA-256 differs from the constants at its top. There is no flag to skip or
change that check.

| | Source | Revision | Checkpoint SHA-256 |
|---|---|---|---|
| Segmentation | `pyannote/speaker-diarization-community-1`, `segmentation/pytorch_model.bin` (gated) | `3533c8cf8e369892e6b79ff1bf80f7b0286a54ee` | `7ad24338d844fb95985486eb1a464e32d229f6d7a03c9abe60f978bacf3f816e` |
| Embedding | `pyannote/wespeaker-voxceleb-resnet34-LM`, `pytorch_model.bin` (public) | `837717ddb9ff5507820346191109dc79c958d614` | `366edf44f4c80889a3eb7a9d7bdf02c4aede3127f7dd15e274dcdb826b143c56` |

The converter writes the source repo, revision, checkpoint hash, licence (CC-BY-4.0), the modification statement
(a short statement, "Converted to Core ML; no changes to weights other than FP16 conversion."; the complete list of
changes is in `NOTICE`) and a Vauta model ID into each model's metadata. The model IDs are what `voice_profiles.model_id` stores later.

## Steps (macOS, Python 3.12, no Xcode needed)

```sh
cd tools/convert-diarization-models
python3 -m venv /tmp/vauta-convert-venv
/tmp/vauta-convert-venv/bin/python -I -m pip install -r requirements.txt

# 1. Embedding model. Put the three pinned files of the WeSpeaker repo in ./src_wespeaker (ignored by git: do not
#    commit it), or let the script fetch them from the pinned revision with --download (public, no token).
/tmp/vauta-convert-venv/bin/python -I convert.py embedding --src-dir src_wespeaker --download

# 2. Segmentation model. The weights are gated on Hugging Face: accept the conditions on
#    huggingface.co/pyannote/speaker-diarization-community-1 with your own account, download
#    segmentation/pytorch_model.bin yourself, then:
/tmp/vauta-convert-venv/bin/python -I convert.py segmentation --checkpoint /path/to/pytorch_model.bin
```

Both commands write the compiled `.mlmodelc` into `Sources/VautaCore/Resources/Models/` and print its **tree
SHA-256**. That is a SHA-256 over every file of the folder (path and content, in path order); Swift computes the same
value in `DiarizationModels.treeHash(of:)`. Paste the printed values into `DiarizationModels.segmentationPin` and
`embeddingPin`; `swift test` fails until they match the folders.

Conversion is not byte-reproducible (the metadata carries the conversion date and the tool versions), so a rebuilt
model has a new tree hash. The committed folders and the constants are the source of truth. The FP16 weights files
(`weights/weight.bin`) do reproduce bit for bit: `1d57dd73...` (segmentation) and `55fab57c...` (embedding).

## Why compiled `.mlmodelc`, committed

* Nothing is compiled by Vauta on a user's Mac. (Core ML itself compiles the loaded model for the Neural Engine into
  its own cache in the app's Caches folder; that derived copy holds no meeting data and is not covered by the hash.)
* The files handed to Core ML are exactly the files whose hash is pinned and checked (`DiarizationModels.verified`).
  A compile-at-launch design would load a freshly compiled copy in a writable folder whose bytes depend on the OS
  version, so the pinned hash could not cover it.
* Compiled models are produced here with `coremltools` (`ct.utils.compile_model`); no `coremlcompiler` or Xcode is needed.

## Test fixtures

`export_fixtures.py` writes `Tests/VautaCoreTests/Fixtures/Diarization` (about 0.7 MB): a 12 s AMI excerpt (CC BY 4.0), the
NumPy fbank of its first window, references from pyannote.audio's own PyTorch classes (segmentation classes and
embeddings for three overlapping windows) and a scipy-derived AHC fixture. It needs pyannote.audio 4.0.7 in a
separate environment (`pip install pyannote.audio==4.0.7`), both checkpoints, and a 16 kHz mono 16-bit WAV; see the
header of the script. The references never come from the Core ML models under test.

## Files

| File | Purpose |
|---|---|
| `convert.py` | the converter (pinned hashes, Core ML FP16, compile, tree hash) |
| `safe_load.py` | allow-listed unpickler: checkpoints are read without executing any code |
| `reference_fbank.py` | NumPy statement of the Kaldi fbank (the spec the Swift `Fbank` is tested against) |
| `export_fixtures.py` | the test fixtures |
| `requirements.txt` | pinned converter environment |
