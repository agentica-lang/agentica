# OpenSSL, Base64 and hex

Binary data is `Bytes` (`bytes.md`); text goes through `s.bytes` and
`String.from_bytes` (`binary.md`).

- The hashes, MACs, ciphers and secure random bytes are the members of the
  `OpenSSL` family, as in Ruby: `OpenSSL.Digest`, `OpenSSL.HMAC`,
  `OpenSSL.Cipher`, `OpenSSL.CMAC`, `OpenSSL.KDF`, `OpenSSL.RSA` and
  `OpenSSL.Random`. `OpenSSL` is the one reserved name; a misspelled member is
  `CHECK-UNKNOWN-NAME`.
- `OpenSSL.Digest.md5`, `sha1`, `sha256` and `sha512(data: Bytes) -> Bytes`
  hash bytes and return the 16, 20, 32 or 64 digest bytes; each `_hexdigest`
  form (`OpenSSL.Digest.sha256_hexdigest(data) -> String`) returns them as
  lowercase hex, as Ruby's `Digest::SHA256.hexdigest`. Hash text with
  `OpenSSL.Digest.sha256("abc".bytes)`. MD5 and SHA-1 are for formats that
  need them (ETags, git), not for security.
- `OpenSSL.HMAC.sha256(key: Bytes, data: Bytes) -> Bytes` and
  `OpenSSL.HMAC.sha512(key, data)` return the 32 or 64 bytes of the HMAC;
  `OpenSSL.HMAC.sha256_hexdigest(key, data) -> String` and `sha512_hexdigest`
  return them as lowercase hex. Any key length works.
- `OpenSSL.HMAC.secure_compare(bytes: Bytes, other: Bytes) -> Bool` compares
  bytes in constant time: check a received MAC, signature or token with it,
  never with `==`. Other lengths give `false`.
- Triple DES CBC and CMAC are for payment formats (PIN blocks, key check
  values, ISO 8583 MACs), not for new designs. Each gives an `error(...)` for a
  wrong key, IV or data size, never partial output:

```text
OpenSSL.Cipher.des_ede3_cbc_encrypt(key: Bytes, iv: Bytes, data: Bytes) -> Result[Bytes]
OpenSSL.Cipher.des_ede3_cbc_decrypt(key: Bytes, iv: Bytes, data: Bytes) -> Result[Bytes]
OpenSSL.CMAC.aes(key: Bytes, data: Bytes) -> Result[Bytes]       # 16-byte tag
OpenSSL.CMAC.des_ede3(key: Bytes, data: Bytes) -> Result[Bytes]  # 8-byte tag
```

- The Triple DES key is 24 bytes, or 16 (K1 K2, run as K1 K2 K1); the IV 8
  bytes; the data whole 8-byte blocks, with no padding: pad it as the format
  says. The AES key of `OpenSSL.CMAC.aes` is 16, 24 or 32 bytes. A shorter MAC
  is `tag.take(n)`; check it with `OpenSSL.HMAC.secure_compare`.
- AES-256-GCM encrypts and authenticates; PBKDF2 and scrypt derive a key from
  a password (store the salt and the parameters beside the result):

```text
OpenSSL.Cipher.aes_256_gcm_encrypt(key: Bytes, iv: Bytes, data: Bytes, auth_data: Bytes = "".bytes) -> Result[Bytes]
OpenSSL.Cipher.aes_256_gcm_decrypt(key: Bytes, iv: Bytes, data: Bytes, auth_data: Bytes = "".bytes) -> Result[Bytes]
OpenSSL.KDF.pbkdf2_hmac_sha256(password: Bytes, salt: Bytes, iterations: Int, length: Int) -> Result[Bytes]
OpenSSL.KDF.scrypt(password: Bytes, salt: Bytes, n: Int, r: Int, p: Int, length: Int) -> Result[Bytes]
```

- GCM: a 32-byte key and a 12-byte IV, never reused with one key
  (`OpenSSL.Random.random_bytes(12)`). Encrypting gives the ciphertext with the
  16-byte tag appended; decrypting takes that form and gives an `error(...)`
  when the key, IV, data or `auth_data` do not match the tag, never partial
  plaintext. `auth_data` is authenticated, not encrypted.
- KDF: `length` 1 to 1048576, scrypt's `n` a power of 2; values past the
  limits (iterations, scrypt memory about 1 GiB per call) give an `error(...)`.
  OWASP advises 600000 iterations for PBKDF2-HMAC-SHA256, and scrypt with
  `n = 131072, r = 8, p = 1`. A call runs on the compute pool: its task waits
  and the other tasks keep running. Compare a derived key with
  `OpenSSL.HMAC.secure_compare`.
- RSA-OAEP (OAEP with SHA-1, as MySQL's `caching_sha2_password` wants)
  encrypts with an RSA public key in PEM (`BEGIN PUBLIC KEY` or `BEGIN RSA
  PUBLIC KEY`):

```text
OpenSSL.RSA.public_encrypt_oaep(pem: String, data: Bytes) -> Result[Bytes]
```

- The result has the key's size and differs on every call. `data` takes at
  most the key's size less 42 bytes (214 for 2048 bits). A bad PEM, a key that
  is not RSA or data too long is an `error(...)`. It has the `random` effect
  label.

```text
Base64.strict_encode64(data: Bytes) -> String     # padded, one line
Base64.encode64(data: Bytes) -> String            # lines of 60 chars, each ends in "\n"
Base64.urlsafe_encode64(data: Bytes, padding: Bool = true) -> String  # - and _
Base64.strict_decode64(text: String) -> Result[Bytes]
Base64.urlsafe_decode64(text: String) -> Result[Bytes]  # padded or not
Base64.decode64(text: String) -> Bytes            # lenient, never fails
OpenSSL.Digest.hexencode(data: Bytes) -> String          # lowercase
OpenSSL.Digest.hexdecode(text: String) -> Result[Bytes]  # either case
```

- `Base64` and `hexencode` behave as Ruby's (`hexdecode` is Agentica's own
  inverse, `error("invalid hex")`): `strict_decode64` and `urlsafe_decode64`
  give `error("invalid base64")` for anything but base64 (no newlines);
  `decode64` skips other characters and stops at a `=` padding. Text goes
  through `s.bytes` and `String.from_bytes(b)`:
  `Base64.strict_encode64("hi".bytes)`. `Base64` is a reserved type name.

## Secure random

```text
OpenSSL.Random.random_bytes(count: Int = 16) -> Bytes  # OpenSSL RAND_bytes
OpenSSL.Random.hex(count: Int = 16) -> String      # 2 * count lowercase hex digits
OpenSSL.Random.uuid() -> String                    # version 4, 36 chars
```

- Use `OpenSSL.Random` (Ruby's `SecureRandom`) for keys, salts, tokens and
  IDs: `Random` is seeded and `--seed` repeats it, so it is not for secrets.
- `count` outside 0..1048576 halts (`RUNTIME-INVALID-COUNT`). A module constant
  cannot call them.
