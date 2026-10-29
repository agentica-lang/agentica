## 20. Crypto module

**Status:** started (issue #757, one PR per item; see Landed and Plan). It needs
`Bytes` (§12.5) to leave `List[Int]` and uses the same OpenSSL as TLS: the
vendored 3.5 LTS, linked statically, in the release, and the system OpenSSL 3
(3.0 or newer) in a default source build
(`docs/vm/10-dependencies-and-platforms.md` 10.0). So 3.5-only features
(Argon2id, `OSSL_set_max_threads`) are not always there: when this work lands,
either raise the minimum in `OSSL_MIN` of mk/vm.mk and the `#error` in
`vm/tls_openssl.c` to 3.5, or check at run time on system builds and return an
error `Result` that names the missing feature. Likewise, when `EVP_KDF_fetch`
still returns `NULL` (an algorithm left out of the build), the call returns an
error `Result` that names the missing feature.

**Landed:** the `Digest` hashes `md5`, `sha1`, `sha256` and `sha512`, each
with a `_hexdigest` form (`Digest.sha256(data: List[Int]) -> List[Int]`,
`docs/grammar/06b-builtins.md`), on OpenSSL 3.0 or newer through
`vm/digest_openssl.c`, HMAC-SHA256 and HMAC-SHA512
(`HMAC.sha256(key: List[Int], data: List[Int]) -> List[Int]`, each with a
`_hexdigest` form, Ruby's `OpenSSL::HMAC.digest`), and
`SecureRandom.random_bytes`, `hex` and `uuid` from `RAND_bytes`. They take and
give `List[Int]` until `Bytes` exists, and move to `Bytes` with the other byte
APIs.

**Plan** (issue #757, one PR each): PBKDF2 and AES-256-GCM. Their names
follow Ruby's (`OpenSSL::PKCS5.pbkdf2_hmac`), flattened as `Digest` and `HMAC`
are (`Digest::SHA256.hexdigest` is `Digest.sha256_hexdigest`); each PR settles
its names. `Crypto` stays a reserved type name only.

- Hex and Base64 are the `Digest.hexencode`/`hexdecode` and `Base64` builtins
  (`docs/grammar/06b-builtins.md`).
- No low-level primitives: no raw block ciphers, no ECB, no unauthenticated
  modes.
- Errors are `Result` values. Hashes and HMAC have no effect label; the
  calls that draw random bytes use the existing `random` label.

