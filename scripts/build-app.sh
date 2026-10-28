#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# Builds Vauta and assembles build/Vauta.app (App Sandbox + hardened runtime).
# Needs only the Command Line Tools, not Xcode.
#
# Signing, first match wins:
#   VAUTA_SIGN_IDENTITY=<name or SHA-1>  Developer ID Application identity. Optional, for someone with an Apple
#                                       Developer account (Vauta itself is source-only). Signs with a secure
#                                       timestamp (needed for notarization).
#                                       VAUTA_SIGN_KEYCHAIN optionally names the keychain holding it.
#   private signing keychain            the "Vauta Local Code Signing" identity created by
#                                       scripts/setup-signing.sh (stable local builds).
#   VAUTA_ALLOW_ADHOC=1                  ad-hoc; macOS asks for permissions again after each update.
#
# Version:
#   CFBundleShortVersionString  VAUTA_VERSION if set, else the version in the latest tag
#                               (`git describe --tags --always`, "v1.2.3" -> "1.2.3"),
#                               else the value in Resources/Info.plist.
#   CFBundleVersion             number of commits (`git rev-list --count HEAD`),
#                               else the value in Resources/Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/config.sh

fail() { echo "ERROR: $*" >&2; exit 1; }
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" Resources/Info.plist; }

# --- Version -------------------------------------------------------------------------------
# Only trust git when this directory is the repository root (not a tarball inside another repo).
in_repo() { [[ "$(git rev-parse --show-toplevel 2>/dev/null || true)" == "$(pwd -P)" ]]; }
if [[ -n "${VAUTA_VERSION:-}" ]]; then
  VERSION="$VAUTA_VERSION"
else
  VERSION="$(plist_value CFBundleShortVersionString)"
  if in_repo; then
    DESCRIBE="$(git describe --tags --always 2>/dev/null || true)"
    # "v1.2.3", "v1.2.3-4-gabc1234" or "1.2.3"; never a bare commit hash that happens to be all digits.
    if [[ "$DESCRIBE" =~ ^v([0-9]+(\.[0-9]+){0,2})(-|$) || "$DESCRIBE" =~ ^([0-9]+(\.[0-9]+){1,2})(-|$) ]]; then
      VERSION="${BASH_REMATCH[1]}"
    fi
  fi
fi
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "invalid version '$VERSION' (expected 1.2.3)"
BUILD_NUMBER="$(plist_value CFBundleVersion)"
if in_repo; then
  BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo "$BUILD_NUMBER")"
fi
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "invalid build number '$BUILD_NUMBER'"

# --- Signing mode (decided before the slow build so misconfiguration fails fast) -----------
# The "Vauta Local Code Signing" identity lives in a PRIVATE, locked keychain
# (scripts/setup-signing.sh): nobody can sign as Vauta without its password. A stable
# signature lets macOS keep permissions and Keychain access across updates.
KC="$HOME/Library/Keychains/vauta-signing.keychain-db"
IDENTITY_SHA1="$(cat scripts/signing-identity.txt 2>/dev/null || true)"
KEYCHAIN_ARGS=()
TIMESTAMP_ARGS=(--timestamp=none)
if [[ -n "${VAUTA_SIGN_IDENTITY:-}" ]]; then
  MODE="developer-id"
  SIGN="$VAUTA_SIGN_IDENTITY"
  FIND_ARGS=()
  if [[ -n "${VAUTA_SIGN_KEYCHAIN:-}" ]]; then
    [[ -f "$VAUTA_SIGN_KEYCHAIN" ]] || fail "VAUTA_SIGN_KEYCHAIN not found: $VAUTA_SIGN_KEYCHAIN"
    KEYCHAIN_ARGS=(--keychain "$VAUTA_SIGN_KEYCHAIN")
    FIND_ARGS=("$VAUTA_SIGN_KEYCHAIN")
  fi
  # Only a Developer ID Application identity can be notarized and pass Gatekeeper.
  security find-identity -v -p codesigning ${FIND_ARGS[@]+"${FIND_ARGS[@]}"} \
    | grep -iF -- "$VAUTA_SIGN_IDENTITY" | grep -q '"Developer ID Application: ' \
    || fail "VAUTA_SIGN_IDENTITY is not a valid Developer ID Application identity: $VAUTA_SIGN_IDENTITY"
  TIMESTAMP_ARGS=(--timestamp)
