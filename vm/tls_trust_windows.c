/*
 * The system trust store on Windows, read with Crypt32: the certificates of
 * the current user's Disallowed store, added as rejected, then those of the
 * ROOT store whose valid uses include server authentication, then those of
 * the CA store (intermediates), added as chain certificates only (rejected
 * when not valid for it), as CPython's ssl.load_default_certs reads ROOT
 * and CA. Every view includes the machine's stores. Platform adapter behind tls_trust.h.
 */
#include "tls_trust.h"

#ifdef _WIN32
#include <windows.h>
#include <wincrypt.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

/* How copy_store adds the certificates of one store. */
typedef enum { COPY_REJECTED, COPY_ROOT, COPY_INTERMEDIATE } copy_kind;

/* CertGetEnhancedKeyUsage with no flags combines the EKU extension and the EKU property. An empty list means every
 * use when the last error is CRYPT_E_NOT_FOUND, and no use when it is 0 (Microsoft Learn, CertGetEnhancedKeyUsage),
 * so the error is cleared before the call that fills the list. A call that fails leaves the root out. */
bool agc_tls_trust_server_auth(PCCERT_CONTEXT cert) {
  DWORD size = 0;
  if (!CertGetEnhancedKeyUsage(cert, 0, NULL, &size)) return false;
  CERT_ENHKEY_USAGE *usage = malloc(size);
  if (!usage) return false;
  bool ok = false;
  SetLastError(0);
  if (CertGetEnhancedKeyUsage(cert, 0, usage, &size)) {
    if (usage->cUsageIdentifier == 0) ok = GetLastError() == (DWORD)CRYPT_E_NOT_FOUND;
    for (DWORD k = 0; k < usage->cUsageIdentifier && !ok; k++)
      ok = strcmp(usage->rgpszUsageIdentifier[k], szOID_PKIX_KP_SERVER_AUTH) == 0;
  }
  free(usage);
  return ok;
}

/* Copies one Crypt32 store. Each CertEnumCertificatesInStore call frees the context passed in and returns the next;
 * the loop ends on NULL, so nothing is left to free (Microsoft Learn, CertEnumCertificatesInStore). */
static void copy_store(struct x509_store_st *store, HCERTSTORE from, copy_kind kind) {
  if (!from) return;
  PCCERT_CONTEXT cert = NULL;
  while ((cert = CertEnumCertificatesInStore(from, cert)) != NULL) {
    if (!(cert->dwCertEncodingType & X509_ASN_ENCODING)) continue;
    if (kind == COPY_INTERMEDIATE)
      (void)agc_tls_trust_add_intermediate_der(store, cert->pbCertEncoded, cert->cbCertEncoded,
                                               !agc_tls_trust_server_auth(cert));
    else if (kind == COPY_REJECTED || agc_tls_trust_server_auth(cert))
      (void)agc_tls_trust_add_der(store, cert->pbCertEncoded, cert->cbCertEncoded, kind == COPY_REJECTED);
  }
}

/* The order matters twice. The store keeps the first copy of a certificate, so Disallowed goes first and a
 * distrusted root or intermediate stays rejected. CA goes after ROOT, so the cross-signed copies of its anchors are
 * known and left out. What keeps a CA certificate from becoming an anchor is the self-issued check of
 * agc_tls_trust_add_intermediate_der, not the order. A CA certificate whose valid uses exclude server
 * authentication is added rejected rather than skipped: OpenSSL looks in the store first, so a server that sends
 * that intermediate itself still fails with X509_V_ERR_CERT_REJECTED, as the Windows property says. */
void agc_tls_trust_copy_stores(struct x509_store_st *store, void *disallowed, void *root, void *ca) {
  copy_store(store, disallowed, COPY_REJECTED);
  copy_store(store, root, COPY_ROOT);
  copy_store(store, ca, COPY_INTERMEDIATE);
}

void agc_tls_trust_load(struct x509_store_st *store) {
  HCERTSTORE disallowed = CertOpenSystemStoreW(0, L"Disallowed"), root = CertOpenSystemStoreW(0, L"ROOT"),
             ca = CertOpenSystemStoreW(0, L"CA");
  agc_tls_trust_copy_stores(store, disallowed, root, ca);
  if (disallowed) CertCloseStore(disallowed, 0);
  if (root) CertCloseStore(root, 0);
  if (ca) CertCloseStore(ca, 0);
}
#endif
