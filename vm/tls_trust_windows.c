/*
 * The system trust store on Windows: the certificates of the current user's
 * ROOT system store (which includes the machine's roots), read with Crypt32
 * and copied into the OpenSSL store. A root whose valid uses exclude server
 * authentication is left out. Platform adapter behind tls_trust.h.
 */
#include "tls_trust.h"

#ifdef _WIN32
/* wincrypt.h defines X509_NAME and friends as macros; OpenSSL's headers undefine them, so they come second. */
#include <windows.h>
#include <wincrypt.h>
#include <limits.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/err.h>
#include <openssl/x509.h>
#include <openssl/x509_vfy.h>

/* CertGetEnhancedKeyUsage with no flags combines the EKU extension and the EKU property. An empty list means every
 * use when the error is CRYPT_E_NOT_FOUND, and no use otherwise (Microsoft Learn, CertGetEnhancedKeyUsage). */
static bool server_auth(PCCERT_CONTEXT cert) {
  DWORD size = 0;
  if (!CertGetEnhancedKeyUsage(cert, 0, NULL, &size)) return GetLastError() == (DWORD)CRYPT_E_NOT_FOUND;
  CERT_ENHKEY_USAGE *usage = malloc(size);
  if (!usage) return false;
  bool ok = false;
  if (CertGetEnhancedKeyUsage(cert, 0, usage, &size)) {
    if (usage->cUsageIdentifier == 0) ok = GetLastError() == (DWORD)CRYPT_E_NOT_FOUND;
    for (DWORD k = 0; k < usage->cUsageIdentifier && !ok; k++)
      ok = strcmp(usage->rgpszUsageIdentifier[k], szOID_PKIX_KP_SERVER_AUTH) == 0;
  }
  free(usage);
  return ok;
}

size_t agc_tls_trust_system(struct x509_store_st *store) {
  HCERTSTORE root = CertOpenSystemStoreW(0, L"ROOT");
  if (!root) return 0;
  size_t added = 0;
  /* Each call frees the context passed in and returns the next one; the loop ends on NULL, so nothing is left to
   * free (Microsoft Learn, CertEnumCertificatesInStore). */
  PCCERT_CONTEXT cert = NULL;
  while ((cert = CertEnumCertificatesInStore(root, cert)) != NULL) {
    if (!(cert->dwCertEncodingType & X509_ASN_ENCODING) || cert->cbCertEncoded > LONG_MAX || !server_auth(cert)) continue;
    const unsigned char *der = cert->pbCertEncoded;
    X509 *x = d2i_X509(NULL, &der, (long)cert->cbCertEncoded);
    if (x && X509_STORE_add_cert(store, x) == 1) added++;
    X509_free(x);
    ERR_clear_error();
  }
  CertCloseStore(root, 0);
  return added;
}
#endif
