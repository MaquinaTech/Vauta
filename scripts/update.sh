#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# Updates Vauta to the newest release: fetches the tags, verifies that the newest one is signed by the maintainer's
# key, shows its release notes, checks it out, runs the tests and installs it with scripts/install.sh (same bundle ID,
# same signing method).
#
#   ./scripts/update.sh               ask before installing
#   ./scripts/update.sh --yes         install without asking
#   ./scripts/update.sh --skip-tests  install without running the tests (not recommended)
#
# The key is checked against the allowed_signers file of the checkout you already have, read before anything is
# fetched, and against the fingerprint below: a tag pushed by someone with access to the GitHub account, but without
# the maintainer's private key, is refused. If the maintainer ever changes the key, this script stops and SECURITY.md
# says how to check the new one.
#
# With a local signing identity, run it in your own Terminal: install.sh asks for the signing keychain's password.
set -euo pipefail

FINGERPRINT="SHA256:exvRtcRtqxp/AHhadgXr7PAHe9itjHFPqVVCoGaOrU4"
PRINCIPAL="maintainer@vauta"

fail() { echo "ERROR: $*" >&2; exit 1; }

# Bash reads a script while it runs it, and the checkout below replaces this file: everything runs from main, which
# is read whole before it starts.
main() {
  local yes=0 tests=1
  for arg in "$@"; do
    case "$arg" in
      --yes) yes=1 ;;
      --skip-tests) tests=0 ;;
      *) fail "unknown option $arg (use --yes or --skip-tests)" ;;
    esac
  done
  cd "$(dirname "$0")/.."
  [[ "$(git rev-parse --show-toplevel 2>/dev/null || true)" == "$(pwd -P)" ]] \
    || fail "run this from a Git clone of Vauta (a downloaded archive cannot update itself: clone the repository)"
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] \
    || fail "this folder has local changes; commit or stash them first (git stash)"

  # The trusted key, from what is already on this Mac.
  local dir; dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' EXIT
  cp .github/allowed_signers "$dir/allowed_signers"
  local found
  found="$(awk -v p="$PRINCIPAL" '$1 == p { print $(NF-1), $NF }' "$dir/allowed_signers" | ssh-keygen -lf - 2>/dev/null | awk '{ print $2 }')"
  [[ "$found" == "$FINGERPRINT" ]] \
    || fail ".github/allowed_signers does not hold the maintainer's key $FINGERPRINT (it has '${found:-nothing}'); see SECURITY.md, Verifying what you run"

  echo "Fetching the releases…"
  # --force: a tag the maintainer re-signed replaces the local copy; the signature below decides what is trusted.
  git fetch --quiet --tags --force origin
  git fetch --quiet origin main
  local latest
  latest="$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
  [[ -n "$latest" ]] || fail "no release tag found"
  local version="${latest#v}"

  local installed=""
  if [[ -f ~/Applications/Vauta.app/Contents/Info.plist ]]; then
    installed="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' ~/Applications/Vauta.app/Contents/Info.plist 2>/dev/null || true)"
  fi
  if [[ -n "$installed" ]]; then
    if [[ "$installed" == "$version" ]]; then
      echo "Vauta $installed is installed, the newest release. Nothing to do."
      return 0
    fi
    # Never back to an older release (a stale or replayed tag list).
    [[ "$(printf '%s\n%s\n' "$installed" "$version" | sort -V | tail -1)" == "$version" ]] \
      || fail "the installed Vauta ($installed) is newer than the newest release tag ($latest)"
  fi

  echo "Verifying $latest…"
  [[ "$(git cat-file -t "$latest")" == "tag" ]] || fail "$latest is not a signed tag"
  local verify
  verify="$(git -c gpg.ssh.allowedSignersFile="$dir/allowed_signers" tag -v "$latest" 2>&1)" \
    || fail "the signature of $latest does not verify:"$'\n'"$verify"
  grep -qF "Good \"git\" signature for $PRINCIPAL with ED25519 key $FINGERPRINT" <<< "$verify" \
    || fail "$latest is not signed by the maintainer's key $FINGERPRINT"
  local commit; commit="$(git rev-parse "$latest^{commit}")"
  git merge-base --is-ancestor "$commit" origin/main || fail "$latest is not on the main branch"
  echo "   Good signature by the maintainer's key ($FINGERPRINT), commit ${commit:0:12}."

  echo
  echo "Vauta ${installed:-(not installed)} → $version. Release notes:"
  echo
  git show "$latest:CHANGELOG.md" | awk -v v="$version" '
    $0 ~ "^## \\[" v "\\]" { on = 1; next }
    on && /^## \[/ { exit }
    on { print "   " $0 }'
  echo
  if [[ $yes -eq 0 ]]; then
    [[ -t 0 ]] || fail "run this in a terminal, or pass --yes"
    local answer
    read -r -p "Install Vauta $version? [y/N] " answer
    [[ "$answer" == [yY]* ]] || { echo "Nothing changed."; return 0; }
  fi

  # Detached at the tag, so the version built is exactly the release (build-app.sh reads it from the tag).
  git -c advice.detachedHead=false checkout --quiet "$latest"
  echo "This folder is now at $latest (git switch main to go back to the branch)."

  if [[ $tests -eq 1 ]]; then
    echo "Running the tests…"
    if [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
      swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
    else
      swift test
    fi
  fi
  ./scripts/install.sh
}

main "$@"
exit
