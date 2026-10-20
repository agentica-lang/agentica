/*
 * The system trust store on Windows, read with Crypt32: the certificates of
 * the current user's Disallowed store, added as rejected, then those of the
 * ROOT store (both views include the machine's stores) whose valid uses
 * include server authentication. Platform adapter behind tls_trust.h.
 */
#include "tls_trust.h"

#ifdef _WIN32
#include <windows.h>
#include <wincrypt.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

/* CertGetEnhancedKeyUsage with no flags combines the EKU extension and the EKU property. An empty list means every
 * use when the last error is CRYPT_E_NOT_FOUND, and no use when it is 0 (Microsoft Learn, CertGetEnhancedKeyUsage),
 * so the error is cleared before the call that fills the list. */
bool agc_tls_trust_server_auth(PCCERT_CONTEXT cert) {
  DWORD size = 0;
  if (!CertGetEnhancedKeyUsage(cert, 0, NULL, &size)) return GetLastError() == (DWORD)CRYPT_E_NOT_FOUND;
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
static void copy_store(struct x509_store_st *store, HCERTSTORE from, bool rejected) {
  if (!from) return;
  PCCERT_CONTEXT cert = NULL;
  while ((cert = CertEnumCertificatesInStore(from, cert)) != NULL) {
    if (!(cert->dwCertEncodingType & X509_ASN_ENCODING) || (!rejected && !agc_tls_trust_server_auth(cert)))
      continue;
    (void)agc_tls_trust_add_der(store, cert->pbCertEncoded, cert->cbCertEncoded, rejected);
  }
}

/* Disallowed first: the store keeps the first copy of a certificate, so a distrusted root stays rejected. */
void agc_tls_trust_copy_stores(struct x509_store_st *store, void *disallowed, void *root) {
  copy_store(store, disallowed, true);
  copy_store(store, root, false);
}

void agc_tls_trust_load(struct x509_store_st *store) {
  HCERTSTORE disallowed = CertOpenSystemStoreW(0, L"Disallowed"), root = CertOpenSystemStoreW(0, L"ROOT");
  agc_tls_trust_copy_stores(store, disallowed, root);
  if (disallowed) CertCloseStore(disallowed, 0);
  if (root) CertCloseStore(root, 0);
}
#endif
