#!/bin/sh
set -eu

dir=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
days=36500

key() {
  openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$1"
}

ext() {
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' "$1" > "$work/$2.ext"
}

leaf() {
  name=$1 cn=$2 san=$3
  shift 3
  key "$dir/$name-key.pem"
  openssl req -new -key "$dir/$name-key.pem" -subj "/CN=$cn" -out "$work/$name.csr"
  ext "$san" "$name"
  openssl x509 -req -in "$work/$name.csr" -CA "$dir/ca.pem" -CAkey "$work/ca-key.pem" -set_serial "0x$(openssl rand -hex 16)" \
    -extfile "$work/$name.ext" -out "$dir/$name.pem" "$@"
}

key "$work/ca-key.pem"
openssl req -x509 -new -key "$work/ca-key.pem" -subj "/CN=Agentica Test CA" -days "$days" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$dir/ca.pem"

leaf server localhost "DNS:localhost,IP:127.0.0.1,IP:::1" -days "$days"
leaf wrong-host wrong.example "DNS:wrong.example" -days "$days"
leaf expired localhost "DNS:localhost,IP:127.0.0.1,IP:::1" -not_before 20200101000000Z -not_after 20200102000000Z

key "$dir/self-signed-key.pem"
openssl req -x509 -new -key "$dir/self-signed-key.pem" -subj "/CN=localhost" -days "$days" \
  -addext "basicConstraints=critical,CA:FALSE" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1" \
  -out "$dir/self-signed.pem"
