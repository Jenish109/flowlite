#!/bin/bash
# Creates a local self-signed code-signing identity, "FlowLite Local Signing".
# Signing every build with the same identity lets macOS privacy permissions
# (Microphone, Accessibility, Input Monitoring) survive rebuilds.
set -euo pipefail

NAME="FlowLite Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Identity '$NAME' already exists."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cfg" <<EOF2
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF2

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$TMP/cert.cfg" -keyout "$TMP/key.pem" -out "$TMP/cert.pem"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout pass:flowlite \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P flowlite -T /usr/bin/codesign
if [[ -n "${KEYCHAIN_PASSWORD:-}" ]]; then
  # Lets codesign use the key without prompting.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
else
  echo "note: KEYCHAIN_PASSWORD not set; the first codesign will show a one-time keychain dialog — click \"Always Allow\"."
fi
echo "Trusting the certificate for code signing (macOS will ask for your login password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

security find-identity -v -p codesigning | grep "$NAME"
