#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# Regenerates the English source table, Resources/en.lproj/Localizable.strings, from the code.
# Needs only the Command Line Tools (no Xcode, genstrings or xcstringstool).
#
# The Swift compiler does the extraction: built with -emit-localized-strings, it writes a
# .stringsdata file per source file with every string that reaches a localizable API
# (Text("…"), Button("…"), .help("…"), LocalizedStringResource, String(localized:comment:)…),
# with interpolations turned into format specifiers ("\(count) meetings" -> "%lld meetings")
# and the translator comments from the code. tools/stringsdata-to-strings.swift then merges
# them into Localizable.strings, leaving out the plural keys of Localizable.stringsdict.
#
#   scripts/extract-strings.sh
#
# It builds from scratch in .build/strings (about a minute) so every file is compiled and
# no stale string survives. Then run scripts/check-strings.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/legacy-env.sh

SCRATCH=.build/strings
OUT="$SCRATCH/stringsdata"
rm -rf "$SCRATCH"
mkdir -p "$OUT"

echo "Compiling to collect localizable strings…"
if ! swift build -j "${VAUTA_JOBS:-3}" --scratch-path "$SCRATCH" \
     -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/$OUT" \
     >"$SCRATCH/build.log" 2>&1; then
  tail -30 "$SCRATCH/build.log" >&2
  echo "ERROR: the build failed (full log: $SCRATCH/build.log)" >&2
  exit 1
fi

swift tools/stringsdata-to-strings.swift "$SCRATCH" Resources/en.lproj
plutil -lint -s Resources/en.lproj/Localizable.strings
