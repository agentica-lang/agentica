---
title: Crypto
weight: 6
description: The Crypto builtins, which hash bytes with SHA-256.
---

`Crypto` holds the cryptographic builtins. The VM computes them with OpenSSL, the library it already uses for TLS; nothing is written in Agentica. Today it has one function, `Crypto.sha256`. More (HMAC, a constant-time compare, random bytes) are planned.

## SHA-256

```text
Crypto.sha256(data: List[Int]) -> List[Int]
```

`Crypto.sha256` gives the SHA-256 digest of a list of bytes: 32 integers from 0 to 255. Bytes are a `List[Int]`, as `IO.read_bytes`, `File.read_bytes` and [std/binary](/library/text-and-data/binary/) use. To hash text, hash its UTF-8 bytes from `String.to_bytes`. [`Digest.hexencode`](/library/text-and-data/base64/#hex) writes the digest in hex.

```agentica
def main() -> Void
  digest = Crypto.sha256(String.to_bytes("abc"))
  puts(digest.size)
  puts(Digest.hexencode(digest))
  puts(Digest.hexencode(Crypto.sha256([])))
end
```

```output
32
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

- An item outside 0 to 255 stops the program with `RUNTIME-INVALID-NUMBER` at the argument.
- The time grows with the list. A call is never split, but it counts toward the task's turn, so other tasks run soon after a large hash.
- It needs no effect label: it reads nothing outside its argument.
- `Crypto` is a reserved type name.

```agentica {expect="RUNTIME-INVALID-NUMBER"}
def main() -> Void
  puts(Crypto.sha256([1, 256]))
end
```
