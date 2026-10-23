/*
 * The digest adapter over OpenSSL's EVP interface, the same library that
 * tls_openssl.c links (system OpenSSL 3 or the vendored one). Adapter layer,
 * behind digest.h. Design: docs/vm/15-layers.md §15.1.
 */
#include "digest.h"

#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/evp.h>
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

bool agc_digest_sha256(const unsigned char *data, size_t n, unsigned char out[AGC_SHA256_BYTES]) {
  static const unsigned char none = 0;
  unsigned int len = 0;
  bool done = digest_ready() && EVP_Digest(n ? data : &none, n, out, &len, EVP_sha256(), NULL) == 1 &&
              len == AGC_SHA256_BYTES;
  /* A failure leaves errors in this thread's OpenSSL queue; drop them so a later TLS call on it reads only its own. */
  if (!done) ERR_clear_error();
  return done;
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
