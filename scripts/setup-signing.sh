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
    echo "$KC already exists and is not empty: leaving it alone."; exit 1
  fi
  security delete-keychain "$KC"
fi

echo "1/5 Signing keychain. Choose a NEW password (not your Mac's) and save it in your password manager:"
security create-keychain "$KC"
security set-keychain-settings -l -u -t 600 "$KC"

echo "2/5 Generating the identity (the private key only ever exists inside the keychain)…"
D="$(mktemp -d)"; trap 'rm -rfP "$D"' EXIT; umask 077
"$OPENSSL" req -x509 -newkey rsa:3072 -nodes -keyout "$D/key.pem" -out "$D/cert.pem" -days 3650 -sha256 \
  -subj "/CN=$CN" -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
P12PASS="$("$OPENSSL" rand -hex 24)"
# OpenSSL 3 needs -legacy so `security import` can read the .p12; LibreSSL (macOS's) does not know it.
LEGACY=(); "$OPENSSL" version | grep -q '^OpenSSL 3' && LEGACY=(-legacy)
"$OPENSSL" pkcs12 -export ${LEGACY[@]+"${LEGACY[@]}"} -inkey "$D/key.pem" -in "$D/cert.pem" -name "$CN" -out "$D/vauta.p12" -passout "pass:$P12PASS"
echo "   Type the signing keychain's password again to unlock it:"
for try in 1 2 3; do
  security unlock-keychain "$KC" && break
  [[ $try -lt 3 ]] || { echo "Too many attempts. Run the script again."; exit 1; }
  echo "   That does not match, try again ($((try + 1))/3):"
done
security import "$D/vauta.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
echo "   The signing keychain's password once more (authorizes codesign only):"
for try in 1 2 3; do
  security set-key-partition-list -S apple-tool:,apple: -s "$KC" >/dev/null && break
  [[ $try -lt 3 ]] || { echo "Too many attempts. Delete the keychain (security delete-keychain $KC) and start over."; exit 1; }
  echo "   That does not match, try again ($((try + 1))/3):"
done

echo "3/5 Trusting it for code signing only (macOS asks for your Mac's password)…"
security add-trusted-cert -p codeSign -k "$KC" "$D/cert.pem"

NEW_SHA1="$(security find-identity -v -p codesigning "$KC" | awk -v cn="\"$CN\"" '$0 ~ cn {print $2; exit}')"
[[ -n "$NEW_SHA1" ]] || { echo "ERROR: the new identity is not valid for code signing"; exit 1; }
echo "$NEW_SHA1" > scripts/signing-identity.txt   # public fingerprint, read by build-app.sh (git-ignored)

echo "4/5 Removing the old identity from the login keychain…"
while OLD="$(security find-identity -v -p codesigning "$LOGIN_KC" | awk -v cn="\"$CN\"" '$0 ~ cn {print $2; exit}')" && [[ -n "$OLD" ]]; do
  security find-certificate -Z -a -c "$CN" -p "$LOGIN_KC" > "$D/old.pem" 2>/dev/null || true
  [[ -s "$D/old.pem" ]] && security remove-trusted-cert "$D/old.pem" 2>/dev/null || true
  security delete-identity -Z "$OLD" "$LOGIN_KC" >/dev/null
done

security lock-keychain "$KC"
echo "5/5 Done. New identity: $NEW_SHA1 (in $KC, locked)."
echo "To update Vauta: ./scripts/install.sh (it asks for the signing keychain's password)."
