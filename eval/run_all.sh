#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# Runs the whole evaluation: downloads (pinned and hash-verified), builds the sets, runs the scorer's unit tests,
# diarizes the 18-file set and scores DER, then transcribes the AMI subset and scores WER, then writes minutes for the
# same 10 AMI windows with Apple's on-device model and counts their citations (run_minutes.py). Then the held-out
# sets (eval/heldout/README.md): 8 AMI dev meetings and 11 VoxConverse files that the settings were not tuned on, 12
# synthetic Spanish conversations and 24 call-augmented files (DER), English WER on the AMI dev headsets, and Spanish WER.
#
#   eval/run_all.sh [--skip-fetch] [--skip-wer] [--skip-minutes] [--skip-heldout]
#
# Needs: a release build of the app (swift build -c release --arch arm64), ffmpeg with libopus, git, Python 3 with the
# virtual environment of eval/README.md, about 5 GB of free disk (about 13 GB with the held-out sets), and (for WER) Apple's en-US and es-ES
# speech models installed (`.build/release/Vauta install-speech-assets --locale en-US`, and es-ES); for the minutes, Apple Intelligence turned on. Data goes to $VAUTA_EVAL_WORK (default eval/work).
set -euo pipefail
cd "$(dirname "$0")/.."
HERE="$PWD/eval"
PY="${VAUTA_EVAL_PYTHON:-$HERE/.venv/bin/python}"
[[ -x "$PY" ]] || { echo "ERROR: $PY not found. Create the virtual environment first (see eval/README.md)." >&2; exit 2; }
BIN="${VAUTA_BIN:-$PWD/.build/release/Vauta}"
[[ -x "$BIN" ]] || { echo "ERROR: $BIN not found. Run: swift build -c release --arch arm64" >&2; exit 2; }
command -v ffmpeg >/dev/null || { echo "ERROR: ffmpeg is required (brew install ffmpeg)" >&2; exit 2; }

SKIP_FETCH=0; SKIP_WER=0; SKIP_MINUTES=0; SKIP_HELDOUT=0
for a in "$@"; do
  case "$a" in
    --skip-fetch) SKIP_FETCH=1 ;;
    --skip-wer) SKIP_WER=1 ;;
    --skip-minutes) SKIP_MINUTES=1 ;;
    --skip-heldout) SKIP_HELDOUT=1 ;;
    *) echo "usage: $0 [--skip-fetch] [--skip-wer] [--skip-minutes] [--skip-heldout]" >&2; exit 2 ;;
  esac
done
TAG="${VAUTA_EVAL_TAG:-$(date +%Y%m%d-%H%M%S)}"

"$PY" -I -m unittest discover -s "$HERE/tests"
[[ $SKIP_FETCH -eq 1 ]] || "$PY" -I "$HERE/scripts/fetch.py" --jobs 4
"$PY" -I "$HERE/scripts/build_sets.py"
"$PY" -I "$HERE/scripts/run_diarization.py" --bin "$BIN" --tag "$TAG"
[[ $SKIP_WER -eq 1 ]] || "$PY" -I "$HERE/scripts/run_wer.py" --bin "$BIN" --tag "$TAG"
if [[ $SKIP_MINUTES -eq 0 ]]; then
  # Both tables of docs/BENCHMARKS.md: 3-minute windows (the headline) and 10-minute windows.
  "$PY" -I "$HERE/scripts/run_minutes.py" --bin "$BIN" --tag "$TAG-minutes180" --seconds 180
  "$PY" -I "$HERE/scripts/run_minutes.py" --bin "$BIN" --tag "$TAG-minutes600" --seconds 600
fi
if [[ $SKIP_HELDOUT -eq 0 ]]; then
  # The held-out sets live in their own work directory with their own pins (set names, meetings, files).
  MAIN_WORK="${VAUTA_EVAL_WORK:-$HERE/work}"
  export VAUTA_EVAL_WORK="$MAIN_WORK/heldout" VAUTA_EVAL_PINS="$HERE/heldout/pins_heldout.json"
  S="$HERE/scripts"
  "$PY" -I -c 'import scipy, soundfile, pyarrow' 2>/dev/null || { echo "ERROR: the held-out sets need scipy, soundfile and pyarrow: pip install --only-binary=:all: --require-hashes -r eval/requirements-heldout.txt (or use --skip-heldout)" >&2; exit 2; }
  if [[ $SKIP_FETCH -eq 0 ]]; then
    "$PY" -I "$S/fetch_heldout.py" --only refs
    "$PY" -I "$S/fetch_heldout.py" --only ann
    "$PY" -I "$S/fetch_heldout.py" --only ami --jobs 4
    # shellcheck disable=SC2046
    "$PY" -I "$S/fetch_heldout.py" --only vox --vox $(cat "$HERE/manifests/heldout/vox_selected.txt")
    "$PY" -I "$S/fetch_heldout.py" --only mls
    "$PY" -I "$S/fetch_heldout.py" --only vp
  fi
  "$PY" -I "$S/build_sets.py"
  "$PY" -I "$S/build_es.py"
  "$PY" -I "$S/build_aug.py"
  "$PY" -I "$S/check_heldout_sets.py"
  "$PY" -I "$S/run_diar_sets.py" --bin "$BIN" --tag "$TAG-heldout" --sets ami_dev_others voxconverse_heldout es_conv aug_calls
  if [[ $SKIP_WER -eq 0 ]]; then
    "$PY" -I "$S/run_wer.py" --bin "$BIN" --tag "$TAG-heldout"
    "$PY" -I "$S/run_wer_es.py" --bin "$BIN" --tag "$TAG-heldout" --set es_wer --locale es-ES
  fi
  echo "Held-out results: $VAUTA_EVAL_WORK/runs/$TAG-heldout"
  export VAUTA_EVAL_WORK="$MAIN_WORK"; unset VAUTA_EVAL_PINS
fi
echo "Done. Results: ${VAUTA_EVAL_WORK:-$HERE/work}/runs/$TAG (minutes in $TAG-minutes180 and $TAG-minutes600)"
