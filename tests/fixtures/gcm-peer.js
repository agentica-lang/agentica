// The independent peer of tests/fixtures/gcm-peer.agc for tests/test_vm_crypto.py: it
// reads JSON cases on stdin and prints, as JSON, the AES-256-GCM encryption of each
// (Node's crypto), the ciphertext with the 16-byte tag appended.
"use strict";
const crypto = require("crypto");

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { input += chunk; });
process.stdin.on("end", () => {
  const hex = (s) => Buffer.from(s, "hex");
  const out = JSON.parse(input).cases.map((c) => {
    const cipher = crypto.createCipheriv("aes-256-gcm", hex(c.key), hex(c.iv), { authTagLength: 16 });
    cipher.setAAD(hex(c.aad));
    const sealed = Buffer.concat([cipher.update(hex(c.data)), cipher.final(), cipher.getAuthTag()]);
    return { sealed: sealed.toString("hex") };
  });
  process.stdout.write(JSON.stringify(out) + "\n");
});
