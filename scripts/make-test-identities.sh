#!/usr/bin/env bash
# Generates the three TEST-ONLY identities (EC P-256, self-signed, 100 years) as PKCS#12.
# Password: "test". These files are committed; they never ship in any app.
set -euo pipefail
cd "$(dirname "$0")/.."
out=protocol/testdata/identities
mkdir -p "$out"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# OpenSSL 3 needs -legacy to emit 3DES/SHA1 PKCS#12 that Apple and Java both read.
legacy=""
if openssl version | grep -q '^OpenSSL 3'; then legacy="-legacy"; fi

gen() { # file-stem  CN
  openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/$1.key"
  openssl req -new -x509 -key "$tmp/$1.key" -sha256 -days 36500 -subj "/CN=$2" -out "$tmp/$1.crt"
  openssl pkcs12 -export $legacy -inkey "$tmp/$1.key" -in "$tmp/$1.crt" -name "$2" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -passout pass:test -out "$out/$1.p12"
}
gen mac "AM Test Mac"
gen phone "AM Test Phone"
gen stranger "AM Test Stranger"
echo "wrote $out/{mac,phone,stranger}.p12"
