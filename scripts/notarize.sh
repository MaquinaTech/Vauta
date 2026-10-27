#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# OPTIONAL, and not part of the official release: Vauta is distributed as source only. This script is only for
# someone with an Apple Developer account (for example a fork that ships binaries).
#
# Notarizes a Developer ID signed Vauta.app or .dmg with Apple, staples the ticket and
# checks the result with Gatekeeper.
#
#   VAUTA_NOTARY_PROFILE=vauta-notary ./scripts/notarize.sh build/Vauta.app
#   VAUTA_NOTARY_PROFILE=vauta-notary ./scripts/notarize.sh dist/Vauta-1.2.3.dmg
#
# VAUTA_NOTARY_PROFILE names notarytool credentials stored in a keychain beforehand, e.g.
# with an App Store Connect API key:
#   xcrun notarytool store-credentials vauta-notary --key AuthKey_XXXX.p8 --key-id XXXX --issuer <uuid>
# VAUTA_NOTARY_KEYCHAIN optionally names the keychain holding that profile (used by CI).
set -euo pipefail
source "$(dirname "$0")/legacy-env.sh"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ $# -eq 1 ]] || fail "usage: VAUTA_NOTARY_PROFILE=<profile> $0 <Vauta.app|Vauta.dmg>"
TARGET="${1%/}"
[[ -e "$TARGET" ]] || fail "not found: $TARGET"
[[ -n "${VAUTA_NOTARY_PROFILE:-}" ]] || fail "VAUTA_NOTARY_PROFILE is not set. Store notarization credentials first:
  xcrun notarytool store-credentials <profile> --key AuthKey_XXXX.p8 --key-id <key id> --issuer <issuer id>
then run: VAUTA_NOTARY_PROFILE=<profile> $0 $TARGET"
xcrun --find notarytool >/dev/null 2>&1 || fail "notarytool not found (install the Xcode Command Line Tools)"

NOTARY_ARGS=(--keychain-profile "$VAUTA_NOTARY_PROFILE")
if [[ -n "${VAUTA_NOTARY_KEYCHAIN:-}" ]]; then
  NOTARY_ARGS+=(--keychain "$VAUTA_NOTARY_KEYCHAIN")
fi

# Notarization only accepts Developer ID signatures with a secure timestamp.
SIGNATURE="$(codesign -dvv "$TARGET" 2>&1)" || fail "$TARGET is not signed"
[[ "$SIGNATURE" == *"Authority=Developer ID Application: "* ]] \
  || fail "$TARGET is not signed with a Developer ID Application certificate (set VAUTA_SIGN_IDENTITY when building)"
[[ "$SIGNATURE" == *$'\n'"Timestamp="* ]] || fail "$TARGET has no secure timestamp"

case "$TARGET" in
  *.app)
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    SUBMISSION="$WORK/$(basename "$TARGET" .app).zip"
    ditto -c -k --keepParent "$TARGET" "$SUBMISSION"
    ASSESS=(spctl --assess --type execute -vv "$TARGET")
    ;;
  *.dmg)
    SUBMISSION="$TARGET"
    ASSESS=(spctl --assess --type open --context context:primary-signature -vv "$TARGET")
    ;;
  *) fail "expected an .app or a .dmg (a .zip cannot be stapled; notarize the .app before zipping it)" ;;
esac

echo "Submitting $(basename "$TARGET") for notarization (this usually takes a few minutes)…"
OUTPUT="$(xcrun notarytool submit "$SUBMISSION" "${NOTARY_ARGS[@]}" --wait 2>&1)" || true
echo "$OUTPUT"
if [[ "$OUTPUT" != *"status: Accepted"* ]]; then
  ID="$(echo "$OUTPUT" | sed -n 's/^ *id: //p' | head -1)"
  [[ -n "$ID" ]] && xcrun notarytool log "$ID" "${NOTARY_ARGS[@]}" || true
  fail "notarization of $TARGET was not accepted"
fi

xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
"${ASSESS[@]}" || fail "Gatekeeper rejects $TARGET"
echo "OK: $TARGET is notarized and stapled"
