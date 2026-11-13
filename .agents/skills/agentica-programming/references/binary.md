# Binary data (`std/binary`)

`import Binary from "std/binary"`. Binary data is a `Bytes`, such as the one
`IO.read_bytes`, `File.read_bytes`, `TCP.recv_bytes` and `Process.read_bytes`
give. The module is written in Agentica on the bit builtins below.

```text
Binary.read_u8(data: Bytes, offset: Int) -> Result[Int]
Binary.read_i8(data: Bytes, offset: Int) -> Result[Int]
Binary.read_u16_be(data, offset) -> Result[Int]     # also _le, i16, u32, i32, u64, i64
Binary.read_f32_be(data, offset) -> Result[Float]   # also _le, f64
Binary.write_u8(value: Int) -> Result[Bytes]
Binary.write_i8(value: Int) -> Result[Bytes]
Binary.write_u16_be(value: Int) -> Result[Bytes]  # also _le, i16, u32, i32, u64
Binary.write_i64_be(value: Int) -> Bytes          # also _le; cannot fail
Binary.write_f32_be(value: Float) -> Bytes        # also _le, f64; cannot fail
Binary.frame(payload: Bytes) -> Result[Bytes]
Binary.read_frame_length(data: Bytes, offset: Int, max: Int) -> Result[Int]
```

- `_be` is big-endian (network order), `_le` little-endian; `u8` and `i8` have
  no suffix. Signed types use two's complement. `offset` is zero-based.
- A reader never halts: an `offset` outside the data is an `error(...)`. A
  writer that can fail (a value outside its type) returns a `Result`;
  `write_i64_*`, `write_f32_*` and `write_f64_*` return a plain `Bytes`, so
  `try` on them is a check error.
- `u64` is `0 .. 9223372036854775807`: `read_u64_*` errors on a top bit set and
  `write_u64_*` rejects a negative value. For all 64 bits (hashes, IDs) use
  `read_i64_*` and `write_i64_*`, which read and write the same bytes.
- Floats: `write_f32_*` rounds; every NaN is written as the canonical NaN.
  `-0.0`, infinities and subnormals are exact.
- Join writer results with `Bytes.concat(parts)`, one copy for any number of
  parts; a loop of `out = out + part` copies the output each time and is O(n²).
  Build `parts` with `map`: `values.map do |v| Binary.write_i64_be(v) end`.
- `frame(payload)` is the 4-byte big-endian length, then the payload.
  `read_frame_length(data, offset, max)` returns the length, or an error above
  `max` (and for a negative `max`), so a program rejects a hostile length before
  it reads the body; then it reads that many bytes itself (`TCP.recv_bytes` and
  `Process.read_bytes` may return fewer).
- No mutable buffers: writers return new `Bytes`, which the program joins.

## Bit operations

```text
Int.bit_and(int: Int, other: Int) -> Int                 # 64-bit two's complement
Int.bit_or(int: Int, other: Int) -> Int
Int.bit_xor(int: Int, other: Int) -> Int
Int.bit_not(int: Int) -> Int                             # -1 - int
Int.shift_left(int: Int, count: Int) -> Int              # wraps; 64 or more gives 0
Int.shift_right(int: Int, count: Int) -> Int             # arithmetic, rounds down; 64 or more gives 0 or -1
Int.shift_right_unsigned(int: Int, count: Int) -> Int    # logical; 64 or more gives 0
Float.to_bits(float: Float) -> Int                       # binary64 bits as an Int; every NaN gives 9221120237041090560
Float.from_bits(bits: Int) -> Float                      # any Int; any NaN pattern gives NaN
Float.to_bits32(float: Float) -> Int                     # rounds to binary32; 0..4294967295; every NaN gives 2143289344
Float.from_bits32(bits: Int) -> Float                    # exact; bits outside 0..4294967295 halt (RUNTIME-INVALID-NUMBER)
```

- A negative shift count halts with `RUNTIME-INVALID-COUNT` at the count.
- Write masks in hex or binary: `0xFF`, `0xFFFF`, `0b1010`.
- `x.shift_right(i).bit_and(1) == 1` tests bit `i`; `x.to_bits < 0` tests the
  sign of a Float (not NaN: use `x != x`).

## Text bytes and hashing

- `String.from_bytes` decodes strictly. A byte read can split a UTF-8 character,
  so decode complete sequences only. `s.bytes` encodes text for
  `File.write_bytes`, `TCP.send_bytes` and the like.
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
