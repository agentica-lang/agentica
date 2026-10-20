/*
 * The Windows trust policy (tls_trust_windows.c) on in-memory Crypt32 stores:
 * the valid uses of a root, a Disallowed copy that wins over ROOT, and CA
 * certificates that complete a chain but are never anchors.
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
  agc_tls_trust_copy_stores(trusted, disallowed, root, NULL);
  assert(verify(trusted, leaf) == 0);
  X509_STORE_free(trusted);
  CertFreeCertificateContext(add_to(disallowed, ca));
  X509_STORE *rejected = X509_STORE_new();
  agc_tls_trust_copy_stores(rejected, disallowed, root, NULL);
  assert(verify(rejected, leaf) == X509_V_ERR_CERT_REJECTED);
  X509_STORE_free(rejected);
  HCERTSTORE empty = memory_store(), client_only = memory_store();
  PCCERT_CONTEXT cert = add_to(client_only, ca);
  LPSTR client[] = {szOID_PKIX_KP_CLIENT_AUTH};
  set_usage(cert, client, 1);
  CertFreeCertificateContext(cert);
  X509_STORE *skipped = X509_STORE_new();
  agc_tls_trust_copy_stores(skipped, empty, client_only, NULL);
  assert(verify(skipped, leaf) == X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY);
  X509_STORE_free(skipped);
  CertCloseStore(empty, 0);
  CertCloseStore(client_only, 0);
  CertCloseStore(disallowed, 0);
  CertCloseStore(root, 0);
  X509_free(leaf);
}

/* The certificate of a fixture, parsed again from its DER (the caller frees both). */
static X509 *x509_of(der_cert d) {
  const unsigned char *p = d.der;
  X509 *x = d2i_X509(NULL, &p, d.len);
  assert(x);
  return x;
}

/* The verify error of `leaf` against the copy of ROOT `root` and CA `ca` (no Disallowed store). */
static int verify_copy(HCERTSTORE root, HCERTSTORE ca, X509 *leaf) {
  X509_STORE *store = X509_STORE_new();
  assert(store);
  agc_tls_trust_copy_stores(store, NULL, root, ca);
  int error = verify(store, leaf);
  X509_STORE_free(store);
  return error;
}

/* chain-leaf.pem is signed by chain-intermediate.pem, which chain-root.pem signs. The peer sends only the leaf, so
 * the chain needs the CA store's intermediate, and still ends at ROOT: the intermediate alone, a self-signed
 * certificate in CA never verifies, and an intermediate whose EKU property excludes server authentication is
 * rejected. A Disallowed copy of the intermediate wins over CA. A cross-signed copy of the ROOT anchor in CA, whose
 * signer is distrusted, is left out, so it cannot hide the anchor. */
static void test_ca_store(der_cert ca) {
  der_cert root_cert = read_der(CERTS "chain-root.pem"), inter = read_der(CERTS "chain-intermediate.pem");
  der_cert leaf_der = read_der(CERTS "chain-leaf.pem"), server_der = read_der(CERTS "server.pem");
  X509 *leaf = x509_of(leaf_der), *server = x509_of(server_der);
  HCERTSTORE root = memory_store(), cas = memory_store(), none = memory_store();
  CertFreeCertificateContext(add_to(root, root_cert));
  assert(verify_copy(root, none, leaf) == X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY);
  PCCERT_CONTEXT in_ca = add_to(cas, inter);
  assert(verify_copy(root, cas, leaf) == X509_V_OK);
  assert(verify_copy(none, cas, leaf) == X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT);
  HCERTSTORE disallowed = memory_store();
  CertFreeCertificateContext(add_to(disallowed, inter));
  X509_STORE *store = X509_STORE_new();
  agc_tls_trust_copy_stores(store, disallowed, root, cas);
  assert(verify(store, leaf) == X509_V_ERR_CERT_REJECTED);
  X509_STORE_free(store);
  der_cert signer = read_der(CERTS "chain-cross-signer.pem"), cross = read_der(CERTS "chain-root-cross.pem");
  HCERTSTORE distrusted = memory_store(), crossed = memory_store();
  CertFreeCertificateContext(add_to(distrusted, signer));
  CertFreeCertificateContext(add_to(crossed, cross));
  CertFreeCertificateContext(add_to(crossed, inter));
  X509_STORE *with_cross = X509_STORE_new();
  agc_tls_trust_copy_stores(with_cross, distrusted, root, crossed);
  assert(verify(with_cross, leaf) == X509_V_OK);
  X509_STORE_free(with_cross);
  CertCloseStore(crossed, 0);
  CertCloseStore(distrusted, 0);
  OPENSSL_free(cross.der);
  OPENSSL_free(signer.der);
  LPSTR client[] = {szOID_PKIX_KP_CLIENT_AUTH};
  set_usage(in_ca, client, 1);
  assert(verify_copy(root, cas, leaf) == X509_V_ERR_CERT_REJECTED);
  CertFreeCertificateContext(in_ca);
  HCERTSTORE self_signed = memory_store();
  CertFreeCertificateContext(add_to(self_signed, ca));
  assert(verify_copy(none, self_signed, server) == X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY);
  assert(verify_copy(self_signed, none, server) == X509_V_OK);
  CertCloseStore(self_signed, 0);
  CertCloseStore(disallowed, 0);
  CertCloseStore(none, 0);
  CertCloseStore(cas, 0);
  CertCloseStore(root, 0);
  X509_free(server);
  X509_free(leaf);
  OPENSSL_free(server_der.der);
  OPENSSL_free(leaf_der.der);
  OPENSSL_free(inter.der);
  OPENSSL_free(root_cert.der);
}

int main(void) {
  der_cert ca = read_der(CERTS "ca.pem");
  test_server_auth(ca);
  test_copy_stores(ca);
  test_ca_store(ca);
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
