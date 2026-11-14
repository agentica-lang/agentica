import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "OpenSSL.Digest.hexdecode",
    parameters: [Model.Named(name: "text", type: Types.Type.String)],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.Digest.hexdecode.bytes",
    effects: [],
    description: (
      "Decode an even number of hex digits in either case to bytes, or an error for any other text; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.Digest.hexencode",
    parameters: [Model.Named(name: "data", type: Types.Type.Bytes)],
    result: Types.Type.String,
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.Digest.hexencode.bytes",
    effects: [],
    description: "Encode bytes as two lowercase hex digits each; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.Digest.md5",
    parameters: [Model.Named(name: "data", type: Types.Type.Bytes)],
    result: Types.Type.Bytes,
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.Digest.md5.bytes",
    effects: [],
    description: (
      "Hash bytes with MD5 and return the 16 bytes of the digest; for compatibility (ETags, old " +
      "APIs), not for security; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.Digest.md5_hexdigest",
    parameters: [Model.Named(name: "data", type: Types.Type.Bytes)],
    result: Types.Type.String,
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.Digest.md5_hexdigest.bytes",
    effects: [],
    description: (
      "Hash bytes with MD5 and return the digest as 32 lowercase hex digits; for compatibility " +
      "(ETags, old APIs), not for security; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.Digest.sha1",
    parameters: [Model.Named(name: "data", type: Types.Type.Bytes)],
    result: Types.Type.Bytes,
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.Digest.sha1.bytes",
    effects: [],
    description: (
      "Hash bytes with SHA-1 and return the 20 bytes of the digest; for compatibility (git, old " +
      "APIs), not for security; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.Digest.sha1_hexdigest",
    parameters: [Model.Named(name: "data", type: Types.Type.Bytes)],
    result: Types.Type.String,
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.Digest.sha1_hexdigest.bytes",
    effects: [],
    description: (
      "Hash bytes with SHA-1 and return the digest as 40 lowercase hex digits; for " +
      "compatibility (git, old APIs), not for security; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.Digest.sha256",
    parameters: [Model.Named(name: "data", type: Types.Type.Bytes)],
    result: Types.Type.Bytes,
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.Digest.sha256.bytes",
    effects: [],
    description: "Hash bytes with SHA-256 and return the 32 bytes of the digest; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.Digest.sha256_hexdigest",
    parameters: [Model.Named(name: "data", type: Types.Type.Bytes)],
    result: Types.Type.String,
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.Digest.sha256_hexdigest.bytes",
    effects: [],
    description: "Hash bytes with SHA-256 and return the digest as 64 lowercase hex digits; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.Digest.sha512",
    parameters: [Model.Named(name: "data", type: Types.Type.Bytes)],
    result: Types.Type.Bytes,
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.Digest.sha512.bytes",
    effects: [],
    description: "Hash bytes with SHA-512 and return the 64 bytes of the digest; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.Digest.sha512_hexdigest",
    parameters: [Model.Named(name: "data", type: Types.Type.Bytes)],
    result: Types.Type.String,
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.Digest.sha512_hexdigest.bytes",
    effects: [],
    description: "Hash bytes with SHA-512 and return the digest as 128 lowercase hex digits; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.HMAC.sha256",
    parameters: [Model.Named(name: "key", type: Types.Type.Bytes), Model.Named(name: "data", type: Types.Type.Bytes)],
    result: Types.Type.Bytes,
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.HMAC.sha256.bytes",
    effects: [],
    description: (
      "HMAC-SHA256 (RFC 2104) of data (bytes) under a key of any length; returns the " +
      "32 bytes of the MAC; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.HMAC.sha256_hexdigest",
    parameters: [Model.Named(name: "key", type: Types.Type.Bytes), Model.Named(name: "data", type: Types.Type.Bytes)],
    result: Types.Type.String,
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.HMAC.sha256_hexdigest.bytes",
    effects: [],
    description: (
      "HMAC-SHA256 (RFC 2104) of data (bytes) under a key of any length; returns the " +
      "MAC as 64 lowercase hex digits; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.HMAC.sha512",
    parameters: [Model.Named(name: "key", type: Types.Type.Bytes), Model.Named(name: "data", type: Types.Type.Bytes)],
    result: Types.Type.Bytes,
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.HMAC.sha512.bytes",
    effects: [],
    description: (
      "HMAC-SHA512 (RFC 2104) of data (bytes) under a key of any length; returns the " +
      "64 bytes of the MAC; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.HMAC.sha512_hexdigest",
    parameters: [Model.Named(name: "key", type: Types.Type.Bytes), Model.Named(name: "data", type: Types.Type.Bytes)],
    result: Types.Type.String,
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.HMAC.sha512_hexdigest.bytes",
    effects: [],
    description: (
      "HMAC-SHA512 (RFC 2104) of data (bytes) under a key of any length; returns the " +
      "MAC as 128 lowercase hex digits; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.Random.random_bytes",
    parameters: [Model.Named(name: "count", type: Types.Type.Int, default: Model.Default.Whole(16))],
    result: Types.Type.Bytes,
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.Random.random_bytes.bytes",
    effects: ["random"],
    description: (
      "Draw count bytes (0..1048576, 16 by default) from the system's secure random source (OpenSSL RAND_bytes), " +
      "for keys, salts and tokens; unlike Random, never seeded; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.Random.hex",
    parameters: [Model.Named(name: "count", type: Types.Type.Int, default: Model.Default.Whole(16))],
    result: Types.Type.String,
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.Random.hex",
    effects: ["random"],
    description: (
      "Draw count secure random bytes (0..1048576, 16 by default) and give them as 2 * count lowercase hex " +
      "digits; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.Random.uuid",
    parameters: [],
    result: Types.Type.String,
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.Random.uuid",
    effects: ["random"],
    description: "Draw a random version 4 UUID (RFC 9562) as 36 lowercase characters; VM only.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.HMAC.secure_compare",
    parameters: [
      Model.Named(name: "bytes", type: Types.Type.Bytes),
      Model.Named(name: "other", type: Types.Type.Bytes),
    ],
    result: Types.Type.Bool,
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.HMAC.secure_compare.bytes",
    effects: [],
    description: (
      "Whether bytes and other are the same, in constant time: it compares their SHA-256 " +
      "digests with OpenSSL CRYPTO_memcmp, so the time never depends on the bytes; for checking MACs and " +
      "tokens; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.Cipher.des_ede3_cbc_encrypt",
    parameters: [
      Model.Named(name: "key", type: Types.Type.Bytes),
      Model.Named(name: "iv", type: Types.Type.Bytes),
      Model.Named(name: "data", type: Types.Type.Bytes),
    ],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.Cipher.des_ede3_cbc_encrypt",
    effects: [],
    description: (
      "Encrypt data (bytes) with Triple DES in CBC mode and no padding, for payment formats, not new designs; " +
      "a key of 16 (two-key) or 24 bytes, an 8-byte iv and data in whole 8-byte blocks, or an error; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.Cipher.des_ede3_cbc_decrypt",
    parameters: [
      Model.Named(name: "key", type: Types.Type.Bytes),
      Model.Named(name: "iv", type: Types.Type.Bytes),
      Model.Named(name: "data", type: Types.Type.Bytes),
    ],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.Cipher.des_ede3_cbc_decrypt",
    effects: [],
    description: (
      "Decrypt data (bytes) with Triple DES in CBC mode and no padding, for payment formats, not new designs; " +
      "a key of 16 (two-key) or 24 bytes, an 8-byte iv and data in whole 8-byte blocks, or an error; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.CMAC.aes",
    parameters: [Model.Named(name: "key", type: Types.Type.Bytes), Model.Named(name: "data", type: Types.Type.Bytes)],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.CMAC.aes",
    effects: [],
    description: (
      "CMAC (NIST SP 800-38B, RFC 4493) of data (bytes) with AES-128, -192 or -256 by the key size " +
      "(16, 24 or 32 bytes); the full 16-byte tag, or an error for another key size; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.CMAC.des_ede3",
    parameters: [Model.Named(name: "key", type: Types.Type.Bytes), Model.Named(name: "data", type: Types.Type.Bytes)],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.CMAC.des_ede3",
    effects: [],
    description: (
      "CMAC (NIST SP 800-38B) of data (bytes) with Triple DES, for payment formats; a key of 16 " +
      "(two-key) or 24 bytes; the full 8-byte tag, or an error for another key size; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.Cipher.aes_256_gcm_encrypt",
    parameters: [
      Model.Named(name: "key", type: Types.Type.Bytes),
      Model.Named(name: "iv", type: Types.Type.Bytes),
      Model.Named(name: "data", type: Types.Type.Bytes),
      Model.Named(name: "auth_data", type: Types.Type.Bytes, default: Model.Default.EmptyBytes),
    ],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.Cipher.aes_256_gcm_encrypt",
    effects: [],
    description: (
      "Encrypt data (bytes) with AES-256-GCM: a 32-byte key, a 12-byte iv never reused under the key and " +
      "optional auth_data, authenticated but not encrypted; the ciphertext with the 16-byte tag appended; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.Cipher.aes_256_gcm_decrypt",
    parameters: [
      Model.Named(name: "key", type: Types.Type.Bytes),
      Model.Named(name: "iv", type: Types.Type.Bytes),
      Model.Named(name: "data", type: Types.Type.Bytes),
      Model.Named(name: "auth_data", type: Types.Type.Bytes, default: Model.Default.EmptyBytes),
    ],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.Cipher.aes_256_gcm_decrypt",
    effects: [],
    description: (
      "Decrypt AES-256-GCM data (the ciphertext with its 16-byte tag appended) under the same key, iv and " +
      "auth_data; a tag that does not match is an error, never partial plaintext; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.KDF.pbkdf2_hmac_sha256",
    parameters: [
      Model.Named(name: "password", type: Types.Type.Bytes),
      Model.Named(name: "salt", type: Types.Type.Bytes),
      Model.Named(name: "iterations", type: Types.Type.Int),
      Model.Named(name: "length", type: Types.Type.Int),
    ],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.KDF.pbkdf2_hmac_sha256",
    effects: [],
    description: (
      "Derive length bytes (1 to 1048576) from a password and a salt with PBKDF2-HMAC-SHA256 (RFC 8018) and at " +
      "least 1 iteration, iterations * ceil(length / 32) at most 50000000; a password or salt over 1048576 " +
      "bytes is an error; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.KDF.scrypt",
    parameters: [
      Model.Named(name: "password", type: Types.Type.Bytes),
      Model.Named(name: "salt", type: Types.Type.Bytes),
      Model.Named(name: "n", type: Types.Type.Int),
      Model.Named(name: "r", type: Types.Type.Int),
      Model.Named(name: "p", type: Types.Type.Int),
      Model.Named(name: "length", type: Types.Type.Int),
    ],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.KDF.scrypt",
    effects: [],
    description: (
      "Derive length bytes (1 to 1048576) from a password and a salt with scrypt (RFC 7914): cost n, a power " +
      "of 2, block size r and parallelization p, in at most 1025 MiB (128 * r * (n + p + 2) bytes) and with " +
      "r * p * (n + 16) at most 2^25, or an error; VM only."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "OpenSSL.RSA.public_encrypt_oaep",
    parameters: [Model.Named(name: "pem", type: Types.Type.String), Model.Named(name: "data", type: Types.Type.Bytes)],
    result: Types.Type.Result(Types.Type.Bytes),
    rule: Model.Rule.Plain,
    implementation: "OpenSSL.RSA.public_encrypt_oaep",
    effects: ["random"],
    description: (
      "Encrypt data (bytes) with the RSA public key in pem (PUBLIC KEY or RSA PUBLIC KEY) and OAEP padding with " +
      "SHA-1; at most the key size less 42 bytes; a bad PEM, a key that is not RSA or data too long is an error; " +
      "VM only."
    ),
    alternatives: [],
  ),
]
