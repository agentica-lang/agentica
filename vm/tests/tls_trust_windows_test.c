/*
 * The Windows trust policy (tls_trust_windows.c) on in-memory Crypt32 stores:
 * the valid uses of a root, and a Disallowed copy that wins over ROOT.
 */
#include "../tls_trust.h"

#include <stdio.h>

#ifdef _WIN32
#include <windows.h>
#include <wincrypt.h>
#include <assert.h>
#include <stdlib.h>

#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/x509_vfy.h>

#define CERTS "tests/fixtures/tls/"

typedef struct {
  unsigned char *der;
  int len;
} der_cert;

static der_cert read_der(const char *path) {
  FILE *f = fopen(path, "rb");
  assert(f);
  X509 *x = PEM_read_X509(f, NULL, NULL, NULL);
  fclose(f);
  assert(x);
  der_cert d = {NULL, 0};
  d.len = i2d_X509(x, &d.der);
  assert(d.len > 0);
  X509_free(x);
  return d;
}

static HCERTSTORE memory_store(void) {
  HCERTSTORE s = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, 0, NULL);
  assert(s);
  return s;
}

static PCCERT_CONTEXT add_to(HCERTSTORE s, der_cert d) {
  PCCERT_CONTEXT cert = NULL;
  assert(CertAddEncodedCertificateToStore(s, X509_ASN_ENCODING, d.der, (DWORD)d.len, CERT_STORE_ADD_ALWAYS, &cert));
  return cert;
}

/* Sets the EKU property (CERT_ENHKEY_USAGE_PROP_ID) to these OIDs; zero OIDs is a property that allows no use. */
static void set_usage(PCCERT_CONTEXT cert, LPSTR *oids, DWORD count) {
  CERT_ENHKEY_USAGE usage = {count, oids};
  BYTE encoded[256];
  DWORD size = sizeof encoded;
  assert(CryptEncodeObject(X509_ASN_ENCODING, X509_ENHANCED_KEY_USAGE, &usage, encoded, &size));
  CRYPT_DATA_BLOB blob = {size, encoded};
  assert(CertSetCertificateContextProperty(cert, CERT_ENHKEY_USAGE_PROP_ID, 0, &blob));
}

/* ca.pem has no EKU extension, so the property alone decides. */
static void test_server_auth(der_cert ca) {
  HCERTSTORE s = memory_store();
  PCCERT_CONTEXT cert = add_to(s, ca);
  assert(agc_tls_trust_server_auth(cert));
  LPSTR server[] = {szOID_PKIX_KP_CLIENT_AUTH, szOID_PKIX_KP_SERVER_AUTH};
  set_usage(cert, server, 2);
  assert(agc_tls_trust_server_auth(cert));
  LPSTR client[] = {szOID_PKIX_KP_CLIENT_AUTH};
  set_usage(cert, client, 1);
  assert(!agc_tls_trust_server_auth(cert));
  set_usage(cert, NULL, 0);
  assert(!agc_tls_trust_server_auth(cert));
  CertFreeCertificateContext(cert);
  CertCloseStore(s, 0);
}

/* The verify error of `leaf` under the SSL server trust (the one a TLS client checks), or 0. */
static int verify(X509_STORE *store, X509 *leaf) {
  X509_STORE_CTX *ctx = X509_STORE_CTX_new();
  int error = -1;
  if (ctx && X509_STORE_CTX_init(ctx, store, leaf, NULL) == 1 && X509_STORE_CTX_set_trust(ctx, X509_TRUST_SSL_SERVER))
    error = X509_verify_cert(ctx) == 1 ? X509_V_OK : X509_STORE_CTX_get_error(ctx);
  X509_STORE_CTX_free(ctx);
  return error;
}

/* The test CA in ROOT alone verifies server.pem; also in Disallowed, the rejected copy wins. A root whose EKU
 * property excludes server authentication is not copied. */
static void test_copy_stores(der_cert ca) {
  FILE *f = fopen(CERTS "server.pem", "rb");
  assert(f);
  X509 *leaf = PEM_read_X509(f, NULL, NULL, NULL);
  fclose(f);
  assert(leaf);
  HCERTSTORE disallowed = memory_store(), root = memory_store();
  CertFreeCertificateContext(add_to(root, ca));
  X509_STORE *trusted = X509_STORE_new();
  agc_tls_trust_copy_stores(trusted, disallowed, root);
  assert(verify(trusted, leaf) == 0);
  X509_STORE_free(trusted);
  CertFreeCertificateContext(add_to(disallowed, ca));
  X509_STORE *rejected = X509_STORE_new();
  agc_tls_trust_copy_stores(rejected, disallowed, root);
  assert(verify(rejected, leaf) == X509_V_ERR_CERT_REJECTED);
  X509_STORE_free(rejected);
  HCERTSTORE empty = memory_store(), client_only = memory_store();
  PCCERT_CONTEXT cert = add_to(client_only, ca);
  LPSTR client[] = {szOID_PKIX_KP_CLIENT_AUTH};
  set_usage(cert, client, 1);
  CertFreeCertificateContext(cert);
  X509_STORE *skipped = X509_STORE_new();
  agc_tls_trust_copy_stores(skipped, empty, client_only);
  assert(verify(skipped, leaf) == X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY);
  X509_STORE_free(skipped);
  CertCloseStore(empty, 0);
  CertCloseStore(client_only, 0);
  CertCloseStore(disallowed, 0);
  CertCloseStore(root, 0);
  X509_free(leaf);
}

int main(void) {
  der_cert ca = read_der(CERTS "ca.pem");
  test_server_auth(ca);
  test_copy_stores(ca);
  OPENSSL_free(ca.der);
  puts("tls trust windows tests passed");
  return 0;
}
#else
int main(void) {
  puts("tls trust windows tests skipped: not Windows");
  return 0;
}
#endif
