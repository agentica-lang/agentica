## 20. Crypto module

**Status:** on demand: it starts when a real program needs it (signed webhooks,
tokens, password storage). It needs `Bytes` (§12.5) and uses the same OpenSSL as
TLS: the vendored 3.5 LTS, linked statically, in the release, and the system
OpenSSL 3 (3.0 or newer) in a default source build
(`docs/vm/10-dependencies-and-platforms.md` 10.0). So 3.5-only features
(Argon2id, `OSSL_set_max_threads`) are not always there: when this work lands,
either raise the minimum in the Makefile's `OSSL_MIN` and the `#error` in
`vm/tls_openssl.c` to 3.5, or check at run time on system builds and return an
error `Result` that names the missing feature. Likewise, when `EVP_KDF_fetch`
still returns `NULL` (an algorithm left out of the build), the call returns an
error `Result` that names the missing feature.

**Landed:** `Crypto.sha256(data: List[Int]) -> List[Int]` (#455,
`docs/grammar/06b-builtins.md`), on OpenSSL 3.0 or newer through
`vm/digest_openssl.c`. It takes and gives `List[Int]` until `Bytes` exists, and
moves to `Bytes` with the other byte APIs.

**Sketch** (names are not final):

```text
Crypto.sha256(data: Bytes) -> Bytes          # also sha512; blake2b if needed
Crypto.hmac_sha256(key: Bytes, data: Bytes) -> Bytes
Crypto.equal?(a: Bytes, b: Bytes) -> Bool     # constant time
Crypto.random_bytes(n: Int) -> Result[Bytes]  # OS-backed CSPRNG
Crypto.password_hash(password: String) -> Result[String]
Crypto.password_verify(password: String, hash: String) -> Result[Bool]
Crypto.seal(key: Bytes, plain: Bytes) -> Result[Bytes]   # AEAD
Crypto.open(key: Bytes, sealed: Bytes) -> Result[Bytes]
```

- Hex and Base64 encoding go here only if no other module has them by then.
- `password_hash` uses Argon2id (OpenSSL 3.2 or later, so always with the
  vendored 3.5); the hash string carries its algorithm and parameters, so verify
  needs no settings. Argon2 uses `OSSL_set_max_threads` for its lanes.
- AEAD is AES-256-GCM or ChaCha20-Poly1305. The nonce rule is fixed by the
  module: `seal` makes a random nonce for each call and puts it in front of the
  output, so a user never picks or reuses one. `open` fails with `error(...)` on
  a wrong key or changed data.
- No low-level primitives: no raw block ciphers, no ECB, no unauthenticated
  modes.
- Errors are `Result` values. Hashes and HMAC have no effect label;
  `random_bytes`, `password_hash` and `seal` use the existing `random` label.

