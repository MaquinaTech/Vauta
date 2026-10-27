# Held-out evaluation sets

Sets that the speaker-separation settings were **not** tuned on, plus the Spanish and call-augmented sets. The
numbers are in [docs/BENCHMARKS.md](../../docs/BENCHMARKS.md). The 18-file tuning set of the main harness
([../README.md](../README.md)) stays as it is; these sets exist so that a change can be checked on audio the settings
never saw.

**No audio is committed.** This directory holds text only: the reference turns (`rttm/`), the scored regions
(`uem*/`), `info.json` (how each file was built, the utterance ids), the Spanish reference texts (`es_wer/ref/`, with
[their attribution](sets/es_wer/ATTRIBUTION.md)), the results before and after the diarization change (`results/`) and `pins_heldout.json`.
The audio is rebuilt by the scripts from pinned sources, and `scripts/check_heldout_sets.py` compares the result with
`manifests/heldout/SETS_MANIFEST.sha256.txt`.

## Sets

| Set | Content | Licence |
|---|---|---|
| `ami_dev_others` | 8 AMI meetings of the dev split (ES2011 a and c, IS1008 a, c and d, TS3004 a, c and d), built like the main harness (one participant removed as "me", the other three summed and Opus-coded); 600 s headset clips for WER | CC BY 4.0 (AMI); references from `pyannote/AMI-diarization-setup` @ `67c2d539` |
| `voxconverse_heldout` | 11 VoxConverse test recordings not used by the main harness (2 to 12 speakers, 4 to 12 min); ids in `manifests/heldout/vox_selected.txt` | annotations CC BY 4.0 (`joonson/voxconverse` @ `24bf60be`); **the audio copyright stays with the video owners: never redistribute it** |
| `es_wer` | 35.6 min of Spanish: 4 x 5 min VoxPopuli parliament speech and 3 x 5 min MLS audiobooks, utterances joined with 0.5 s gaps, exact reference texts | VoxPopuli CC0-1.0; MLS CC BY 4.0 |
| `es_conv` | 12 **synthetic** Spanish conversations of 2 to 6 speakers, 9 to 15 min, exact RTTM, Opus-coded; speaker pools of MLS and of VoxPopuli are never mixed in one conversation | derived from the two above: CC BY 4.0 (attribute MLS / Meta AI) |
| `aug_calls` | 8 clean files (3 AMI, 3 `es_conv`, 2 VoxConverse) x 3 call profiles (wideband VoIP, PSTN narrowband, poor mobile) with noise, AGC, packet loss and jitter gaps; `uem_nodrop` leaves out the muted regions | derived: CC BY 4.0 |

Attribution (CC BY 4.0): AMI Meeting Corpus (Carletta et al.), VoxConverse (Chung et al.), Multilingual LibriSpeech
(Pratap et al., Meta AI), VoxPopuli (Wang et al., Meta AI, CC0). Derived audio is an adaptation and must carry the
same attribution if you redistribute it (do not redistribute the VoxConverse part).

## Pins

Hugging Face files are checked against the LFS oid of the pinned revision (`manifests/heldout/hf_*.sha256.txt`,
`hf_oids.json`); git repositories by commit; the AMI annotations zip by SHA-256. AMI audio and VoxConverse wavs have no
publisher hash list: their SHA-256 was recorded on the first download (`AMI_AUDIO.sha256.txt`,
`VOXCONVERSE_AUDIO.sha256.txt`, trust on first use; sizes checked against Content-Length, zip members against CRC-32).
A mismatch deletes the file and stops the run. The fetch scripts never change these manifests unless run with `--record`.

## Run

`eval/run_all.sh` does all of it (unless `--skip-heldout`). Step by step, with `VAUTA_EVAL_WORK` set to a directory
of its own (for example `eval/work/heldout`) and `VAUTA_EVAL_PINS=eval/heldout/pins_heldout.json`:

```sh
eval/.venv/bin/pip install --only-binary=:all: --require-hashes -r eval/requirements-heldout.txt   # numpy, scipy, soundfile, pyarrow
P="eval/.venv/bin/python -I eval/scripts"
$P/fetch_heldout.py --only refs; $P/fetch_heldout.py --only ann; $P/fetch_heldout.py --only ami --jobs 4
$P/fetch_heldout.py --only vox --vox $(cat eval/manifests/heldout/vox_selected.txt); $P/fetch_heldout.py --only mls; $P/fetch_heldout.py --only vp
$P/build_sets.py; $P/build_es.py; $P/build_aug.py; $P/check_heldout_sets.py
$P/run_diar_sets.py --bin .build/release/Vauta --tag t --sets ami_dev_others voxconverse_heldout es_conv aug_calls
$P/run_wer.py --bin .build/release/Vauta --tag t                      # English, AMI dev
$P/run_wer_es.py --bin .build/release/Vauta --tag t --set es_wer --locale es-ES
```

Download size: about 4 GB in all (about 2.8 GB for AMI, 0.5 GB for the VoxConverse zip members read by range request, 1 GB for the Spanish
sources); the built sets take about 1.7 GB, and about 8 GB of disk are in use while they are built (the same figures as in
`docs/BENCHMARKS.md` and `eval/run_all.sh`). Needs Apple's `en-US` and `es-ES` speech models for WER.

## Limits

- **Held out for the app, not for every model.** None of these files is in the 18-file tuning set, but the diarization
  models were trained by others on AMI (train split) and on VoxConverse dev; whether AMI dev was used for their
  validation is unverified.
- **`es_conv` is synthetic.** Read and parliament speech, turn-taking from a Markov model, overlap of 3 to 13 % of
  speech (AMI has about 10 to 20 %), no backchannels, speaker pools recorded in different rooms. Separating its
  speakers is probably easier than on a real Spanish meeting. The RTTM is the energy-VAD interval of each placed
  utterance: exact for the construction, not human-annotated.
- **`aug_calls` are simulations** (crude concealment, synthetic noise). The RTTM is unchanged, so muted regions count
  as miss under `uem`; use `uem_nodrop`.
- **Small and homogeneous.** Every AMI file has exactly 3 remote speakers; the dev scenarios share the tuning set's
  recording protocol. English is the only language with human-annotated meeting audio here; there is no real Spanish
  meeting set.
- **Spanish WER** is read and parliament speech, not conversation. MLS texts use some pre-reform spellings, hence the
  accent-folded figure next to the strict one.
