// The independent peer of tests/fixtures/cipher-peer.agc for tests/test_vm_crypto.py:
// it reads the same JSON cases on stdin and prints, as JSON, Triple DES CBC with no
// padding (Node's crypto: des-ede-cbc for a two-key key, des-ede3-cbc for three keys)
// and CMAC written here from RFC 4493 (NIST SP 800-38B) over Node's ECB ciphers.
"use strict";
const crypto = require("crypto");

function tdesName(key, mode) {
  return (key.length === 16 ? "des-ede" : "des-ede3") + mode;
}

function tdesCbc(encrypt, key, iv, data) {
  const make = encrypt ? crypto.createCipheriv : crypto.createDecipheriv;
  const c = make(tdesName(key, "-cbc"), key, iv).setAutoPadding(false);
  return Buffer.concat([c.update(data), c.final()]);
}

// Doubling in GF(2^n): shift left one bit; if the top bit was set, XOR rb into the last byte.
function dbl(x, rb) {
  const out = Buffer.alloc(x.length);
  for (let i = 0; i < x.length; i++) {
    out[i] = ((x[i] << 1) | (i + 1 < x.length ? x[i + 1] >> 7 : 0)) & 0xff;
  }
  if (x[0] & 0x80) out[out.length - 1] ^= rb;
  return out;
}

function xor(a, b) {
  const out = Buffer.alloc(a.length);
  for (let i = 0; i < a.length; i++) out[i] = a[i] ^ b[i];
  return out;
}

// RFC 4493 §2.4 for any block size b; rb is 0x87 for 128-bit blocks and 0x1b for 64-bit ones.
function cmac(ecbName, key, b, rb, msg) {
  const ecb = crypto.createCipheriv(ecbName, key, null).setAutoPadding(false);
  const enc = (block) => ecb.update(block);
  const k1 = dbl(enc(Buffer.alloc(b)), rb);
  const k2 = dbl(k1, rb);
  const n = Math.max(1, Math.ceil(msg.length / b));
  const tail = msg.subarray((n - 1) * b);
  let last;
  if (msg.length > 0 && tail.length === b) {
    last = xor(tail, k1);
  } else {
    const padded = Buffer.alloc(b);
    tail.copy(padded);
    padded[tail.length] = 0x80;
    last = xor(padded, k2);
  }
  let x = Buffer.alloc(b);
  for (let i = 0; i < n - 1; i++) x = enc(xor(x, msg.subarray(i * b, (i + 1) * b)));
  return enc(xor(x, last));
}

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { input += chunk; });
process.stdin.on("end", () => {
  const hex = (s) => Buffer.from(s, "hex");
  const out = JSON.parse(input).cases.map((c) => {
    const desKey = hex(c.des_key), iv = hex(c.iv), aesKey = hex(c.aes_key);
    const blocks = hex(c.blocks), data = hex(c.data);
    return {
      encrypt: tdesCbc(true, desKey, iv, blocks).toString("hex"),
      decrypt: tdesCbc(false, desKey, iv, blocks).toString("hex"),
      cmac_aes: cmac(`aes-${aesKey.length * 8}-ecb`, aesKey, 16, 0x87, data).toString("hex"),
      cmac_des_ede3: cmac(tdesName(desKey, ""), desKey, 8, 0x1b, data).toString("hex"),
    };
  });
  process.stdout.write(JSON.stringify(out) + "\n");
});
