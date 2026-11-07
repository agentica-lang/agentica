---
title: OpenSSL
weight: 6
description: The OpenSSL family of builtins. OpenSSL.Digest hashes bytes with MD5, SHA-1, SHA-256 and SHA-512, OpenSSL.HMAC signs bytes with a key and compares MACs in constant time, OpenSSL.Cipher encrypts with AES-256-GCM and Triple DES CBC, OpenSSL.KDF hashes passwords with PBKDF2 and scrypt, OpenSSL.CMAC gives the MACs of payment formats, OpenSSL.RSA encrypts with a public key, and OpenSSL.Random draws secure random bytes, hex and UUIDs.
---

The VM computes these builtins with OpenSSL, the library it already uses for TLS; nothing is written in Agentica. They are the members of the `OpenSSL` family, written `OpenSSL.Member.function`, and the names and forms follow Ruby:

- `OpenSSL.Digest`: the hashes, as Ruby's `Digest::SHA256.digest` and `hexdigest`.
- `OpenSSL.HMAC`: the MACs, as `OpenSSL::HMAC`, and the constant-time `OpenSSL.HMAC.secure_compare`, as Ruby's `OpenSSL.secure_compare`.
- `OpenSSL.Cipher`: AES-256-GCM, as `OpenSSL::Cipher.new("aes-256-gcm")`, and Triple DES CBC.
- `OpenSSL.KDF`: the password hashes, as `OpenSSL::KDF`.
- `OpenSSL.CMAC`: the CMACs of payment formats.
- `OpenSSL.RSA`: encryption with an RSA public key, as `OpenSSL::PKey::RSA`.
- `OpenSSL.Random`: the secure random draws, as Ruby's `SecureRandom`.

`OpenSSL` is the one reserved name of the family: `Digest`, `Cipher` or `Random` stay free for a type or an import alias of the program. A member the family lacks, such as `OpenSSL.Ciphr`, is `CHECK-UNKNOWN-NAME`, and its help lists the members.

```agentica {expect="CHECK-UNKNOWN-NAME"}
def main() -> Void
  puts(OpenSSL.Digst.sha256_hexdigest("abc".bytes))
end
```

## Digests

```signature
OpenSSL.Digest.md5(data: Bytes) -> Bytes
OpenSSL.Digest.md5_hexdigest(data: Bytes) -> String
OpenSSL.Digest.sha1(data: Bytes) -> Bytes
OpenSSL.Digest.sha1_hexdigest(data: Bytes) -> String
OpenSSL.Digest.sha256(data: Bytes) -> Bytes
OpenSSL.Digest.sha256_hexdigest(data: Bytes) -> String
OpenSSL.Digest.sha512(data: Bytes) -> Bytes
OpenSSL.Digest.sha512_hexdigest(data: Bytes) -> String
```

