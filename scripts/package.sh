#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# OPTIONAL, and not part of the official release: Vauta is distributed as source only. This script is for someone
# (for example a fork) with an Apple Developer account who wants to hand out zip/DMG packages.
#
# Builds the release app and packages it into dist/:
#   Vauta-<version>.zip   the app, zipped with ditto (keeps signature and metadata)
#   Vauta-<version>.dmg   compressed disk image with an /Applications shortcut
#   SHA256SUMS           checksums of both
#
# Environment:
#   VAUTA_SIGN_IDENTITY   Developer ID Application identity (see build-app.sh); also signs the DMG.
#   VAUTA_NOTARY_PROFILE  notarytool keychain profile (see notarize.sh). When set, the app is
#                        notarized and stapled before packaging, and the DMG afterwards.
#   VAUTA_SKIP_BUILD=1    package the existing build/Vauta.app instead of rebuilding it.
# Any other build-app.sh variable (VAUTA_VERSION, VAUTA_ALLOW_ADHOC, …) is passed through.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/legacy-env.sh

fail() { echo "ERROR: $*" >&2; exit 1; }

APP=build/Vauta.app
if [[ "${VAUTA_SKIP_BUILD:-0}" != "1" ]]; then
  ./scripts/build-app.sh
fi
[[ -d "$APP" ]] || fail "$APP not found (run scripts/build-app.sh)"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "unexpected version in $APP: $VERSION"

if [[ -n "${VAUTA_NOTARY_PROFILE:-}" ]]; then
  ./scripts/notarize.sh "$APP"
else
  echo "WARNING: VAUTA_NOTARY_PROFILE is not set: the packages are not notarized and Gatekeeper will block them on other Macs" >&2
fi

DIST=dist
ZIP="$DIST/Vauta-$VERSION.zip"
DMG="$DIST/Vauta-$VERSION.dmg"
mkdir -p "$DIST"
rm -f "$ZIP" "$DMG" "$DIST/SHA256SUMS"

ditto -c -k --keepParent "$APP" "$ZIP"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Vauta.app"
ln -s /Applications "$STAGE/Applications"
# hdiutil occasionally fails with "Resource busy" on busy machines and CI runners: retry.
for attempt in 1 2 3; do
  if hdiutil create -quiet -volname "Vauta" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"; then
    break
  fi
  [[ $attempt -lt 3 ]] || fail "hdiutil could not create $DMG"
  sleep 5
done

if [[ -n "${VAUTA_SIGN_IDENTITY:-}" ]]; then
  KEYCHAIN_ARGS=()
  [[ -n "${VAUTA_SIGN_KEYCHAIN:-}" ]] && KEYCHAIN_ARGS=(--keychain "$VAUTA_SIGN_KEYCHAIN")
  perl -e 'alarm 120; exec @ARGV' codesign --force --timestamp ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} \
    --sign "$VAUTA_SIGN_IDENTITY" "$DMG" || fail "could not sign $DMG"
  codesign --verify --strict "$DMG"
  if [[ -n "${VAUTA_NOTARY_PROFILE:-}" ]]; then
    ./scripts/notarize.sh "$DMG"
  fi
fi

# Checksums last: stapling changes the DMG.
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS)
cat "$DIST/SHA256SUMS"
echo "OK: $ZIP, $DMG and $DIST/SHA256SUMS"
