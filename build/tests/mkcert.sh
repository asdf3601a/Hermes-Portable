#!/usr/bin/env bash
# Test PKI like a TLS-intercepting corporate proxy: a private root CA and a
# 127.0.0.1/localhost server certificate signed by it.
#   mkcert.sh OUT_DIR  ->  OUT_DIR/{ca.pem,ca.key,server.pem,server.key}
set -euo pipefail
out=${1:?usage: mkcert.sh OUT_DIR}
mkdir -p "$out"
cd "$out"
export MSYS_NO_PATHCONV=1
openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj "/CN=Hermes Portable Test Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -keyout ca.key -out ca.pem 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=127.0.0.1" -keyout server.key -out server.csr 2>/dev/null
printf '%s\n' "basicConstraints=CA:FALSE" "keyUsage=critical,digitalSignature,keyEncipherment" \
  "extendedKeyUsage=serverAuth" "subjectAltName=IP:127.0.0.1,DNS:localhost" > server.ext
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 3 \
  -extfile server.ext -out server.pem 2>/dev/null
rm -f server.csr server.ext ca.srl
