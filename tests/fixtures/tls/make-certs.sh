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

# A three-level chain for the Windows CA-store test: a root, an intermediate it signs and a leaf the intermediate
# signs. The keys stay in the temporary directory.
key "$work/chain-root-key.pem"
openssl req -x509 -new -key "$work/chain-root-key.pem" -subj "/CN=Agentica Test Chain Root" -days "$days" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$dir/chain-root.pem"
key "$work/chain-intermediate-key.pem"
openssl req -new -key "$work/chain-intermediate-key.pem" -subj "/CN=Agentica Test Chain Intermediate" \
  -out "$work/chain-intermediate.csr"
printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' > "$work/chain-intermediate.ext"
openssl x509 -req -in "$work/chain-intermediate.csr" -CA "$dir/chain-root.pem" -CAkey "$work/chain-root-key.pem" \
  -set_serial "0x$(openssl rand -hex 16)" -extfile "$work/chain-intermediate.ext" -days "$days" \
  -out "$dir/chain-intermediate.pem"
key "$work/chain-leaf-key.pem"
openssl req -new -key "$work/chain-leaf-key.pem" -subj "/CN=localhost" -out "$work/chain-leaf.csr"
ext "DNS:localhost,IP:127.0.0.1,IP:::1" chain-leaf
openssl x509 -req -in "$work/chain-leaf.csr" -CA "$dir/chain-intermediate.pem" -CAkey "$work/chain-intermediate-key.pem" \
  -set_serial "0x$(openssl rand -hex 16)" -extfile "$work/chain-leaf.ext" -days "$days" -out "$dir/chain-leaf.pem"