`OpenSSL.Digest.sha256` gives the SHA-256 digest of a [`Bytes`](/library/data-structures/bytes/) as a `Bytes` of 32 bytes. `OpenSSL.Digest.md5`, `OpenSSL.Digest.sha1` and `OpenSSL.Digest.sha512` give 16, 20 and 64. Each `_hexdigest` form gives the same digest as lowercase hex, the text that [`OpenSSL.Digest.hexencode`](/library/text-and-data/base64/#hex) writes for the bytes. To hash text, hash its UTF-8 bytes from `s.bytes`; a `List[Int]` becomes a `Bytes` with `Bytes.from_list`.

```agentica
def main() -> Void
  digest = OpenSSL.Digest.sha256("abc".bytes)
  puts(digest.size)
  puts(OpenSSL.Digest.hexencode(digest))
  puts(OpenSSL.Digest.sha256_hexdigest("".bytes))
  puts(OpenSSL.Digest.sha512("abc".bytes).size)
  puts(OpenSSL.Digest.md5_hexdigest("abc".bytes))
  puts(digest == OpenSSL.Digest.sha256("abc".bytes))
end
```

```output
32
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
64
900150983cd24fb0d6963f7d28e17f72
true
```

- MD5 and SHA-1 are broken for security: use them only where a format needs them, such as ETags, git object names or an old API. Use SHA-256 or SHA-512 for anything else.
- Two digests compare with `==`. `==` is not constant time: to check a MAC or a token you received, use [`OpenSSL.HMAC.secure_compare`](#checking-a-mac).
- A system OpenSSL in FIPS-only mode has no MD5 or SHA-1; `OpenSSL.Digest.md5` and `OpenSSL.Digest.sha1` (and their `_hexdigest` forms) then stop the program with `RUNTIME-INTERNAL`. The release binaries use their own OpenSSL, which has all four.
- The time grows with the data. A call is never split, but it counts toward the task's turn, so other tasks run soon after a large hash.
- They need no effect label: they read nothing outside their argument.

A `List[Int]` is not a `Bytes`; convert it once with `Bytes.from_list`, which gives an error for an item outside 0 to 255.

```agentica {expect="CHECK-TYPE-MISMATCH"}
def main() -> Void
  puts(OpenSSL.Digest.sha256_hexdigest([1, 2]))
end
```

## HMAC

```signature
OpenSSL.HMAC.sha256(key: Bytes, data: Bytes) -> Bytes
OpenSSL.HMAC.sha256_hexdigest(key: Bytes, data: Bytes) -> String
OpenSSL.HMAC.sha512(key: Bytes, data: Bytes) -> Bytes
OpenSSL.HMAC.sha512_hexdigest(key: Bytes, data: Bytes) -> String
OpenSSL.HMAC.secure_compare(a: Bytes, b: Bytes) -> Bool
```

`OpenSSL.HMAC.sha256` gives the HMAC-SHA256 (RFC 2104) of `data` under `key`: a `Bytes` of 32 bytes. `OpenSSL.HMAC.sha512` gives the 64 of HMAC-SHA512. Each `_hexdigest` form gives the same MAC as lowercase hex, as Ruby's `OpenSSL::HMAC.hexdigest("SHA256", key, data)` does. The key can have any length, empty included; a key longer than the hash's block (64 bytes for SHA-256, 128 for SHA-512) is hashed first, as RFC 2104 says. They sign webhook payloads, JSON Web Tokens with HS256 (the MAC in unpadded base64url) and signed URLs.

```agentica
def main() -> Void
  key = "key".bytes
  data = "The quick brown fox jumps over the lazy dog".bytes
  puts(OpenSSL.HMAC.sha256_hexdigest(key, data))
  puts(OpenSSL.HMAC.sha512(key, data).size)
  puts(Base64.urlsafe_encode64(OpenSSL.HMAC.sha256(key, data), false))
end
```

```output
f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8
64
97yD9DBThCSxMpjmqm-xQ-9NWaFJRhdZl0edvC0aPNg
```

- The time grows with the key and the data, as for the digests, and they need no effect label.

### Checking a MAC

To check a MAC, signature or token you received, compare it with the one you compute using `OpenSSL.HMAC.secure_compare(a, b)`, never with `==`. `==` on `Bytes` is not constant time: it stops at the first byte that differs, so its time can tell an attacker how much of a forged MAC is right. `OpenSSL.HMAC.secure_compare` gives `true` when the two values hold the same bytes, in a time that does not depend on the bytes or on where they differ: like Ruby's `OpenSSL.secure_compare`, it compares the SHA-256 digests of both with OpenSSL's `CRYPTO_memcmp`.

```agentica
def main() -> Void
  key = "key".bytes
  body = "{\"event\":\"paid\"}".bytes
  received = OpenSSL.HMAC.sha256(key, body)
  puts(OpenSSL.HMAC.secure_compare(OpenSSL.HMAC.sha256(key, body), received))
  puts(OpenSSL.HMAC.secure_compare(OpenSSL.HMAC.sha256(key, "{}".bytes), received))
  puts(OpenSSL.HMAC.secure_compare(received, received.take(16)))
end
```

```output
true
false
false
```

- Values of other lengths give `false`. The time grows with both lengths, so it shows how long the values are, never what they hold.
- To check a hex MAC, such as the one in a webhook header, decode it first with [`OpenSSL.Digest.hexdecode`](/library/text-and-data/base64/#hex); an `error` there means a bad MAC.
- It needs no effect label.

## AES-256-GCM

```signature
OpenSSL.Cipher.aes_256_gcm_encrypt(key: Bytes, iv: Bytes, data: Bytes, auth_data: Bytes = "".bytes) -> Result[Bytes]
OpenSSL.Cipher.aes_256_gcm_decrypt(key: Bytes, iv: Bytes, data: Bytes, auth_data: Bytes = "".bytes) -> Result[Bytes]
```

`OpenSSL.Cipher.aes_256_gcm_encrypt` encrypts `data` with AES-256-GCM, as Ruby's `OpenSSL::Cipher.new("aes-256-gcm")` does, and gives the ciphertext with the 16-byte tag appended: 16 bytes more than `data`. `OpenSSL.Cipher.aes_256_gcm_decrypt` takes that form back. It gives the plaintext only when the tag matches the key, the IV, the ciphertext and `auth_data`; anything changed gives an `error`, and no part of the plaintext. `auth_data` is authenticated but not encrypted: a header, a record id or a version that the receiver reads in the clear and must not be swapped.

```agentica
def main() -> Void
  key = OpenSSL.Digest.hexdecode("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308").unwrap!
  iv = OpenSSL.Digest.hexdecode("cafebabefacedbaddecaf888").unwrap!
  header = "record 7".bytes
  sealed = OpenSSL.Cipher.aes_256_gcm_encrypt(key, iv, "attack at dawn".bytes, header).unwrap!
  puts(sealed.size)
  puts(OpenSSL.Digest.hexencode(sealed))
  opened = OpenSSL.Cipher.aes_256_gcm_decrypt(key, iv, sealed, header).unwrap!
  puts(String.from_bytes(opened).unwrap!)
  puts(OpenSSL.Cipher.aes_256_gcm_decrypt(key, iv, sealed, "record 8".bytes).ok?)
  puts(OpenSSL.Cipher.aes_256_gcm_decrypt(key, iv, sealed).ok?)
end
```

```output
30
ea6887b402b95b8325065a07f21f0e754294b29d6398414d4a28a9fb3317
attack at dawn
false
false
```

- The key has 32 bytes; draw it with [`OpenSSL.Random.random_bytes(32)`](#random) or derive it with [`OpenSSL.KDF`](#password-hashing).
- The IV (the nonce) has 12 bytes and must never be used twice with the same key: two messages under one key and IV leak the XOR of their plaintexts and let anyone forge tags. Draw a new one for each message with `OpenSSL.Random.random_bytes(12)` and send it beside the sealed bytes; it need not be secret.
- A key or IV of another size, sealed bytes shorter than the tag, or more than 2^36 - 32 bytes to encrypt gives an `error`, before any work.
- The time grows with the data and `auth_data`, and they need no effect label.

## Password hashing

```signature
OpenSSL.KDF.pbkdf2_hmac_sha256(password: Bytes, salt: Bytes, iterations: Int, length: Int) -> Result[Bytes]
OpenSSL.KDF.scrypt(password: Bytes, salt: Bytes, n: Int, r: Int, p: Int, length: Int) -> Result[Bytes]
```

A password hash is slow on purpose, so that guessing passwords from a stolen hash is slow too. `OpenSSL.KDF.pbkdf2_hmac_sha256` gives `length` bytes of PBKDF2 (RFC 8018) with HMAC-SHA256, as Ruby's `OpenSSL::KDF.pbkdf2_hmac` with `hash: "SHA256"` does; its cost is `iterations`. `OpenSSL.KDF.scrypt` gives `length` bytes of scrypt (RFC 7914), as Ruby's `OpenSSL::KDF.scrypt` does, which also needs memory: `n` is the cost, a power of 2, `r` the block size and `p` the parallelization. Store the salt (16 random bytes per password) and the parameters beside the hash, derive again from the password given, and compare with [`OpenSSL.HMAC.secure_compare`](#checking-a-mac). The same calls derive an encryption key from a passphrase.

```agentica
def main() -> Void
  salt = OpenSSL.Digest.hexdecode("8d2f1e0a9c6b5a4f3e2d1c0b9a8f7e6d").unwrap!
  stored = OpenSSL.KDF.pbkdf2_hmac_sha256("correct horse".bytes, salt, 600000, 32).unwrap!
  puts(OpenSSL.Digest.hexencode(stored))
  attempt = OpenSSL.KDF.pbkdf2_hmac_sha256("correct horse".bytes, salt, 600000, 32).unwrap!
  puts(OpenSSL.HMAC.secure_compare(attempt, stored))
  wrong = OpenSSL.KDF.pbkdf2_hmac_sha256("Correct horse".bytes, salt, 600000, 32).unwrap!
  puts(OpenSSL.HMAC.secure_compare(wrong, stored))
  key = OpenSSL.KDF.scrypt("correct horse".bytes, salt, 16384, 8, 1, 32).unwrap!
  puts(OpenSSL.Digest.hexencode(key))
  puts(OpenSSL.KDF.pbkdf2_hmac_sha256("pw".bytes, salt, 0, 32).ok?)
end
```

```output
685d9f0664089a1dceb6bfec27db35482562804c30a3669a9224cea9240f6609
true
false
8840f2f4d9d646327d081885af746152d33cef9cb0e22384713790a75b136ce2
false
```

- `iterations` is at least 1 and `length` from 1 to 1048576; the password and the salt have at most 1048576 bytes each.
- scrypt's `n` is above 1 and below 2^(16 * r), `r` and `p` are at least 1 with `r * p` below 2^30, and the memory, 128 * r * (n + p + 2) bytes, is at most 1025 MiB. That memory is native, outside the garbage collector, so each call may take up to about 1 GiB while it runs. With `n = 16384` and `r = 8` it is about 16 MiB.
- Any other value gives an `error`, before any work.
- OWASP's password storage cheat sheet advises 600000 iterations for PBKDF2-HMAC-SHA256, and scrypt with `n = 131072`, `r = 8` and `p = 1`.
- A call runs on the compute pool, the threads of `compute def` native calls: the task waits, and the other tasks keep running. A cancelled task's call is skipped if it has not started; once started, it runs to its end and its key is dropped. Inside a callback of native code a call is `RUNTIME-NATIVE-CALLBACK`, since that callback cannot wait. A started call cannot be stopped, by `--max-steps` or a signal either, and it holds a compute pool thread until it ends. So the work is capped, and a valid call takes tens of seconds at most: `iterations * ceil(length / 32)` is at most 50000000 for PBKDF2, and `r * p * (n + 16)` at most 2^25 (33554432) for scrypt, about 80 and 32 times the OWASP figures above.
- They need no effect label.

## Triple DES and CMAC

```signature
OpenSSL.Cipher.des_ede3_cbc_encrypt(key: Bytes, iv: Bytes, data: Bytes) -> Result[Bytes]
OpenSSL.Cipher.des_ede3_cbc_decrypt(key: Bytes, iv: Bytes, data: Bytes) -> Result[Bytes]
OpenSSL.CMAC.aes(key: Bytes, data: Bytes) -> Result[Bytes]
OpenSSL.CMAC.des_ede3(key: Bytes, data: Bytes) -> Result[Bytes]
```

Payment messages use Triple DES and CMAC: PIN blocks, key check values and the MACs of ISO 8583 messages. These builtins are for such formats, not for new designs; Triple DES CBC is not authenticated, and its 8-byte blocks are small. They give only what OpenSSL gives: the message formats, BCD and the ISO 9797-1 MAC algorithms belong to a package.

`OpenSSL.Cipher.des_ede3_cbc_encrypt` encrypts `data` with Triple DES in CBC mode and no padding, as Ruby's `OpenSSL::Cipher.new("des-ede3-cbc")` with `padding = 0` does, and `OpenSSL.Cipher.des_ede3_cbc_decrypt` decrypts it. The key has 24 bytes, or 16 for a two-key key (K1 K2, which runs as K1 K2 K1); the IV has 8 bytes; the data is whole blocks of 8 bytes, and the result has the same size. Pad the data as your format says before you encrypt it.

```agentica
def main() -> Void
  key = OpenSSL.Digest.hexdecode("0123456789abcdeffedcba9876543210").unwrap!
  iv = Bytes.from_list(List.repeat(0, 8)).unwrap!
  sealed = OpenSSL.Cipher.des_ede3_cbc_encrypt(key, iv, "PIN 1234".bytes).unwrap!
  puts(OpenSSL.Digest.hexencode(sealed))
  opened = OpenSSL.Cipher.des_ede3_cbc_decrypt(key, iv, sealed).unwrap!
  puts(String.from_bytes(opened).unwrap!)
  check_value = OpenSSL.Cipher.des_ede3_cbc_encrypt(key, iv, iv).unwrap!.take(3)
  puts(OpenSSL.Digest.hexencode(check_value))
  puts(OpenSSL.Cipher.des_ede3_cbc_encrypt(key, iv, "PIN".bytes).ok?)
end
```

```output
1a3be5be6098e0d3
PIN 1234
08d7b4
false
```

`OpenSSL.CMAC.aes` gives the CMAC (NIST SP 800-38B, RFC 4493) of `data` with AES: the key has 16, 24 or 32 bytes, for AES-128, AES-192 or AES-256, and the tag has 16 bytes. `OpenSSL.CMAC.des_ede3` gives it with Triple DES, under a key of 24 or 16 bytes, and the tag has 8 bytes. Both give the full tag; when a format sends a shorter MAC, take its first bytes and check it with [`OpenSSL.HMAC.secure_compare`](#checking-a-mac).

```agentica
def main() -> Void
  key = OpenSSL.Digest.hexdecode("2b7e151628aed2a6abf7158809cf4f3c").unwrap!
  message = "0200 payment message".bytes
  tag = OpenSSL.CMAC.aes(key, message).unwrap!
  puts(OpenSSL.Digest.hexencode(tag))
  mac = tag.take(8)
  puts(OpenSSL.HMAC.secure_compare(OpenSSL.CMAC.aes(key, message).unwrap!.take(8), mac))
  tdes_key = OpenSSL.Digest.hexdecode("0123456789abcdeffedcba9876543210").unwrap!
  puts(OpenSSL.CMAC.des_ede3(tdes_key, message).unwrap!.size)
  puts(OpenSSL.CMAC.aes(key.take(10), message).ok?)
end
```

```output
384be8227f8ea73df2a5fe3da6056b99
true
8
false
```

- A key, IV or data of another size gives an `error`, before any work: there is never partial output.
- The time grows with the data, and they need no effect label.

## RSA-OAEP

```signature
OpenSSL.RSA.public_encrypt_oaep(pem: String, data: Bytes) -> Result[Bytes]
```

`OpenSSL.RSA.public_encrypt_oaep` encrypts `data` with the RSA public key in `pem` and OAEP padding with SHA-1 and MGF1-SHA-1, as Ruby's `OpenSSL::PKey::RSA.new(pem).public_encrypt(data, OpenSSL::PKey::RSA::PKCS1_OAEP_PADDING)` does. Only the owner of the private key can decrypt the result. MySQL's `caching_sha2_password` and `sha256_password` use it to send a password to the server without TLS. `pem` holds the key as `-----BEGIN PUBLIC KEY-----` (SubjectPublicKeyInfo, what `openssl pkey -pubout` writes) or as `-----BEGIN RSA PUBLIC KEY-----` (PKCS#1); only its first PEM block is read. The result has the size of the key, 256 bytes for a 2048-bit key, and differs on every call, since OAEP draws a random seed each time.

```agentica
PEM = (
  "-----BEGIN PUBLIC KEY-----\n" +
  "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAs1ZCN9Wxre/bu7dwEeju\n" +
  "bBLygVJkUck+jMQuh8glJPrdzdDsmANl87e/f2/AC2+hmGVaXDCQhORyMBqRT0NW\n" +
  "NhdqwGviyW+lp3h6494ioX3HPTXyoauDWT4Ur2CKaetLO0iH/54vGQGyKGsKxCdD\n" +
  "kGV6hiftn3LKzq3rQ2k4lPEbam2V4SppaSG/d7iR/l4qVzKbPbIa3QqK75JI+PbI\n" +
  "rj5O9zKgeWS1VCVLMjp5GmUH3blNqbMo4bqm8uEBwD0R4/XgksAyV/xwDn/YUGm5\n" +
  "Ge3bi1fuS5ec3N0d6Nym9ueD1PV/s8luy+YYpBxw6d1o5fN/rA+crcKQf4xyquRS\n" +
  "kQIDAQAB\n" +
  "-----END PUBLIC KEY-----\n"
)

def main() -> Void
  sealed = OpenSSL.RSA.public_encrypt_oaep(PEM, "secret password".bytes).unwrap!
  puts(sealed.size)
  puts(sealed == OpenSSL.RSA.public_encrypt_oaep(PEM, "secret password".bytes).unwrap!)
  puts(OpenSSL.RSA.public_encrypt_oaep(PEM, OpenSSL.Random.random_bytes(215)).ok?)
  puts(OpenSSL.RSA.public_encrypt_oaep("not a key", "x".bytes).ok?)
end
```

```output
256
false
false
false
```

- `data` has at most the key's size less 42 bytes: 214 for a 2048-bit key, 470 for a 4096-bit key. To send more, encrypt it with [AES-256-GCM](#aes-256-gcm) under a random key and encrypt that key with RSA.
- A `pem` with no PEM public key (a private key and a certificate included), over 65536 bytes, a key that is not RSA (EC or RSA-PSS), data too long for the key, or a key that cannot encrypt (42 bytes or less, more than 16384 bits, an even modulus, or an exponent that is even, 1 or longer than 64 bits) gives an `error`. A failure inside OpenSSL itself, such as no random bytes for the seed, stops the program with `RUNTIME-INTERNAL`.
- It only encrypts: no private keys, signatures, other paddings or key generation.
- The work is one public-key operation, bounded by those limits, and it needs the `random` effect label, as `OpenSSL.Random` does, so a module constant cannot call it.

## Random

```signature
OpenSSL.Random.random_bytes(n: Int = 16) -> Bytes
OpenSSL.Random.hex(n: Int = 16) -> String
OpenSSL.Random.uuid() -> String
```

`OpenSSL.Random.random_bytes(n)` gives a `Bytes` of `n` bytes from the secure random generator of OpenSSL (`RAND_bytes`), which the system seeds. `OpenSSL.Random.hex(n)` gives `n` such bytes as `2n` lowercase hex digits. `OpenSSL.Random.uuid` gives a random version 4 UUID (RFC 9562): 36 lowercase characters such as `"2ddb7c9f-b237-4edc-b8ae-d3a42c7135f5"`. Without an argument, `random_bytes` and `hex` draw 16 bytes, as in Ruby.

```agentica
def main() -> Void
  key = OpenSSL.Random.random_bytes(32)
  puts(key.size)
  puts(OpenSSL.Random.hex.size)
  id = OpenSSL.Random.uuid
  puts(id.size)
  puts(String.slice(id, 14, 1))
end
```

```output
32
32
36
4
```

Each run gives other values.

- Use `OpenSSL.Random` for keys, salts, session tokens, password reset links and IDs that must not be guessed. [`Random`](/library/io-and-system/system/#randomint) is seeded and `--seed` repeats it, so it is not for secrets.
- `n` must be from 0 to 1048576 (1 MiB); any other `n` stops the program with `RUNTIME-INVALID-COUNT` at the argument. A key or a token needs 16 to 64 bytes.
- If the system cannot give random bytes, the call stops the program with `RUNTIME-INTERNAL`. It never gives weak bytes instead.
- The calls have the `random` effect label, so a module constant cannot call them. The time of `random_bytes` and `hex` grows with `n`.

```agentica {expect="RUNTIME-INVALID-COUNT"}
def main() -> Void
  puts(OpenSSL.Random.hex(-1))
end
```
