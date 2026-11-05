#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# Writes the two files that let Settings › General › Update… start an update from inside the App Sandbox, in
# ~/Library/Application Scripts/<bundle ID>/ (install.sh runs it after installing):
#
#   update-vauta          fixed text: opens "Update Vauta.command" in Terminal. Vauta runs it with no arguments.
#   Update Vauta.command  goes to this checkout and runs scripts/update.sh with this install's bundle ID and signing method.
#
# macOS lets Vauta run and read the scripts in that folder but never create or change them, so the app can start this one
# update and nothing else. update.sh then verifies the release tag's signature, shows the release notes and asks before it
# builds, tests and installs. Vauta itself checks both files before it runs them (Sources/VautaCore/Updates/UpdateLauncher.swift)
# and refuses anything that is not exactly what this script writes.
#
#   scripts/install-update-launcher.sh            (VAUTA_BUNDLE_ID and the signing variables as for install.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/config.sh

fail() { echo "ERROR: $*" >&2; exit 1; }

CHECKOUT="$(pwd -P)"
# Single-quoted in the command file, so a quote, a newline or a control character could change what it runs: refused, byte by
# byte (LC_ALL=C: bytes below 0x20 and 0x7F), the same rule Vauta applies when it reads the file back.
safe_value() { local LC_ALL=C; [[ "$1" != *"'"* && ! "$1" =~ [[:cntrl:]] ]]; }
safe_value "$CHECKOUT" || fail "the path of this folder contains a quote or a control character; move it to use Update… in Vauta"
[[ -x scripts/update.sh ]] || fail "scripts/update.sh is missing"

DIR="$HOME/Library/Application Scripts/$VAUTA_BUNDLE_ID"
mkdir -p "$DIR"
# Vauta refuses a folder or a file that anyone else can write to.
chmod go-w "$DIR"

LAUNCHER_TEXT='#!/bin/sh
# vauta-update-launcher 1
# Written by Vauta'"'"'s scripts/install.sh (again at each install). Vauta runs it, with no arguments, when you click Update…;
# macOS lets Vauta run the scripts in this folder but not change them. It opens Update Vauta.command in Terminal, where
# scripts/update.sh verifies the release'"'"'s signature before anything is built or installed.
exec /usr/bin/open -a /System/Applications/Utilities/Terminal.app "${0%/*}/Update Vauta.command"
'

rm -f "$DIR/.command.tmp" "$DIR/.launcher.tmp"
{
  echo '#!/bin/bash'
  echo '# vauta-update-command 1'
  echo "# Written by Vauta's scripts/install.sh (again at each install): the Vauta checkout to update and how it was built."
  echo "cd '$CHECKOUT' || exit 1"
  echo "export VAUTA_BUNDLE_ID='$VAUTA_BUNDLE_ID'"
  # The signing method install.sh was run with, so the update is signed the same way (local.env is read by update.sh too).
  for name in VAUTA_ALLOW_ADHOC VAUTA_SIGN_IDENTITY VAUTA_SIGN_KEYCHAIN; do
    value="${!name:-}"
    [[ -n "$value" ]] || continue
    safe_value "$value" || fail "$name contains a quote or a control character"
    if [[ "$name" == VAUTA_ALLOW_ADHOC && "$value" != 1 ]]; then continue; fi
    echo "export $name='$value'"
  done
  echo './scripts/update.sh'
  echo 'echo'
  echo 'read -r -p "Press Return to close this window. " _'
} > "$DIR/.command.tmp"
printf '%s' "$LAUNCHER_TEXT" > "$DIR/.launcher.tmp"

# Owner only (read, write, run), then moved into place: a half-written file is never run.
chmod 0700 "$DIR/.command.tmp" "$DIR/.launcher.tmp"
mv -f "$DIR/.command.tmp" "$DIR/Update Vauta.command"
mv -f "$DIR/.launcher.tmp" "$DIR/update-vauta"
echo "Update… in Vauta's Settings › General will update this checkout ($CHECKOUT)."
