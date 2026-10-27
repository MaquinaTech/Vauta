#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# Memory bound of speaker separation on a long recording, with the real models. A stub analyzer in a unit test cannot
# catch the leak this guards against (Core ML temporaries piling up in a long analysis loop, about 0.5 MB per second
# of audio), so run this on any change to Sources/VautaCore/Diarization:
#
#   swift build -c release --arch arm64
#   scripts/check-diarize-memory.sh <audio file of 30 minutes or more> [max MB, default 250]
#
# It runs `Vauta diarize` (read-only: it prints who speaks when, never text, and writes no audio) and fails when the
# peak resident memory of the process is above the limit. Use your own recording or any public meeting audio; the
# file is only read.
set -euo pipefail
cd "$(dirname "$0")/.."

AUDIO="${1:-}"
LIMIT_MB="${2:-250}"
BIN=".build/release/Vauta"
[[ -n "$AUDIO" && -f "$AUDIO" ]] || { echo "usage: $0 <audio file of 30 minutes or more> [max MB]" >&2; exit 2; }
[[ -x "$BIN" ]] || { echo "$BIN is missing: swift build -c release --arch arm64" >&2; exit 2; }

REPORT="$(mktemp)"
RTTM="$(mktemp)"
trap 'rm -f "$REPORT" "$RTTM"' EXIT
/usr/bin/time -l "$BIN" diarize "$AUDIO" --rttm "$RTTM" 2> "$REPORT" || { cat "$REPORT" >&2; exit 1; }
SUMMARY="$(grep -E 'speakers ·' "$REPORT" || true)"
RSS_BYTES="$(awk '/maximum resident set size/ { print $1 }' "$REPORT")"
[[ -n "$RSS_BYTES" ]] || { echo "could not read the peak memory" >&2; exit 1; }
RSS_MB=$((RSS_BYTES / 1048576))
echo "${SUMMARY:-diarize finished} · peak resident memory ${RSS_MB} MB (limit ${LIMIT_MB} MB)"
if (( RSS_MB > LIMIT_MB )); then
  echo "FAIL: peak memory ${RSS_MB} MB is above ${LIMIT_MB} MB" >&2
  exit 1
fi
