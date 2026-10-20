/*
 * The system trust store on Windows, read with Crypt32: the certificates of
 * the current user's Disallowed store, added as rejected, then those of the
 * ROOT store whose valid uses include server authentication, then those of
 * the CA store (intermediates), added as chain certificates only (rejected
 * when their EKU property excludes it), as CPython's
 * ssl.load_default_certs reads ROOT and CA. Every view includes the
 * machine's stores. Platform adapter behind tls_trust.h.
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

/* What one EKU list says about server authentication. */
typedef enum { USES_YES, USES_NO, USES_ERROR } uses;

/* Whether the valid uses CertGetEnhancedKeyUsage reads with `flags` include server authentication: USES_YES,
 * USES_NO, or USES_ERROR when a call fails. No flags combine the EKU extension and the EKU property;
 * CERT_FIND_PROP_ONLY_ENHKEY_USAGE_FLAG reads the property alone. An empty list means every use when the last
 * error is CRYPT_E_NOT_FOUND, and no use when it is 0 (Microsoft Learn, CertGetEnhancedKeyUsage), so the error is
 * cleared before the call that fills the list. A property-only call on a certificate with no property may instead
 * fail with CRYPT_E_NOT_FOUND (Wine does), which also means no restriction. */
static uses server_auth_uses(PCCERT_CONTEXT cert, DWORD flags) {
  DWORD size = 0;
  SetLastError(0);
  if (!CertGetEnhancedKeyUsage(cert, flags, NULL, &size))
    return flags && GetLastError() == (DWORD)CRYPT_E_NOT_FOUND ? USES_YES : USES_ERROR;
  CERT_ENHKEY_USAGE *usage = malloc(size);
  if (!usage) return USES_ERROR;
  uses result = USES_ERROR;
  SetLastError(0);
  if (CertGetEnhancedKeyUsage(cert, flags, usage, &size)) {
    bool ok = usage->cUsageIdentifier == 0 && GetLastError() == (DWORD)CRYPT_E_NOT_FOUND;
    for (DWORD k = 0; k < usage->cUsageIdentifier && !ok; k++)
      ok = strcmp(usage->rgpszUsageIdentifier[k], szOID_PKIX_KP_SERVER_AUTH) == 0;
    result = ok ? USES_YES : USES_NO;
  }
  free(usage);
  return result;
}

/* A call that fails leaves the root out. */
bool agc_tls_trust_server_auth(PCCERT_CONTEXT cert) { return server_auth_uses(cert, 0) == USES_YES; }

/* A CA certificate: its EKU extension is checked by agc_tls_trust_add_intermediate_der (which refuses one that
 * excludes server authentication, as OpenSSL would refuse any copy of it in a chain), so only the Crypt32 property
 * is read here. A property that excludes server authentication adds the certificate rejected; a property that
 * cannot be read leaves it out (fail closed). */
static void copy_intermediate(struct x509_store_st *store, PCCERT_CONTEXT cert) {
  uses property = server_auth_uses(cert, CERT_FIND_PROP_ONLY_ENHKEY_USAGE_FLAG);
  if (property != USES_ERROR)
    (void)agc_tls_trust_add_intermediate_der(store, cert->pbCertEncoded, cert->cbCertEncoded, property == USES_NO);
}

/* Copies one Crypt32 store. Each CertEnumCertificatesInStore call frees the context passed in and returns the next;
 * the loop ends on NULL, so nothing is left to free (Microsoft Learn, CertEnumCertificatesInStore). */
static void copy_store(struct x509_store_st *store, HCERTSTORE from, copy_kind kind) {
  if (!from) return;
  PCCERT_CONTEXT cert = NULL;
  while ((cert = CertEnumCertificatesInStore(from, cert)) != NULL) {
    if (!(cert->dwCertEncodingType & X509_ASN_ENCODING)) continue;
    if (kind == COPY_INTERMEDIATE)
      copy_intermediate(store, cert);
    else if (kind == COPY_REJECTED || agc_tls_trust_server_auth(cert))
      (void)agc_tls_trust_add_der(store, cert->pbCertEncoded, cert->cbCertEncoded, kind == COPY_REJECTED);
  }
}

/* The order matters twice. The store keeps the first copy of a certificate, so Disallowed goes first and a
 * distrusted root or intermediate stays rejected. CA goes after ROOT, so the cross-signed copies of its anchors are
 * known and left out. What keeps a CA certificate from becoming an anchor is the self-issued check of
 * agc_tls_trust_add_intermediate_der, not the order. A ROOT certificate that the EKU filter skipped is not in the
 * store, so a cross-signed copy of it in CA is still accepted, as Windows gives each certificate its own EKU
 * property. A CA certificate whose EKU extension excludes server authentication is skipped: OpenSSL looks in the
 * store first, and such a copy of an intermediate (an S/MIME sibling with the same subject and key) would fail a
 * chain where the server sends the valid one. One whose EKU property alone excludes it is added rejected, so a
 * server that sends that intermediate itself still fails with X509_V_ERR_CERT_REJECTED, as the property says; it
 * also shadows same-key siblings of it, which is taken as the administrator's intent. */
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
