#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# Puts an app bundle in place so that a failure at any point leaves a working app there: the new copy is made next to the
# installed one (.Vauta.app.staging), its signature is checked, and only then the two are swapped with two renames on the same
# volume; the previous app is removed once the new one is in place, and put back if the swap fails. A run that was cut between
# the two renames is finished by the next one, which first puts the previous app back.
#
#   scripts/install-app.sh build/Vauta.app ~/Applications/Vauta.app
set -euo pipefail

SRC="${1:?usage: install-app.sh <new app> <installed app>}"
SRC="${SRC%/}"
DEST="${2:?usage: install-app.sh <new app> <installed app>}"
DEST="${DEST%/}"
DIR="$(dirname "$DEST")"
NAME="$(basename "$DEST")"
STAGING="$DIR/.$NAME.staging"
PREVIOUS="$DIR/.$NAME.previous"

fail() { echo "ERROR: $*" >&2; exit 1; }

mkdir -p "$DIR"
# A run cut between the two renames left the previous app aside: it goes back first.
if [[ ! -e "$DEST" && -d "$PREVIOUS" ]]; then
  mv "$PREVIOUS" "$DEST"
  echo "Put back the app that an interrupted install had set aside."
fi
# Leftovers of an interrupted copy are never the installed app.
rm -rf "$STAGING" "$PREVIOUS"

if ! cp -R "$SRC" "$STAGING"; then
  rm -rf "$STAGING"
  fail "could not copy the new app next to $DEST (is the disk full?). The installed app was not changed."
fi
if ! codesign --verify --strict "$STAGING"; then
  rm -rf "$STAGING"
  fail "the copy of the new app does not verify. The installed app was not changed."
fi
if [[ -e "$DEST" ]]; then
  mv "$DEST" "$PREVIOUS" || { rm -rf "$STAGING"; fail "could not set the installed app aside. It was not changed."; }
fi
if ! mv "$STAGING" "$DEST"; then
  if [[ -e "$PREVIOUS" ]]; then mv "$PREVIOUS" "$DEST"; fi
  rm -rf "$STAGING"
  fail "could not put the new app in place. The installed app was put back."
fi
rm -rf "$PREVIOUS"
