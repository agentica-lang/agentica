---
title: Crypto
weight: 6
description: The Digest builtins, which hash bytes with MD5, SHA-1, SHA-256 and SHA-512.
---

The cryptographic builtins are computed by the VM with OpenSSL, the library it already uses for TLS; nothing is written in Agentica. Today they are the hashes of the `Digest` namespace, in the forms of Ruby's `Digest::SHA256.digest` and `hexdigest`. More (HMAC, a constant-time compare, random bytes) are planned.

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
- The time grows with the list. A call is never split, but it counts toward the task's turn, so other tasks run soon after a large hash.
- They need no effect label: they read nothing outside their argument.
- `Crypto` and `Digest` are reserved type names.

```agentica {expect="RUNTIME-INVALID-NUMBER"}
def main() -> Void
  puts(Digest.sha256([1, 256]))
end
```
