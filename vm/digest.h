/*
 * The digest adapter interface: one-shot hashes of a byte buffer, for the
 * Digest builtins (crypto.c), and an incremental SHA-256 for the File hash
 * (files.c), which streams a whole file in fixed chunks. The OpenSSL code is
 * in digest_openssl.c. Adapter header. Design: docs/vm/15-layers.md §15.1.
 */
#ifndef AGC_DIGEST_H
#define AGC_DIGEST_H

#include <stdbool.h>
#include <stddef.h>

#define AGC_SHA256_BYTES 32
/* The longest digest of agc_digest_kind: SHA-512. */
#define AGC_DIGEST_MAX_BYTES 64

/* The one-shot hashes. MD5 and SHA-1 are broken for security and exist for formats that need them (ETags, git). */
typedef enum { AGC_DIGEST_MD5, AGC_DIGEST_SHA1, AGC_DIGEST_SHA256, AGC_DIGEST_SHA512 } agc_digest_kind;

/* Writes the digest of the n bytes at data into out and returns its length (16, 20, 32 or 64 bytes), or returns 0
   when the library fails (the hash missing from the build, or no memory). data may be NULL when n is 0. */
size_t agc_digest(agc_digest_kind kind, const unsigned char *data, size_t n, unsigned char out[AGC_DIGEST_MAX_BYTES]);

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

#endif
