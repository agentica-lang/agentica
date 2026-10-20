/*
 * The digest adapter interface: one-shot hashes of a byte buffer, for the
 * Crypto builtins (crypto.c). The OpenSSL code is in digest_openssl.c. Adapter
 * header. Design: docs/vm/15-layers.md §15.1.
 */
#ifndef AGC_DIGEST_H
#define AGC_DIGEST_H

#include <stdbool.h>
#include <stddef.h>

#define AGC_SHA256_BYTES 32

/* Writes the SHA-256 digest of the n bytes at data into out and returns true, or returns false when the library
   fails (no SHA-256 in the build, or no memory). data may be NULL when n is 0. */
bool agc_digest_sha256(const unsigned char *data, size_t n, unsigned char out[AGC_SHA256_BYTES]);

#endif
