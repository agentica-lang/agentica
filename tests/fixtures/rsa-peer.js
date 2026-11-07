// The independent peer of tests/fixtures/rsa-peer.agc for tests/test_vm_crypto.py: it
// reads a private key in PEM and RSA-OAEP ciphertexts as hex in a JSON document on stdin
// and prints, as JSON, each one decrypted with Node's crypto (OAEP with SHA-1, the
// default of RSA_PKCS1_OAEP_PADDING), as hex.
"use strict";
const crypto = require("crypto");

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { input += chunk; });
process.stdin.on("end", () => {
  const { key, sealed } = JSON.parse(input);
  const out = sealed.map((hex) => crypto.privateDecrypt(
    { key, padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: "sha1" },
    Buffer.from(hex, "hex"),
  ).toString("hex"));
  process.stdout.write(JSON.stringify(out) + "\n");
});
