---
title: Digest, HMAC and SecureRandom
weight: 6
description: The Digest builtins, which hash bytes with MD5, SHA-1, SHA-256 and SHA-512, the HMAC builtins, which sign bytes with a key and compare MACs in constant time, Triple DES CBC and CMAC for payment formats, and SecureRandom, which draws secure random bytes, hex and UUIDs.
---

The cryptographic builtins are computed by the VM with OpenSSL, the library it already uses for TLS; nothing is written in Agentica. Today they are the hashes of the `Digest` namespace, in the forms of Ruby's `Digest::SHA256.digest` and `hexdigest`, the `HMAC` namespace, in the forms of Ruby's `OpenSSL::HMAC.digest` and `hexdigest`, with the constant-time `HMAC.secure_compare` of Ruby's `OpenSSL.secure_compare`, Triple DES CBC (`Cipher`, named after Ruby's `OpenSSL::Cipher.new("des-ede3-cbc")`) and `CMAC` for payment formats, and the secure random draws of `SecureRandom`, as Ruby names them.

## Digests

```text
Digest.md5(data: Bytes) -> Bytes
Digest.md5_hexdigest(data: Bytes) -> String
Digest.sha1(data: Bytes) -> Bytes
Digest.sha1_hexdigest(data: Bytes) -> String
Digest.sha256(data: Bytes) -> Bytes
Digest.sha256_hexdigest(data: Bytes) -> String
Digest.sha512(data: Bytes) -> Bytes
Digest.sha512_hexdigest(data: Bytes) -> String
```

