/*
 * The digest adapter over OpenSSL's EVP interface and RAND_bytes, the same
 * library that tls_openssl.c links (system OpenSSL 3 or the vendored one).
 * Adapter layer, behind digest.h. Design: docs/vm/15-layers.md §15.1.
 */
#include "digest.h"

#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <limits.h>
#include <stdlib.h>

#if OPENSSL_VERSION_NUMBER < 0x30000000L || defined(LIBRESSL_VERSION_NUMBER)
#error "the VM needs OpenSSL 3.0 or newer (LibreSSL is not supported): install the OpenSSL 3 development files or build with AGENTICA_OPENSSL=vendored"
#endif

struct agc_sha256_stream {
  EVP_MD_CTX *ctx;
};

static bool digest_ready(void) {
  /* The same init as the TLS adapter: no openssl.cnf (a system build would otherwise read it on first use) and no
     atexit cleanup, which could run while another scheduler still hashes. After the first call it is a cheap check. */
  if (OPENSSL_init_crypto(OPENSSL_INIT_NO_LOAD_CONFIG | OPENSSL_INIT_NO_ATEXIT, NULL) != 1) {
    ERR_clear_error();
    return false;
  }
  return true;
}

/* EVP_Digest writes at most EVP_MAX_MD_SIZE bytes, so out never overflows. */
_Static_assert(EVP_MAX_MD_SIZE <= AGC_DIGEST_MAX_BYTES, "AGC_DIGEST_MAX_BYTES must hold any EVP digest");

/* The method of a kind. The switch has no default, so -Wswitch flags a new kind that is not added here. */
static const EVP_MD *digest_method(agc_digest_kind kind) {
  switch (kind) {
    case AGC_DIGEST_MD5: return EVP_md5();
    case AGC_DIGEST_SHA1: return EVP_sha1();
    case AGC_DIGEST_SHA256: return EVP_sha256();
    case AGC_DIGEST_SHA512: return EVP_sha512();
  }
  return NULL;
}

size_t agc_digest(agc_digest_kind kind, const unsigned char *data, size_t n, unsigned char out[AGC_DIGEST_MAX_BYTES]) {
  static const unsigned char none = 0;
  /* The default provider has all four, MD5 and SHA-1 included (the legacy provider, which no-legacy leaves out of the
     vendored build, holds only older hashes such as MD4). A FIPS-only system OpenSSL has no MD5 or SHA-1: the fetch
     inside EVP_Digest fails and the call returns 0. */
  const EVP_MD *md = digest_method(kind);
  unsigned int len = 0;
  bool done = md && digest_ready() && EVP_Digest(n ? data : &none, n, out, &len, md, NULL) == 1 && len > 0;
  /* A failure leaves errors in this thread's OpenSSL queue; drop them so a later TLS call on it reads only its own. */
  if (!done) ERR_clear_error();
  return done ? len : 0;
}

agc_sha256_stream *agc_sha256_begin(void) {
  if (!digest_ready()) return NULL;
  agc_sha256_stream *stream = malloc(sizeof *stream);
  if (!stream) {
    ERR_clear_error();
    return NULL;
  }
  stream->ctx = EVP_MD_CTX_new();
  if (!stream->ctx || EVP_DigestInit_ex(stream->ctx, EVP_sha256(), NULL) != 1) {
    EVP_MD_CTX_free(stream->ctx);
    free(stream);
    ERR_clear_error();
    return NULL;
  }
  return stream;
}

bool agc_sha256_update(agc_sha256_stream *stream, const unsigned char *data, size_t n) {
  /* The file hash never feeds an empty chunk, but an empty update is defined to succeed. */
  if (!stream || (n && !data)) return false;
  if (n == 0) return true;
  if (EVP_DigestUpdate(stream->ctx, data, n) != 1) {
    ERR_clear_error();
    return false;
  }
  return true;
}

bool agc_sha256_final(agc_sha256_stream *stream, unsigned char out[AGC_SHA256_BYTES]) {
  unsigned int len = 0;
  if (!stream || EVP_DigestFinal_ex(stream->ctx, out, &len) != 1 || len != AGC_SHA256_BYTES) {
    ERR_clear_error();
    return false;
  }
  return true;
}

void agc_sha256_free(agc_sha256_stream *stream) {
  if (!stream) return;
  EVP_MD_CTX_free(stream->ctx);
  free(stream);
}

bool agc_secure_random(unsigned char *out, size_t n) {
  if (n == 0) return true;
  /* RAND_bytes takes an int count; it returns 1 only when every byte came from a seeded generator (0 or -1 else). */
  bool done = n <= INT_MAX && digest_ready() && RAND_bytes(out, (int)n) == 1;
  if (!done) ERR_clear_error();
  return done;
}
