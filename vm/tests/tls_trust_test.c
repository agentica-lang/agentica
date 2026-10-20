/*
 * The system trust store of this platform (tls_trust.h): Crypt32 on Windows,
 * the Security framework on macOS, a PEM bundle elsewhere. It must load roots.
 */
#include "../tls_trust.h"

#include <assert.h>
#include <stdio.h>

#include <openssl/x509.h>
#include <openssl/x509_vfy.h>

int main(void) {
  X509_STORE *store = X509_STORE_new();
  assert(store);
  size_t added = agc_tls_trust_system(store);
  STACK_OF(X509) *certs = X509_STORE_get1_all_certs(store);
  assert(certs);
  int held = sk_X509_num(certs);
  /* The loader counts each add; a certificate listed twice is stored once. */
  assert(held >= 0 && (size_t)held <= added);
  sk_X509_pop_free(certs, X509_free);
  X509_STORE_free(store);
#if defined(_WIN32) || defined(__APPLE__)
  assert(held > 0);
#else
  /* A Linux machine without a CA bundle (a minimal container) has no system trust: the client then fails closed. */
  if (held == 0) puts("tls trust: no system bundle on this machine");
#endif
  printf("tls trust tests passed (%lu roots)\n", (unsigned long)added);
  return 0;
}
