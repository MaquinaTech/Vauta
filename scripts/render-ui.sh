#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# Renders the main views to PNG files with invented sample meetings, to review
# the interface without launching the app and to refresh README screenshots.
#
#   scripts/render-ui.sh [out-dir] [--langs "en es ja" | --all-langs] [--scale 2] [--appearance light|dark|both] [--only "guide,settings-models"] [--jobs 8]
#
# Output: <out-dir>/<area>-<state>-<lang>-<appearance>.png (default build/ui-snapshots).
# Each language and appearance renders in its own process, --jobs at a time (default: 9,
# two even waves for 9 languages x 2 appearances); a render mostly waits for views to settle, so they overlap well.
#
# It builds a diagnostics app bundle (VAUTA_DIAGNOSTICS, ad-hoc signed, no sandbox
# entitlements, bundle ID local.vauta.snapshots) OUTSIDE the project, so it never
# shares a container, Keychain item or preferences with a real install. The
# images come from a temporary store with an in-memory key: no real meetings, no
# Keychain, no network, no permission prompt, no audio. The bundle is only
# needed for the translations (the interface language comes from its .lproj folders).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/legacy-env.sh

BUNDLE_ID="local.vauta.snapshots"
OUT="build/ui-snapshots"
LANGS="en es ja"
SCALE=2
APPEARANCE=both
ONLY=""
JOBS=9
while [[ $# -gt 0 ]]; do
  case "$1" in
    --langs) LANGS="$2"; shift 2 ;;
    --all-langs) LANGS="en es fr de it pt-BR ja ko zh-Hans"; shift ;;
    --scale) SCALE="$2"; shift 2 ;;
    --appearance) APPEARANCE="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    -h|--help) sed -n '5,19p' "$0"; exit 0 ;;
    -*) echo "ERROR: unknown option $1" >&2; exit 2 ;;
    *) OUT="$1"; shift ;;
  esac
done

# The diagnostics build also contains the capturing `spike` command: keep it away from the project.
WORK="${VAUTA_SNAPSHOT_BUILD:-${TMPDIR:-/tmp}/vauta-ui-snapshots-build}"
APP="$WORK/Vauta Snapshots.app"
mkdir -p "$WORK"

swift build -c release --arch arm64 --scratch-path "$WORK/swiftpm" -Xswiftc -DVAUTA_DIAGNOSTICS >&2
BIN="$(swift build -c release --arch arm64 --scratch-path "$WORK/swiftpm" -Xswiftc -DVAUTA_DIAGNOSTICS --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Vauta" "$APP/Contents/MacOS/Vauta"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.9.3" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 4" "$PLIST"
xattr -cr "$APP"
# Ad hoc, without the sandbox: the images are written outside any container.
codesign --force --sign - --timestamp=none "$APP" >&2

mkdir -p "$OUT"
case "$APPEARANCE" in
  both) APPEARANCES="light dark" ;;
  *) APPEARANCES="$APPEARANCE" ;;
esac
LOGS="$(mktemp -d "${TMPDIR:-/tmp}/vauta-render-logs.XXXXXX")"
trap 'rm -rf "$LOGS" "$WORK/jobs"' EXIT
export APP OUT SCALE ONLY LOGS BUNDLE_ID WORK VAUTA_RENDER_TIMEOUT
# shellcheck disable=SC2016 # the script runs in the child shell, which expands it
for lang in $LANGS; do
  for appearance in $APPEARANCES; do echo "$lang $appearance"; done
done | xargs -n 2 -P "$JOBS" bash -c '
  set -e
  log="$LOGS/$1-$2.log"
  # Its own copy of the bundle (an APFS clone) under its own bundle ID, so renders
  # running side by side never share preferences.
  job="$WORK/jobs/$1-$2/Vauta Snapshots.app"
  rm -rf "$job"; mkdir -p "$(dirname "$job")"
  cp -cR "$APP" "$job" 2>/dev/null || cp -R "$APP" "$job"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID.$1-$2" "$job/Contents/Info.plist"
  codesign --force --sign - --timestamp=none "$job" 2>/dev/null
  # A subcommand is always given: the binary never starts as a second menu-bar app.
  if perl -e "alarm ${VAUTA_RENDER_TIMEOUT:-900}; exec @ARGV" "$job/Contents/MacOS/Vauta" render-ui "$OUT" --lang "$1" --scale "$SCALE" \
       --appearance "$2" ${ONLY:+--only "$ONLY"} >"$log" 2>&1; then
    echo "Rendered $1 $2: $(tail -n 1 "$log")" >&2
  else
    echo "ERROR: rendering $1 $2 failed:" >&2
    cat "$log" >&2
    exit 1
  fi' _
# An accessibility variant that is byte for byte its base scene proves nothing and only overstates the coverage.
IDENTICAL=0
for variant in "$OUT"/*-increased-contrast-*.png; do
  [ -e "$variant" ] || continue
  base="${variant/-increased-contrast-/-}"
  [ -e "$base" ] || continue
  if cmp -s "$variant" "$base"; then echo "ERROR: $(basename "$variant") is identical to $(basename "$base")" >&2; IDENTICAL=1; fi
done
[ "$IDENTICAL" = 0 ] || exit 1
echo "Done: $OUT"
