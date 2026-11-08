/*
 * The digest adapter interface: one-shot hashes and HMACs for the Digest and
 * HMAC builtins (crypto.c), an incremental SHA-256 for the File hash
 * (files.c), secure random bytes for OpenSSL.Random, a constant-time compare,
 * Triple DES CBC, AES-256-GCM and CMAC (Cipher, CMAC), PBKDF2 and scrypt (KDF),
 * RSA-OAEP with a PEM public key (RSA), and the wipe of a secret. The OpenSSL
 * code is in digest_openssl.c. Adapter header. Design: docs/vm/15-layers.md
 * §15.1.
 */
#ifndef AGC_DIGEST_H
#define AGC_DIGEST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define AGC_SHA256_BYTES 32
/* The longest digest of agc_digest_kind: SHA-512. */
#define AGC_DIGEST_MAX_BYTES 64

/* The one-shot hashes. MD5 and SHA-1 are broken for security and exist for formats that need them (ETags, git). */
typedef enum { AGC_DIGEST_MD5, AGC_DIGEST_SHA1, AGC_DIGEST_SHA256, AGC_DIGEST_SHA512 } agc_digest_kind;

/* Writes the digest of the n bytes at data into out and returns its length (16, 20, 32 or 64 bytes), or returns 0
   when the library fails (the hash missing from the build, or no memory). data may be NULL when n is 0. */
size_t agc_digest(agc_digest_kind kind, const unsigned char *data, size_t n, unsigned char out[AGC_DIGEST_MAX_BYTES]);

/* Writes the HMAC (RFC 2104) with the hash of kind of the n bytes at data under the key_n bytes at key into out and
   returns its length (the digest size), or returns 0 when the library fails. A key of any length is taken: one
   longer than the hash's block is hashed first, as RFC 2104 says. key and data may be NULL when their length is 0. */
size_t agc_hmac(agc_digest_kind kind, const unsigned char *key, size_t key_n, const unsigned char *data, size_t n,
                unsigned char out[AGC_DIGEST_MAX_BYTES]);

/* An incremental SHA-256 hash: one malloc'd context per call, fed in chunks. Only the pool threads use it (files.c),
   which free the context on every return path; no GC memory is involved. */
typedef struct agc_sha256_stream agc_sha256_stream;

/* Starts a hash; NULL when the library fails or there is no memory. */
agc_sha256_stream *agc_sha256_begin(void);

/* Hashes the n bytes at data; false when the library fails. n may be 0. */
bool agc_sha256_update(agc_sha256_stream *stream, const unsigned char *data, size_t n);

/* Writes the 32 digest bytes into out; false when the library fails. The stream stays owned by the caller. */
bool agc_sha256_final(agc_sha256_stream *stream, unsigned char out[AGC_SHA256_BYTES]);

/* Frees a stream started by agc_sha256_begin; NULL is free of charge. */
void agc_sha256_free(agc_sha256_stream *stream);

/* Fills the n bytes at out from OpenSSL's CSPRNG (RAND_bytes: the default DRBG, seeded from the system and reseeded
   after a fork), and returns true; n == 0 draws nothing. Returns false when the draw fails (the system has no entropy
   to give, or n is above INT_MAX); out then holds no usable bytes. Safe on any thread: OpenSSL 3 keeps one generator
   per thread. */
bool agc_secure_random(unsigned char *out, size_t n);

/* True when the n bytes at a and at b are the same, in a time that depends on n only, never on the bytes or on where
   they differ (OpenSSL's CRYPTO_memcmp). a and b may be NULL when n is 0. It reads only the two buffers: no library
   state, so it is safe on any thread. */
bool agc_secure_equal(const unsigned char *a, const unsigned char *b, size_t n);

/* Triple DES (DES-EDE3) has 8-byte blocks and IVs; a two-key key (16 bytes) is K1 K2 and runs as K1 K2 K1. */
#define AGC_DES_BLOCK_BYTES 8
/* The longest CMAC tag: the AES block. */
#define AGC_CMAC_MAX_BYTES 16

/* Encrypts (or decrypts) the n bytes at data with Triple DES in CBC mode and no padding into the n bytes at out, and
   returns true. key_n is 16 (two-key) or 24 (three-key), iv has AGC_DES_BLOCK_BYTES bytes and n is a multiple of
   AGC_DES_BLOCK_BYTES (any size: the call feeds OpenSSL in chunks); the caller checks them, and any other length
   returns false. Returns false when the library fails; out then holds no usable bytes. The copies of the key it
   makes are wiped. data may be NULL when n is 0. */
bool agc_des_ede3_cbc(bool encrypt, const unsigned char *key, size_t key_n, const unsigned char *iv,
                      const unsigned char *data, size_t n, unsigned char *out);

/* The block ciphers of CMAC. */
typedef enum { AGC_CMAC_AES, AGC_CMAC_DES_EDE3 } agc_cmac_cipher;

/* Writes the CMAC (NIST SP 800-38B; RFC 4493 for AES) of the n bytes at data under the key into out and returns its
   length: the full tag, 16 bytes for AES and 8 for Triple DES. The key picks the cipher's size: 16, 24 or 32 bytes
   for AES-128, -192 or -256, and 16 (two-key) or 24 bytes for Triple DES. Returns 0 for another key length or when
   the library fails. The copies of the key it makes are wiped. data may be NULL when n is 0. */
size_t agc_cmac(agc_cmac_cipher cipher, const unsigned char *key, size_t key_n, const unsigned char *data, size_t n,
                unsigned char out[AGC_CMAC_MAX_BYTES]);

