#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
#
# Only for the "Another computer" model server mode: creates a private CA and the model
# server's TLS certificate (EC P-256) so it can be served over HTTPS on the local network.
#
#   ./scripts/make-server-cert.sh 192.168.1.50 [server.local ...]
#
# The arguments are the fixed IP address(es) and the host names Vauta will connect to:
# they go into the SAN and must match the URL in Settings > Models.
#
# Writes to ./vauta-server-tls/ (or $VAUTA_TLS_DIR):
#   ca.key      the CA's private key: keep it off the server and out of cloud backups
#   ca.crt      the public CA: paste it into Settings > Models ("Private CA (PEM)")
#   server.key  the server's private key: only on the model server (or its TLS proxy)
#   server.crt  the server certificate (800 days: macOS rejects more than 825)
#
# To renew, run it again with the same arguments. It reuses the CA and the server key,
# so the pin does not change and Vauta needs no update.
set -euo pipefail
source "$(dirname "$0")/legacy-env.sh"
usage() { sed -n '5,20p' "$0" | sed 's/^# \{0,1\}//'; }
[[ $# -ge 1 ]] || { usage; exit 2; }

OPENSSL=/opt/homebrew/bin/openssl
[[ -x "$OPENSSL" ]] || OPENSSL=openssl
DIR="${VAUTA_TLS_DIR:-vauta-server-tls}"
mkdir -p "$DIR"
chmod 700 "$DIR"
umask 077

SAN=()
for h in "$@"; do
  if [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$h" == *:* ]]; then SAN+=("IP:$h"); else SAN+=("DNS:$h"); fi
done
SAN_LIST="$(IFS=,; echo "${SAN[*]}")"

if [[ ! -f "$DIR/ca.key" ]]; then
  echo "Creating the private CA (10 years)…"
  "$OPENSSL" ecparam -name prime256v1 -genkey -noout -out "$DIR/ca.key"
  cat > "$DIR/ca.ext" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Vauta Model Server CA
[v3]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF
  "$OPENSSL" req -x509 -new -key "$DIR/ca.key" -sha256 -days 3650 -config "$DIR/ca.ext" -out "$DIR/ca.crt"
  rm -f "$DIR/ca.ext"
else
  echo "Reusing the existing CA ($DIR/ca.crt)."
fi

if [[ ! -f "$DIR/server.key" ]]; then
  "$OPENSSL" ecparam -name prime256v1 -genkey -noout -out "$DIR/server.key"
else
  echo "Reusing the server key (the pin does not change)."
fi
cat > "$DIR/server.ext" <<EOF
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = $SAN_LIST
EOF
"$OPENSSL" req -new -key "$DIR/server.key" -subj "/CN=${1}" -out "$DIR/server.csr"
"$OPENSSL" x509 -req -in "$DIR/server.csr" -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" -CAcreateserial \
  -days 800 -sha256 -extfile "$DIR/server.ext" -out "$DIR/server.crt" 2>/dev/null
rm -f "$DIR/server.csr" "$DIR/server.ext" "$DIR/ca.srl"
chmod 600 "$DIR"/*.key
chmod 644 "$DIR"/*.crt

pin() { "$OPENSSL" x509 -in "$1" -pubkey -noout | "$OPENSSL" pkey -pubin -outform der | "$OPENSSL" dgst -sha256 -binary | base64; }
"$OPENSSL" verify -CAfile "$DIR/ca.crt" "$DIR/server.crt" >/dev/null
echo
echo "Done in $DIR/  (SAN: $SAN_LIST)"
echo "  Server pin (Settings > Models > Pins): $(pin "$DIR/server.crt")"
echo "  Expires: $("$OPENSSL" x509 -in "$DIR/server.crt" -noout -enddate | cut -d= -f2)"
echo "Next: configure the server (or its TLS proxy) with server.crt + server.key,"
echo "and paste ca.crt into Vauta. Keep ca.key off the server."
