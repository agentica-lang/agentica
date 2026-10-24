/*
 * The digest adapter interface: one-shot hashes of a byte buffer, for the
 * Crypto builtins (crypto.c), and an incremental hash for the File hash
 * (files.c), which streams a whole file in fixed chunks. The OpenSSL code is
 * in digest_openssl.c. Adapter header. Design: docs/vm/15-layers.md §15.1.
 */
#ifndef AGC_DIGEST_H
#define AGC_DIGEST_H

#include <stdbool.h>
#include <stddef.h>

#define AGC_SHA256_BYTES 32

/* Writes the SHA-256 digest of the n bytes at data into out and returns true, or returns false when the library
   fails (no SHA-256 in the build, or no memory). data may be NULL when n is 0. */
bool agc_digest_sha256(const unsigned char *data, size_t n, unsigned char out[AGC_SHA256_BYTES]);

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
