#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# Builds Vauta, installs it in ~/Applications (no sudo) and opens it in the menu bar.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/config.sh
# What the build needs, before it starts (and how many jobs this Mac's memory takes): see scripts/preflight.sh.
source scripts/preflight.sh
vauta_preflight || exit 1
./scripts/build-app.sh

APP_BIN="$HOME/Applications/Vauta.app/Contents/MacOS/Vauta"
# The same app installed under the earlier version's name (Acta.app) with this bundle ID: it shares the
# container, so it is quit like Vauta and, once Vauta is installed, moved to the Trash (it
# would no longer find its files, and as a login item it would start again on its own).
LEGACY_APP="$HOME/Applications/Acta.app"
LEGACY_BIN="$LEGACY_APP/Contents/MacOS/Acta"
legacy_same_id() {
  [[ -d "$LEGACY_APP" && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LEGACY_APP/Contents/Info.plist" 2>/dev/null)" == "$VAUTA_BUNDLE_ID" ]]
}
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
if [[ -d ~/Applications/Vauta.app && "$(cdhash build/Vauta.app)" == "$(cdhash ~/Applications/Vauta.app)" ]]; then
  # Opening a running app only brings it forward; a quit one starts again, as the user expects from install.sh.
  echo "Vauta is already installed with this exact build: nothing to install. Opening it."
  open ~/Applications/Vauta.app
  exit 0
fi

# PIDs of the installed menu-bar app. Launch Services registers only the GUI app, never
# command-line runs of the same binary (e.g. `Vauta install-speech-assets` while it downloads),
# so those are never asked to quit or signalled.
app_pids() {
  local pid
  for pid in $(pgrep -f "$APP_BIN" || true) $(pgrep -f "$LEGACY_BIN" || true); do
    if lsappinfo info -only bundleID "$pid" 2>/dev/null | grep -qF "\"$VAUTA_BUNDLE_ID\""; then
      echo "$pid"
    fi
  done
}
wait_for_exit() {
  for _ in $(seq 1 50); do
    [[ -z "$(app_pids)" ]] && return 0
    sleep 0.2
  done
  return 1
}

# Graceful quit: the app ends the recording and saves the encrypted store before exiting.
if [[ -n "$(app_pids)" ]]; then
  osascript -e "tell application id \"$VAUTA_BUNDLE_ID\" to quit" 2>/dev/null || true
  if ! wait_for_exit; then
    PIDS="$(app_pids)"
    # shellcheck disable=SC2086  # one PID per word
    [[ -n "$PIDS" ]] && kill -TERM $PIDS 2>/dev/null || true
    wait_for_exit || true
  fi
  # Never two instances at once: they would overwrite each other's encrypted store.
  if [[ -n "$(app_pids)" ]]; then
    echo "ERROR: Vauta is still running (finishing a recording?). Quit it and run this again." >&2
    exit 1
  fi
fi
# Command-line runs are never signalled, but some open the same encrypted store
# (`Vauta store-stats`), and an unregistered GUI app would also land here: refuse instead of
# starting a second process on that store.
if pgrep -f "$APP_BIN" >/dev/null; then
  echo "ERROR: a command-line run of the installed Vauta is still active (pids: $(pgrep -f "$APP_BIN" | tr '\n' ' ')). Wait for it to finish and run this again." >&2
  exit 1
fi
if legacy_same_id && pgrep -f "$LEGACY_BIN" >/dev/null; then
  echo "ERROR: the earlier version of the app (same bundle ID) is still running (pids: $(pgrep -f "$LEGACY_BIN" | tr '\n' ' ')). Quit it and run this again." >&2
  exit 1
fi

# The new copy is made and verified next to the installed app, then the two are swapped: a failure at any point (a full
# disk, Ctrl-C) leaves a working app in ~/Applications.
scripts/install-app.sh build/Vauta.app ~/Applications/Vauta.app
if legacy_same_id; then
  # The Trash folder may be protected (Full Disk Access): then Finder moves it there (macOS may ask to let Terminal
  # control Finder). A failure is only a warning: Vauta is already installed.
  TRASHED="$HOME/.Trash/Acta $(date +%Y%m%d-%H%M%S).app"
  if mv "$LEGACY_APP" "$TRASHED" 2>/dev/null \
    || osascript -e "tell application \"Finder\" to delete POSIX file \"$LEGACY_APP\"" >/dev/null 2>&1; then
    echo "Moved the earlier version's Acta.app, which shares this bundle ID and data, to the Trash."
  else
    echo "WARNING: could not move $LEGACY_APP to the Trash. It shares Vauta's data: move it to the Trash yourself." >&2
  fi
fi
echo 'When this version opens, macOS may ask for the Keychain password for "Vauta": choose "Always Allow". It asks again after every update of an ad-hoc build and after a new signing identity. If it appears when you have not just installed or updated Vauta, click Deny.'
open ~/Applications/Vauta.app
echo "Vauta is installed in ~/Applications and running: look for the waveform in the menu bar (use the shortcut shown in its menu to record)."
