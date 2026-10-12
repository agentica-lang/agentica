## 20. Crypto module

**Status:** on demand: it starts when a real program needs it (signed webhooks, tokens, password storage). It needs `Bytes` (§12.5) and lands only after TLS on the VM (roadmap 7h), since it uses the same OpenSSL 3 library, linked the same way (dynamic by default, `OPENSSL=static` as an option, `docs/vm/10-dependencies-and-platforms.md` 10.0). The VM needs only OpenSSL 3.0.0 and calls only symbols of the `OPENSSL_3.0.0` version node (CI checks it with `objdump -T`): newer features such as Argon2id and `OSSL_set_max_threads` (3.2) are found at run time, and when `EVP_KDF_fetch` returns `NULL` the call returns an error `Result` that names the missing feature. If it lands after 7i, it is VM only.

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
- `password_hash` uses Argon2id when the OpenSSL in use has it (3.2 or later), else scrypt; the hash string carries its algorithm and parameters, so verify needs no settings. `password_verify` of an Argon2id hash on OpenSSL older than 3.2 returns an error `Result`. `OSSL_set_max_threads` (3.2) is looked up at run time too; without it Argon2 runs single-threaded.
- AEAD is AES-256-GCM or ChaCha20-Poly1305. The nonce rule is fixed by the module: `seal` makes a random nonce for each call and puts it in front of the output, so a user never picks or reuses one. `open` fails with `error(...)` on a wrong key or changed data.
- No low-level primitives: no raw block ciphers, no ECB, no unauthenticated modes.
- Errors are `Result` values. Hashes and HMAC have no effect label; `random_bytes`, `password_hash` and `seal` use the existing `random` label.