/* AES-256-GCM (NIST SP 800-38D) takes a 32-byte key and a 12-byte IV (the nonce, never reused under one key), and
   gives a 16-byte tag. One key and IV encrypt at most 2^36 - 32 bytes (2^39 - 256 bits, SP 800-38D §5.2.1.1). */
#define AGC_GCM_KEY_BYTES 32
#define AGC_GCM_IV_BYTES 12
#define AGC_GCM_TAG_BYTES 16
#define AGC_GCM_MAX_BYTES (((uint64_t)1 << 36) - 32)

/* The end of an AES-256-GCM call: done, a decrypt whose tag does not match, or a library failure. */
typedef enum { AGC_AEAD_DONE, AGC_AEAD_BAD_TAG, AGC_AEAD_FAILED } agc_aead_status;

/* Encrypts (or decrypts) the n bytes at data with AES-256-GCM into the n bytes at out, after authenticating the
   aad_n bytes at aad. key has AGC_GCM_KEY_BYTES bytes and iv AGC_GCM_IV_BYTES; n is at most AGC_GCM_MAX_BYTES (else
   AGC_AEAD_FAILED), and both lengths may take any size_t (the call feeds OpenSSL in chunks). Encrypting writes the
   tag into tag; decrypting checks the tag it reads there, and a mismatch is AGC_AEAD_BAD_TAG. On any status but
   AGC_AEAD_DONE the n bytes at out are wiped, so a wrong tag never leaves plaintext behind. data, out and aad may be
   NULL when their length is 0. */
agc_aead_status agc_aes_256_gcm(bool encrypt, const unsigned char *key, const unsigned char *iv,
                                const unsigned char *aad, size_t aad_n, const unsigned char *data, size_t n,
                                unsigned char *out, unsigned char tag[AGC_GCM_TAG_BYTES]);

/* Writes out_n bytes of PBKDF2-HMAC-SHA256 (RFC 8018 §5.2) of the password and salt with the given iterations into
   out, and returns true. iterations is at least 1 and out_n at least 1; the password and the salt are at most
   INT_MAX bytes (OpenSSL takes int lengths there). Returns false for another value or when the library fails; out is
   then wiped. password and salt may be NULL when their length is 0. */
bool agc_pbkdf2_hmac_sha256(const unsigned char *password, size_t password_n, const unsigned char *salt,
                            size_t salt_n, uint64_t iterations, unsigned char *out, size_t out_n);

/* Writes out_n bytes of scrypt (RFC 7914) of the password and salt with cost n (a power of 2 above 1), block size r
   and parallelization p into out, and returns true, using at most max_memory bytes (128 * r * (n + p + 2)). The
   password and the salt are at most INT_MAX bytes. Returns false for parameters RFC 7914 or the memory cap refuses,
   or when the library fails; out is then wiped. password and salt may be NULL when their length is 0. */
bool agc_scrypt(const unsigned char *password, size_t password_n, const unsigned char *salt, size_t salt_n, uint64_t n,
                uint64_t r, uint64_t p, uint64_t max_memory, unsigned char *out, size_t out_n);

/* The longest RSA modulus OpenSSL encrypts with (OPENSSL_RSA_MAX_MODULUS_BITS, 16384 bits), in bytes: the most bytes
   an RSA ciphertext has. */
#define AGC_RSA_MAX_BYTES 2048
/* RSA-OAEP with SHA-1 (RFC 8017 §7.1) takes at most the key size less 42 bytes: two SHA-1 digests and two bytes. */
#define AGC_RSA_OAEP_OVERHEAD 42

/* The end of an RSA encryption: done, a text that holds no PEM public key, a public key that is not RSA, data longer
   than the key takes, a key that cannot encrypt (too small or too large, an even modulus, an even exponent or one of
   1 or above 64 bits), or a library failure (no memory, no random OAEP seed). */
typedef enum {
  AGC_RSA_DONE,
  AGC_RSA_BAD_PEM,
  AGC_RSA_NOT_RSA,
  AGC_RSA_TOO_LONG,
  AGC_RSA_BAD_KEY,
  AGC_RSA_FAILED
} agc_rsa_status;

/* Encrypts the n bytes at data with the RSA public key in the pem_n bytes of PEM text at pem (SubjectPublicKeyInfo
   "PUBLIC KEY" or PKCS#1 "RSA PUBLIC KEY"; the first PEM block is read) with OAEP padding, SHA-1 and MGF1-SHA-1
   (OpenSSL's RSA_PKCS1_OAEP_PADDING), into out, and sets *len to the ciphertext's length, the key's size. Every key
   check runs before the encryption, so the work is bounded: a modulus of at most 16384 bits and an exponent of at
   most 64. For AGC_RSA_TOO_LONG *len is the most data bytes the key takes; for the other errors it is 0. A private
   key, a certificate or an encrypted PEM is AGC_RSA_BAD_PEM: no passphrase is ever asked for. pem_n is at most
   INT_MAX (else AGC_RSA_BAD_PEM), and data may be NULL when n is 0. Every OpenSSL object is freed before it returns. */
agc_rsa_status agc_rsa_oaep_encrypt(const char *pem, size_t pem_n, const unsigned char *data, size_t n,
                                    unsigned char out[AGC_RSA_MAX_BYTES], size_t *len);

/* Overwrites the n bytes at data with zeros in a way the compiler cannot drop, for a copy of a secret (a KDF's
   password or key) before it is freed. data may be NULL when n is 0. */
void agc_wipe(void *data, size_t n);

#endif
