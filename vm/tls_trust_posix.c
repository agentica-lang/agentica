/*
 * The system trust store on Linux and the other POSIX systems: the first
 * readable PEM bundle of the paths that distributions use. macOS has its own
 * loader (tls_trust_darwin.c). Platform adapter behind tls_trust.h.
 */
#include "tls_trust.h"

#if !defined(_WIN32) && !defined(__APPLE__)
#include <openssl/err.h>
#include <openssl/x509_vfy.h>
#include <unistd.h>

static const char *const bundles[] = {
  "/etc/ssl/certs/ca-certificates.crt",
  "/etc/pki/tls/certs/ca-bundle.crt",
  "/etc/ssl/ca-bundle.pem",
  "/etc/pki/tls/cacert.pem",
  "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
  "/etc/ssl/cert.pem",
};

void agc_tls_trust_load(struct x509_store_st *store) {
  for (size_t k = 0; k < sizeof bundles / sizeof bundles[0]; k++) {
    if (access(bundles[k], R_OK) != 0) continue;
    if (X509_STORE_load_file(store, bundles[k]) != 1) ERR_clear_error();
    return;
  }
}
#endif
