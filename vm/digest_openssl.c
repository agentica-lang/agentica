/*
 * The digest adapter over OpenSSL's EVP interface, the same library that
 * tls_openssl.c links (system OpenSSL 3 or the vendored one). Adapter layer,
 * behind digest.h. Design: docs/vm/15-layers.md §15.1.
 */
#include "digest.h"

#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/evp.h>

#if OPENSSL_VERSION_NUMBER < 0x30000000L || defined(LIBRESSL_VERSION_NUMBER)
#error "the VM needs OpenSSL 3.0 or newer (LibreSSL is not supported): install the OpenSSL 3 development files or build with AGENTICA_OPENSSL=vendored"
#endif

bool agc_digest_sha256(const unsigned char *data, size_t n, unsigned char out[AGC_SHA256_BYTES]) {
  static const unsigned char none = 0;
  unsigned int len = 0;
  /* The same init as the TLS adapter: no openssl.cnf (a system build would otherwise read it on first use) and no
     atexit cleanup, which could run while another scheduler still hashes. After the first call it is a cheap check. */
  bool done = OPENSSL_init_crypto(OPENSSL_INIT_NO_LOAD_CONFIG | OPENSSL_INIT_NO_ATEXIT, NULL) == 1 &&
              EVP_Digest(n ? data : &none, n, out, &len, EVP_sha256(), NULL) == 1 && len == AGC_SHA256_BYTES;
  /* A failure leaves errors in this thread's OpenSSL queue; drop them so a later TLS call on it reads only its own. */
  if (!done) ERR_clear_error();
  return done;
}
