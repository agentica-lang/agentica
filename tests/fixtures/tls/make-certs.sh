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

# A three-level chain for the CA-store tests: a root, an intermediate it signs and a leaf the intermediate signs.
# The intermediate has no extendedKeyUsage extension, so the Windows EKU test sets the Crypt32 property alone.
# chain-intermediate-email.pem is a sibling of the intermediate (same subject and key) limited to emailProtection by
# its EKU extension.
# chain-root-cross.pem is a cross-signed copy of the root (same subject and key) signed by chain-cross-signer.pem.
# The keys stay in the temporary directory.
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
printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nextendedKeyUsage=emailProtection\n' \
  > "$work/chain-intermediate-email.ext"
openssl x509 -req -in "$work/chain-intermediate.csr" -CA "$dir/chain-root.pem" -CAkey "$work/chain-root-key.pem" \
  -set_serial "0x$(openssl rand -hex 16)" -extfile "$work/chain-intermediate-email.ext" -days "$days" \
  -out "$dir/chain-intermediate-email.pem"
key "$work/chain-leaf-key.pem"
openssl req -new -key "$work/chain-leaf-key.pem" -subj "/CN=localhost" -out "$work/chain-leaf.csr"
ext "DNS:localhost,IP:127.0.0.1,IP:::1" chain-leaf
openssl x509 -req -in "$work/chain-leaf.csr" -CA "$dir/chain-intermediate.pem" -CAkey "$work/chain-intermediate-key.pem" \
  -set_serial "0x$(openssl rand -hex 16)" -extfile "$work/chain-leaf.ext" -days "$days" -out "$dir/chain-leaf.pem"
key "$work/chain-cross-signer-key.pem"
openssl req -x509 -new -key "$work/chain-cross-signer-key.pem" -subj "/CN=Agentica Test Cross Signer" -days "$days" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out "$dir/chain-cross-signer.pem"
openssl req -new -key "$work/chain-root-key.pem" -subj "/CN=Agentica Test Chain Root" -out "$work/chain-root-cross.csr"
printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > "$work/chain-root-cross.ext"
openssl x509 -req -in "$work/chain-root-cross.csr" -CA "$dir/chain-cross-signer.pem" \
  -CAkey "$work/chain-cross-signer-key.pem" -set_serial "0x$(openssl rand -hex 16)" -extfile "$work/chain-root-cross.ext" \
  -days "$days" -out "$dir/chain-root-cross.pem"

# A client CA and a client certificate it signs, for TLS.connect with a client certificate (mTLS); the client CA's key
# stays in the temporary directory.
key "$work/client-ca-key.pem"
openssl req -x509 -new -key "$work/client-ca-key.pem" -subj "/CN=Agentica Test Client CA" -days "$days" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$dir/client-ca.pem"
key "$dir/client-key.pem"
openssl req -new -key "$dir/client-key.pem" -subj "/CN=Agentica Test Client" -out "$work/client.csr"
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n' \
  > "$work/client.ext"
openssl x509 -req -in "$work/client.csr" -CA "$dir/client-ca.pem" -CAkey "$work/client-ca-key.pem" \
  -set_serial "0x$(openssl rand -hex 16)" -extfile "$work/client.ext" -days "$days" -out "$dir/client.pem"