`Digest.sha256` gives the SHA-256 digest of a [`Bytes`](/library/data-structures/bytes/) as a `Bytes` of 32 bytes. `Digest.md5`, `Digest.sha1` and `Digest.sha512` give 16, 20 and 64. Each `_hexdigest` form gives the same digest as lowercase hex, the text that [`Digest.hexencode`](/library/text-and-data/base64/#hex) writes for the bytes. To hash text, hash its UTF-8 bytes from `s.bytes`; a `List[Int]` becomes a `Bytes` with `Bytes.from_list`.

```agentica
def main() -> Void
  digest = Digest.sha256("abc".bytes)
  puts(digest.size)
  puts(Digest.hexencode(digest))
  puts(Digest.sha256_hexdigest("".bytes))
  puts(Digest.sha512("abc".bytes).size)
  puts(Digest.md5_hexdigest("abc".bytes))
  puts(digest == Digest.sha256("abc".bytes))
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
- Two digests compare with `==`. `==` is not constant time: to check a MAC or a token you received, use [`HMAC.secure_compare`](#checking-a-mac).
- A system OpenSSL in FIPS-only mode has no MD5 or SHA-1; `Digest.md5` and `Digest.sha1` (and their `_hexdigest` forms) then stop the program with `RUNTIME-INTERNAL`. The release binaries use their own OpenSSL, which has all four.
- The time grows with the data. A call is never split, but it counts toward the task's turn, so other tasks run soon after a large hash.
- They need no effect label: they read nothing outside their argument.
- `Crypto` and `Digest` are reserved type names.

A `List[Int]` is not a `Bytes`; convert it once with `Bytes.from_list`, which gives an error for an item outside 0 to 255.

```agentica {expect="CHECK-TYPE-MISMATCH"}
def main() -> Void
  puts(Digest.sha256_hexdigest([1, 2]))
end
```

## HMAC

```text
HMAC.sha256(key: Bytes, data: Bytes) -> Bytes
HMAC.sha256_hexdigest(key: Bytes, data: Bytes) -> String
HMAC.sha512(key: Bytes, data: Bytes) -> Bytes
HMAC.sha512_hexdigest(key: Bytes, data: Bytes) -> String
HMAC.secure_compare(a: Bytes, b: Bytes) -> Bool
```

`HMAC.sha256` gives the HMAC-SHA256 (RFC 2104) of `data` under `key`: a `Bytes` of 32 bytes. `HMAC.sha512` gives the 64 of HMAC-SHA512. Each `_hexdigest` form gives the same MAC as lowercase hex, as Ruby's `OpenSSL::HMAC.hexdigest("SHA256", key, data)` does. The key can have any length, empty included; a key longer than the hash's block (64 bytes for SHA-256, 128 for SHA-512) is hashed first, as RFC 2104 says. They sign webhook payloads, JSON Web Tokens with HS256 (the MAC in unpadded base64url) and signed URLs.

```agentica
def main() -> Void
  key = "key".bytes
  data = "The quick brown fox jumps over the lazy dog".bytes
  puts(HMAC.sha256_hexdigest(key, data))
  puts(HMAC.sha512(key, data).size)
  puts(Base64.urlsafe_encode64(HMAC.sha256(key, data), false))
end
```

```output
f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8
64
97yD9DBThCSxMpjmqm-xQ-9NWaFJRhdZl0edvC0aPNg
```

- The time grows with the key and the data, as for the digests, and they need no effect label.
- `HMAC` is a reserved type name too.

### Checking a MAC

To check a MAC, signature or token you received, compare it with the one you compute using `HMAC.secure_compare(a, b)`, never with `==`. `==` on `Bytes` is not constant time: it stops at the first byte that differs, so its time can tell an attacker how much of a forged MAC is right. `HMAC.secure_compare` gives `true` when the two values hold the same bytes, in a time that does not depend on the bytes or on where they differ: like Ruby's `OpenSSL.secure_compare`, it compares the SHA-256 digests of both with OpenSSL's `CRYPTO_memcmp`.

```agentica
def main() -> Void
  key = "key".bytes
  body = "{\"event\":\"paid\"}".bytes
  received = HMAC.sha256(key, body)
  puts(HMAC.secure_compare(HMAC.sha256(key, body), received))
  puts(HMAC.secure_compare(HMAC.sha256(key, "{}".bytes), received))
  puts(HMAC.secure_compare(received, received.take(16)))
end
```

```output
true
false
false
```

- Values of other lengths give `false`. The time grows with both lengths, so it shows how long the values are, never what they hold.
- To check a hex MAC, such as the one in a webhook header, decode it first with [`Digest.hexdecode`](/library/text-and-data/base64/#hex); an `error` there means a bad MAC.
- It needs no effect label.

## Triple DES and CMAC

```text
Cipher.des_ede3_cbc_encrypt(key: Bytes, iv: Bytes, data: Bytes) -> Result[Bytes]
Cipher.des_ede3_cbc_decrypt(key: Bytes, iv: Bytes, data: Bytes) -> Result[Bytes]
CMAC.aes(key: Bytes, data: Bytes) -> Result[Bytes]
CMAC.des_ede3(key: Bytes, data: Bytes) -> Result[Bytes]
```

Payment messages use Triple DES and CMAC: PIN blocks, key check values and the MACs of ISO 8583 messages. These builtins are for such formats, not for new designs; Triple DES CBC is not authenticated, and its 8-byte blocks are small. They give only what OpenSSL gives: the message formats, BCD and the ISO 9797-1 MAC algorithms belong to a package.

`Cipher.des_ede3_cbc_encrypt` encrypts `data` with Triple DES in CBC mode and no padding, as Ruby's `OpenSSL::Cipher.new("des-ede3-cbc")` with `padding = 0` does, and `Cipher.des_ede3_cbc_decrypt` decrypts it. The key has 24 bytes, or 16 for a two-key key (K1 K2, which runs as K1 K2 K1); the IV has 8 bytes; the data is whole blocks of 8 bytes, and the result has the same size. Pad the data as your format says before you encrypt it.

```agentica
def main() -> Void
  key = Digest.hexdecode("0123456789abcdeffedcba9876543210").unwrap!
  iv = Bytes.from_list(List.repeat(0, 8)).unwrap!
  sealed = Cipher.des_ede3_cbc_encrypt(key, iv, "PIN 1234".bytes).unwrap!
  puts(Digest.hexencode(sealed))
  opened = Cipher.des_ede3_cbc_decrypt(key, iv, sealed).unwrap!
  puts(String.from_bytes(opened).unwrap!)
  check_value = Cipher.des_ede3_cbc_encrypt(key, iv, iv).unwrap!.take(3)
  puts(Digest.hexencode(check_value))
  puts(Cipher.des_ede3_cbc_encrypt(key, iv, "PIN".bytes).ok?)
end
```

```output
1a3be5be6098e0d3
PIN 1234
08d7b4
false
```

`CMAC.aes` gives the CMAC (NIST SP 800-38B, RFC 4493) of `data` with AES: the key has 16, 24 or 32 bytes, for AES-128, AES-192 or AES-256, and the tag has 16 bytes. `CMAC.des_ede3` gives it with Triple DES, under a key of 24 or 16 bytes, and the tag has 8 bytes. Both give the full tag; when a format sends a shorter MAC, take its first bytes and check it with [`HMAC.secure_compare`](#checking-a-mac).

```agentica
def main() -> Void
  key = Digest.hexdecode("2b7e151628aed2a6abf7158809cf4f3c").unwrap!
  message = "0200 payment message".bytes
  tag = CMAC.aes(key, message).unwrap!
  puts(Digest.hexencode(tag))
  mac = tag.take(8)
  puts(HMAC.secure_compare(CMAC.aes(key, message).unwrap!.take(8), mac))
  tdes_key = Digest.hexdecode("0123456789abcdeffedcba9876543210").unwrap!
  puts(CMAC.des_ede3(tdes_key, message).unwrap!.size)
  puts(CMAC.aes(key.take(10), message).ok?)
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
- `Cipher` and `CMAC` are reserved type names.

## SecureRandom

```text
SecureRandom.random_bytes(n: Int = 16) -> Bytes
SecureRandom.hex(n: Int = 16) -> String
SecureRandom.uuid() -> String
```

`SecureRandom.random_bytes(n)` gives a `Bytes` of `n` bytes from the secure random generator of OpenSSL (`RAND_bytes`), which the system seeds. `SecureRandom.hex(n)` gives `n` such bytes as `2n` lowercase hex digits. `SecureRandom.uuid` gives a random version 4 UUID (RFC 9562): 36 lowercase characters such as `"2ddb7c9f-b237-4edc-b8ae-d3a42c7135f5"`. Without an argument, `random_bytes` and `hex` draw 16 bytes, as in Ruby.

```agentica
def main() -> Void
  key = SecureRandom.random_bytes(32)
  puts(key.size)
  puts(SecureRandom.hex.size)
  id = SecureRandom.uuid
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

- Use `SecureRandom` for keys, salts, session tokens, password reset links and IDs that must not be guessed. [`Random`](/library/io-and-system/system/#randomint) is seeded and `--seed` repeats it, so it is not for secrets.
- `n` must be from 0 to 1048576 (1 MiB); any other `n` stops the program with `RUNTIME-INVALID-COUNT` at the argument. A key or a token needs 16 to 64 bytes.
- If the system cannot give random bytes, the call stops the program with `RUNTIME-INTERNAL`. It never gives weak bytes instead.
- The calls have the `random` effect label, so a module constant cannot call them. The time of `random_bytes` and `hex` grows with `n`.
- `SecureRandom` is a reserved type name.

```agentica {expect="RUNTIME-INVALID-COUNT"}
def main() -> Void
  puts(SecureRandom.hex(-1))
end
```