elif [[ -f "$KC" && -n "$IDENTITY_SHA1" ]]; then
  MODE="local"
  SIGN="$IDENTITY_SHA1"
  KEYCHAIN_ARGS=(--keychain "$KC")
elif [[ "${VAUTA_ALLOW_ADHOC:-0}" == "1" ]]; then
  MODE="adhoc"
  SIGN="-"
  echo "WARNING: ad-hoc signature (VAUTA_ALLOW_ADHOC=1); macOS will ask for permissions again" >&2
elif [[ -f "$KC" ]]; then
  fail "Vauta's signing keychain is left over from a setup that did not finish. Delete it (security delete-keychain \"$KC\") and run ./scripts/setup-signing.sh again (or set VAUTA_ALLOW_ADHOC=1)"
else
  fail "Vauta's signing keychain is missing. Run ./scripts/setup-signing.sh first (or set VAUTA_SIGN_IDENTITY / VAUTA_ALLOW_ADHOC=1)"
fi

# --- Build ---------------------------------------------------------------------------------
SWIFT_ARGS=(-c release --arch arm64 ${VAUTA_SWIFT_FLAG_ARRAY[@]+"${VAUTA_SWIFT_FLAG_ARRAY[@]}"})
swift build "${SWIFT_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"

APP=build/Vauta.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Vauta" "$APP/Contents/MacOS/Vauta"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] || fail "Resources/AppIcon.icns is missing (swift tools/make-icon.swift)"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Localizations (Resources/<lang>.lproj) and SwiftPM resource bundles, if any.
shopt -s nullglob
LOCALIZATIONS=()
for lproj in Resources/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
  LOCALIZATIONS+=("$(basename "$lproj" .lproj)")
done
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
  # SwiftPM signs resource bundles ad hoc; here they are plain resources sealed by the app's own signature.
  rm -rf "$APP/Contents/Resources/$(basename "$bundle")/Contents/_CodeSignature"
done
shopt -u nullglob
# Speaker-separation models: Core ML folders inside VautaCore's resource bundle, verified by SHA-256 when they load.
MODELS="$APP/Contents/Resources/Vauta_VautaCore.bundle/Contents/Resources/Models"
for model in Segmentation_community1_fp16.mlmodelc WeSpeakerResNet34LM_fp16.mlmodelc; do
  [[ -f "$MODELS/$model/weights/weight.bin" ]] || fail "speaker model $model is missing from the app (Sources/VautaCore/Resources/Models)"
done

# CC BY 4.0 (the speaker models), MIT (MLX) and Apache-2.0 require the notices to travel with the app: NOTICE names the authors,
# the licence and the changes made; LICENSE is Vauta's own.
for notice in NOTICE LICENSE THIRD_PARTY_LICENSES.txt; do
  [[ -f "$notice" ]] || fail "$notice is missing from the repository"
  cp "$notice" "$APP/Contents/Resources/$notice"
done

PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $VAUTA_BUNDLE_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
if [[ ${#LOCALIZATIONS[@]} -gt 0 ]] && ! /usr/libexec/PlistBuddy -c "Print :CFBundleLocalizations" "$PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations array" "$PLIST"
  for lang in "${LOCALIZATIONS[@]}"; do
    /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations: string $lang" "$PLIST"
  done
fi
# Resources/Info.plist lists the supported languages; flag any that has no translation yet
# (it falls back to English) and any translation macOS would not offer.
DECLARED="$(/usr/libexec/PlistBuddy -c "Print :CFBundleLocalizations" "$PLIST" 2>/dev/null | sed -n 's/^ *//; /^[A-Za-z]/p' | grep -v '^Array' || true)"
for lang in $DECLARED; do
  [[ -d "Resources/$lang.lproj" ]] || echo "WARNING: CFBundleLocalizations lists '$lang' but Resources/$lang.lproj is missing (English is shown)" >&2
done
for lang in ${LOCALIZATIONS[@]+"${LOCALIZATIONS[@]}"}; do
  grep -qx -- "$lang" <<< "$DECLARED" || echo "WARNING: Resources/$lang.lproj is not listed in CFBundleLocalizations" >&2
done
plutil -lint -s "$PLIST" || fail "invalid Info.plist in the bundle"

# No symbol table (~1 MB -> ~450 KB, fewer internal names exposed).
strip -rSTx "$APP/Contents/MacOS/Vauta"
# Extended attributes (quarantine, Finder info) make codesign reject the bundle.
xattr -cr "$APP"

# --- Sign ----------------------------------------------------------------------------------
if [[ "$MODE" == "local" ]]; then
  if [[ -t 0 ]]; then
    echo "Password of Vauta's signing keychain (the one you chose in setup-signing.sh, not your Mac's):"
    for try in 1 2 3; do
      security unlock-keychain "$KC" && break
      [[ $try -lt 3 ]] || fail "wrong signing keychain password. If it is lost, delete the keychain (security delete-keychain \"$KC\") and run ./scripts/setup-signing.sh again"
      echo "That is not the signing keychain's password, try again ($((try + 1))/3):"
    done
  fi
  trap 'security lock-keychain "$KC" 2>/dev/null || true' EXIT
fi
# 2-minute cap: with a locked keychain and no terminal, codesign would wait for a dialog forever.
perl -e 'alarm 120; exec @ARGV' codesign --force --options runtime "${TIMESTAMP_ARGS[@]}" \
  ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} \
  --entitlements Resources/Vauta.entitlements --sign "$SIGN" "$APP" \
  || fail "could not sign (signing keychain locked? unlock it: security unlock-keychain ${VAUTA_SIGN_KEYCHAIN:-$KC})"

# --- Verify --------------------------------------------------------------------------------
codesign --verify --strict "$APP"
REQ="$(codesign -d -r- "$APP" 2>&1)"
INFO="$(codesign -dvv "$APP" 2>&1)"
case "$MODE" in
  local)
    LEAF="$(echo "$IDENTITY_SHA1" | tr 'A-F' 'a-f')"
    [[ "$REQ" == *"certificate leaf = H\"$LEAF\""* ]] || fail "unexpected designated requirement"
    ;;
  developer-id)
    [[ "$REQ" == *"anchor apple generic"* && "$REQ" == *"certificate leaf[subject.OU]"* ]] \
      || fail "unexpected designated requirement (not a Developer ID signature)"
    [[ "$INFO" == *"Authority=Developer ID Application: "* ]] || fail "not signed with a Developer ID Application certificate"
    [[ "$INFO" == *$'\n'"Timestamp="* ]] || fail "missing secure timestamp"
    ;;
esac
[[ "$INFO" =~ flags=0x[0-9a-f]+\([^\)]*runtime ]] || fail "hardened runtime is missing"
# The models must pass their pinned SHA-256 and load in the app layout, as signed (offline command, no audio).
"$APP/Contents/MacOS/Vauta" speaker-models || fail "the speaker models do not verify inside the app"
# The GPU kernels (and, with VAUTA_SELFTEST=model, the installed search model) work in the signed, sandboxed, hardened app. A
# failure here is never fixed with an entitlement: AGENTS.md rule 5. Exit 2 (no supported GPU) is not a failure of the build.
if [[ "${VAUTA_SELFTEST:-0}" != "0" ]]; then
  SELFTEST_ARGS=()
  [[ "$VAUTA_SELFTEST" == "model" ]] && SELFTEST_ARGS=(--model)
  set +e
  "$APP/Contents/MacOS/Vauta" mlx-selftest ${SELFTEST_ARGS[@]+"${SELFTEST_ARGS[@]}"}
  SELFTEST_STATUS=$?
  set -e
  [[ $SELFTEST_STATUS == 0 || $SELFTEST_STATUS == 2 ]] || fail "mlx-selftest failed in the app (exit $SELFTEST_STATUS); do not add entitlements, report it"
fi
echo "OK: $APP ($VAUTA_BUNDLE_ID $VERSION ($BUILD_NUMBER), $MODE signature)"
