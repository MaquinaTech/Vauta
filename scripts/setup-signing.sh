#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# Creates Vauta's local code-signing identity in a DEDICATED keychain, protected by its own
# password and locked automatically (after 10 minutes or on sleep). This way no process
# running as your user can sign code as Vauta (and thereby read your meetings' key or use
# its microphone permission) without that password.
# Also removes the old identity from the login keychain.
#
# Free and local: no Apple Developer account needed. Vauta is distributed as source only, so this is the
# signature every user's build gets. (Someone with a Developer ID can set VAUTA_SIGN_IDENTITY instead, see
# scripts/build-app.sh.)
#
# Interactive: passwords are typed on the keyboard, never passed as arguments.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/legacy-env.sh

KC="$HOME/Library/Keychains/vauta-signing.keychain-db"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"
CN="Vauta Local Code Signing"
OPENSSL=/opt/homebrew/bin/openssl
[[ -x "$OPENSSL" ]] || OPENSSL=/usr/bin/openssl
[[ -t 0 ]] || { echo "Run this in a terminal: it asks for passwords."; exit 1; }
if [[ -e "$KC" ]]; then
  # A previous, interrupted attempt leaves an empty keychain: rebuild it. A keychain with
  # content is never touched.
  if [[ -n "$(security find-certificate -a "$KC" 2>/dev/null)" ]]; then
    if [[ -s scripts/signing-identity.txt ]]; then
      echo "Vauta's signing identity is already set up ($KC). Nothing to do: run ./scripts/install.sh."; exit 0
    fi
    # The keychain is per user but signing-identity.txt is per checkout (git-ignored): a new clone of a finished
    # setup only needs the fingerprint written again. Deleting the keychain would change Vauta's signature.
    SHA1="$(security find-identity -v -p codesigning "$KC" 2>/dev/null | awk -v cn="\"$CN\"" '$0 ~ cn {print $2; exit}')"
    if [[ -n "$SHA1" ]]; then
      echo "$SHA1" > scripts/signing-identity.txt
      echo "Vauta's signing identity is already set up ($KC); this folder now uses it. Run ./scripts/install.sh."; exit 0
    fi
    # An attempt that stopped after the import (for example at the trust step) leaves an identity that is not
    # valid for code signing: say how to start over instead of looping.
    echo "$KC is left over from an attempt that did not finish. Delete it and run this script again:"
    echo "  security delete-keychain \"$KC\""
    exit 1
  fi
  security delete-keychain "$KC"
fi

echo "1/5 Signing keychain. Choose a NEW password (not your Mac's) and save it in your password manager:"
security create-keychain "$KC"
security set-keychain-settings -l -u -t 600 "$KC"

echo "2/5 Generating the identity and importing it into the signing keychain…"
# The private key exists outside the keychain only for the few seconds of this step: unencrypted in a temporary folder
# that only you can read, and erased on exit. The .p12 that carries it into the keychain uses a random one-time
# password, which `security import` takes as an argument (it has no other non-interactive way): a process running as
# you could see it in that moment, but such a process could read the key file in the folder as well.
# The signing keychain is locked again however the script ends (it is unlocked from the import on).
D="$(mktemp -d)"; trap 'rm -rfP "$D"; security lock-keychain "$KC" 2>/dev/null || true' EXIT; umask 077
"$OPENSSL" req -x509 -newkey rsa:3072 -nodes -keyout "$D/key.pem" -out "$D/cert.pem" -days 3650 -sha256 \
  -subj "/CN=$CN" -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null \
  || { echo "ERROR: $("$OPENSSL" version) could not create the certificate. Please report it."; exit 1; }
P12PASS="$("$OPENSSL" rand -hex 24)"
# OpenSSL 3 and later (Homebrew's) write the .p12 with AES and PBKDF2, which `security import` cannot read: it fails with
# "MAC verification failed during PKCS12 import (wrong password?)". Name the algorithms macOS reads (3DES, SHA-1 MAC), whatever
# the version; LibreSSL (macOS's) already uses them.
P12ALGS=(); "$OPENSSL" version | grep -q '^OpenSSL' && P12ALGS=(-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1)
"$OPENSSL" pkcs12 -export ${P12ALGS[@]+"${P12ALGS[@]}"} -inkey "$D/key.pem" -in "$D/cert.pem" -name "$CN" -out "$D/vauta.p12" -passout "pass:$P12PASS"
echo "   Type the signing keychain's password again to unlock it:"
for try in 1 2 3; do
  security unlock-keychain "$KC" && break
  [[ $try -lt 3 ]] || { echo "Too many attempts. Run the script again."; exit 1; }
  echo "   That does not match, try again ($((try + 1))/3):"
done
security import "$D/vauta.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign >/dev/null \
  || { echo "ERROR: could not import the signing identity (not your password: the .p12 made by $("$OPENSSL" version)). Please report it."; exit 1; }
echo "   The signing keychain's password once more (authorizes codesign only):"
for try in 1 2 3; do
  security set-key-partition-list -S apple-tool:,apple: -s "$KC" >/dev/null && break
  [[ $try -lt 3 ]] || { echo "Too many attempts. Delete the keychain (security delete-keychain $KC) and start over."; exit 1; }
  echo "   That does not match, try again ($((try + 1))/3):"
done

echo "3/5 Trusting it for code signing only (macOS asks for your Mac's login password this time, not the new one)…"
for try in 1 2 3; do
  security add-trusted-cert -p codeSign -k "$KC" "$D/cert.pem" && break
  [[ $try -lt 3 ]] || { echo "Not trusted. Delete the keychain (security delete-keychain \"$KC\") and start over."; exit 1; }
  echo "   Not trusted (wrong password or cancelled). Your Mac's login password, try again ($((try + 1))/3):"
done

NEW_SHA1="$(security find-identity -v -p codesigning "$KC" | awk -v cn="\"$CN\"" '$0 ~ cn {print $2; exit}')"
[[ -n "$NEW_SHA1" ]] || { echo "ERROR: the new identity is not valid for code signing"; exit 1; }
echo "$NEW_SHA1" > scripts/signing-identity.txt   # public fingerprint, read by build-app.sh (git-ignored)

echo "4/5 Removing the old identity from the login keychain…"
# All of them, valid or not (an old identity may be untrusted or expired). A failure here is only a warning: the new
# identity is already set up.
while OLD="$(security find-identity -p codesigning "$LOGIN_KC" | awk -v cn="\"$CN\"" '$0 ~ cn {print $2; exit}')" && [[ -n "$OLD" ]]; do
  security find-certificate -Z -a -c "$CN" -p "$LOGIN_KC" > "$D/old.pem" 2>/dev/null || true
  [[ -s "$D/old.pem" ]] && security remove-trusted-cert "$D/old.pem" 2>/dev/null || true
  security delete-identity -Z "$OLD" "$LOGIN_KC" >/dev/null \
    || { echo "   WARNING: could not remove the old identity $OLD from the login keychain; delete it in Keychain Access."; break; }
done

security lock-keychain "$KC"
echo "5/5 Done. New identity: $NEW_SHA1 (in $KC, locked)."
echo "To update Vauta: ./scripts/install.sh (it asks for the signing keychain's password)."
