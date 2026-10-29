---
title: Digest, HMAC and SecureRandom
weight: 6
description: The Digest builtins, which hash bytes with MD5, SHA-1, SHA-256 and SHA-512, the HMAC builtins, which sign bytes with a key and compare MACs in constant time, and SecureRandom, which draws secure random bytes, hex and UUIDs.
---

The cryptographic builtins are computed by the VM with OpenSSL, the library it already uses for TLS; nothing is written in Agentica. Today they are the hashes of the `Digest` namespace, in the forms of Ruby's `Digest::SHA256.digest` and `hexdigest`, the `HMAC` namespace, in the forms of Ruby's `OpenSSL::HMAC.digest` and `hexdigest`, with the constant-time `HMAC.secure_compare` of Ruby's `OpenSSL.secure_compare`, and the secure random draws of `SecureRandom`, as Ruby names them.

## Digests

```text
Digest.md5(data: List[Int]) -> List[Int]
Digest.md5_hexdigest(data: List[Int]) -> String
Digest.sha1(data: List[Int]) -> List[Int]
Digest.sha1_hexdigest(data: List[Int]) -> String
Digest.sha256(data: List[Int]) -> List[Int]
Digest.sha256_hexdigest(data: List[Int]) -> String
Digest.sha512(data: List[Int]) -> List[Int]
Digest.sha512_hexdigest(data: List[Int]) -> String
```

`Digest.sha256` gives the SHA-256 digest of a list of bytes: 32 integers from 0 to 255. `Digest.md5`, `Digest.sha1` and `Digest.sha512` give 16, 20 and 64. Each `_hexdigest` form gives the same digest as lowercase hex, the text that [`Digest.hexencode`](/library/text-and-data/base64/#hex) writes for the bytes. Bytes are a `List[Int]`, as `IO.read_bytes`, `File.read_bytes` and [std/binary](/library/text-and-data/binary/) use. To hash text, hash its UTF-8 bytes from `String.to_bytes`.

```agentica
def main() -> Void
  digest = Digest.sha256(String.to_bytes("abc"))
  puts(digest.size)
  puts(Digest.hexencode(digest))
  puts(Digest.sha256_hexdigest([]))
  puts(Digest.sha512(String.to_bytes("abc")).size)
  puts(Digest.md5_hexdigest(String.to_bytes("abc")))
end
```

```output
32
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
64
900150983cd24fb0d6963f7d28e17f72
```

- MD5 and SHA-1 are broken for security: use them only where a format needs them, such as ETags, git object names or an old API. Use SHA-256 or SHA-512 for anything else.
- An item outside 0 to 255 stops the program with `RUNTIME-INVALID-NUMBER` at the argument.
- A system OpenSSL in FIPS-only mode has no MD5 or SHA-1; `Digest.md5` and `Digest.sha1` (and their `_hexdigest` forms) then stop the program with `RUNTIME-INTERNAL`. The release binaries use their own OpenSSL, which has all four.
- The time grows with the list. A call is never split, but it counts toward the task's turn, so other tasks run soon after a large hash.
- They need no effect label: they read nothing outside their argument.
- `Crypto` and `Digest` are reserved type names.

```agentica {expect="RUNTIME-INVALID-NUMBER"}
def main() -> Void
  puts(Digest.sha256([1, 256]))
end
```

## HMAC

```text
HMAC.sha256(key: List[Int], data: List[Int]) -> List[Int]
HMAC.sha256_hexdigest(key: List[Int], data: List[Int]) -> String
HMAC.sha512(key: List[Int], data: List[Int]) -> List[Int]
HMAC.sha512_hexdigest(key: List[Int], data: List[Int]) -> String
HMAC.secure_compare(a: List[Int], b: List[Int]) -> Bool
```

`HMAC.sha256` gives the HMAC-SHA256 (RFC 2104) of `data` under `key`: 32 integers from 0 to 255. `HMAC.sha512` gives the 64 of HMAC-SHA512. Each `_hexdigest` form gives the same MAC as lowercase hex, as Ruby's `OpenSSL::HMAC.hexdigest("SHA256", key, data)` does. The key can have any length, empty included; a key longer than the hash's block (64 bytes for SHA-256, 128 for SHA-512) is hashed first, as RFC 2104 says. They sign webhook payloads, JSON Web Tokens with HS256 (the MAC in unpadded base64url) and signed URLs.

```agentica
def main() -> Void
  key = String.to_bytes("key")
  data = String.to_bytes("The quick brown fox jumps over the lazy dog")
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

- An item outside 0 to 255, in the key or in the data, stops the program with `RUNTIME-INVALID-NUMBER` at that argument.
- The time grows with the key and the data, as for the digests, and they need no effect label.
- `HMAC` is a reserved type name too.

### Checking a MAC

To check a MAC, signature or token you received, compare it with the one you compute using `HMAC.secure_compare(a, b)`, never with `==`. `==` stops at the first byte that differs, so its time can tell an attacker how much of a forged MAC is right. `HMAC.secure_compare` gives `true` when the two lists hold the same bytes, in a time that does not depend on the bytes or on where they differ: like Ruby's `OpenSSL.secure_compare`, it compares the SHA-256 digests of both lists with OpenSSL's `CRYPTO_memcmp`.

```agentica
def main() -> Void
  key = String.to_bytes("key")
  body = String.to_bytes("{\"event\":\"paid\"}")
  received = HMAC.sha256(key, body)
  puts(HMAC.secure_compare(HMAC.sha256(key, body), received))
  puts(HMAC.secure_compare(HMAC.sha256(key, String.to_bytes("{}")), received))
  puts(HMAC.secure_compare(received, received.take(16)))
end
```

```output
true
false
false
```

- Lists of other lengths give `false`. The time grows with both lengths, so it shows how long the lists are, never what they hold.
- To check a hex MAC, such as the one in a webhook header, decode it first with [`Digest.hexdecode`](/library/text-and-data/base64/#hex); an `error` there means a bad MAC.
- An item outside 0 to 255 stops the program with `RUNTIME-INVALID-NUMBER` at that argument. It needs no effect label.

## SecureRandom

```text
SecureRandom.random_bytes(n: Int = 16) -> List[Int]
SecureRandom.hex(n: Int = 16) -> String
SecureRandom.uuid() -> String
```

`SecureRandom.random_bytes(n)` gives `n` bytes from the secure random generator of OpenSSL (`RAND_bytes`), which the system seeds. `SecureRandom.hex(n)` gives `n` such bytes as `2n` lowercase hex digits. `SecureRandom.uuid` gives a random version 4 UUID (RFC 9562): 36 lowercase characters such as `"2ddb7c9f-b237-4edc-b8ae-d3a42c7135f5"`. Without an argument, `random_bytes` and `hex` draw 16 bytes, as in Ruby.

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
