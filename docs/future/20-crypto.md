## 20. Crypto module

**Status:** built (issue #757; see Landed). It uses
`Bytes` (0.17.0, #805) and the same OpenSSL as TLS: the
vendored 3.5 LTS, linked statically, in the release, and the system OpenSSL 3
(3.0 or newer) in a default source build
(`docs/vm/10-dependencies-and-platforms.md` 10.0). So 3.5-only features
(Argon2id, `OSSL_set_max_threads`) are not always there: if one is added,
either raise the minimum in `OSSL_MIN` of mk/vm.mk and the `#error` in
`vm/tls_openssl.c` to 3.5, or check at run time on system builds and return an
error `Result` that names the missing feature. An algorithm left out of a
system build (a FIPS-only OpenSSL has no MD5, SHA-1 or scrypt) stops the call
with `RUNTIME-INTERNAL`, as any failed library call does.

**Landed:** the `Digest` hashes `md5`, `sha1`, `sha256` and `sha512`, each
with a `_hexdigest` form (`Digest.sha256(data: Bytes) -> Bytes`,
`docs/grammar/06b-builtins.md`), on OpenSSL 3.0 or newer through
`vm/digest_openssl.c`, HMAC-SHA256 and HMAC-SHA512
(`HMAC.sha256(key: Bytes, data: Bytes) -> Bytes`, each with a
`_hexdigest` form, Ruby's `OpenSSL::HMAC.digest`), and
`SecureRandom.random_bytes`, `hex` and `uuid` from `RAND_bytes`,
AES-256-GCM (`Cipher.aes_256_gcm_encrypt`, the tag appended to the
ciphertext), and PBKDF2-HMAC-SHA256 and scrypt (`KDF.pbkdf2_hmac_sha256`,
`KDF.scrypt`). They take and give `Bytes` (0.17.0, #805), as the other byte
APIs do. Their names follow Ruby's (`OpenSSL::Cipher.new("aes-256-gcm")`,
`OpenSSL::KDF.pbkdf2_hmac`), flattened as `Digest` and `HMAC` are
(`Digest::SHA256.hexdigest` is `Digest.sha256_hexdigest`). `Crypto` stays a
reserved type name only.

- Hex and Base64 are the `Digest.hexencode`/`hexdecode` and `Base64` builtins
  (`docs/grammar/06b-builtins.md`).
- No low-level primitives: no raw block ciphers, no ECB, no unauthenticated
  modes. The one exception is Triple DES CBC with CMAC (#825), for payment
  formats (`docs/grammar/06b-builtins.md`).
- Errors are `Result` values. Hashes and HMAC have no effect label; the
  calls that draw random bytes use the existing `random` label.

