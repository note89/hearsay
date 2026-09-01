#!/usr/bin/env bash
# Creates a local self-signed code-signing certificate ("hearsay-dev") and imports it into the
# login keychain. A stable signature keeps macOS permission grants across rebuilds.
# Run once per machine, then: sudo security add-trusted-cert -d -r trustRoot -p codeSign \
#   -k /Library/Keychains/System.keychain scripts/hearsay-dev.pem   (fix-permissions.sh does this)
set -euo pipefail
cd "$(dirname "$0")/.."

if security find-identity -p codesigning 2>/dev/null | grep -q "hearsay-dev"; then
    echo "hearsay-dev certificate already in keychain"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out scripts/hearsay-dev.pem -days 3650 -nodes \
    -subj "/CN=hearsay-dev" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null
# -legacy: macOS `security import` cannot read OpenSSL 3's default PKCS12 encryption
openssl pkcs12 -export -legacy -out "$WORK/hearsay-dev.p12" -inkey "$WORK/key.pem" -in scripts/hearsay-dev.pem \
    -passout pass:hearsay -name hearsay-dev 2>/dev/null \
  || openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -out "$WORK/hearsay-dev.p12" -inkey "$WORK/key.pem" -in scripts/hearsay-dev.pem -passout pass:hearsay -name hearsay-dev
security import "$WORK/hearsay-dev.p12" -k ~/Library/Keychains/login.keychain-db -P hearsay -T /usr/bin/codesign
echo "hearsay-dev certificate created (public half: scripts/hearsay-dev.pem)"
echo "next: scripts/fix-permissions.sh to trust it and re-sign"
