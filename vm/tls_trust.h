/*
 * The system trust store, for a client with no ca_file. tls_trust.c reads it
 * once per process and copies it into each new store. The platform loader:
 * a PEM bundle on Linux and other POSIX (tls_trust_posix.c), the Security
 * framework on macOS (tls_trust_darwin.c), Crypt32 on Windows
 * (tls_trust_windows.c). Adapter header, used by tls_openssl.c and the loaders.
 */
#ifndef AGC_TLS_TRUST_H
#define AGC_TLS_TRUST_H

#include <stdbool.h>
#include <stddef.h>

struct x509_store_st;

/* Adds the system's certificates to `store`: the roots trusted for TLS server authentication, and the certificates
 * the system distrusts, marked rejected for that use. Returns how many it added (0 when no source loaded: verification
 * then fails closed). The platform store is read on the first call only, under a once guard, so a trust change
 * while the process runs is not seen. Safe on any thread; the first call blocks (file reads, Keychain or Crypt32
 * queries), so callers run it in a pool job. The store keeps its own reference to each certificate. */
size_t agc_tls_trust_system(struct x509_store_st *store);

/* Parses one DER certificate and adds it to `store`; with `rejected`, it carries an explicit reject of
 * serverAuth, so a chain through it fails with X509_V_ERR_CERT_REJECTED. The store keeps the first copy of a
 * certificate and ignores later ones, so loaders add rejected certificates before trusted ones. */
bool agc_tls_trust_add_der(struct x509_store_st *store, const unsigned char *der, size_t len, bool rejected);

struct x509_store_ctx_st;

/* The verify callback of every client config. OpenSSL looks up rejected copies only for the certificates it takes
 * from the store (roots and intermediates), so a distrusted end-entity certificate sent by the peer would pass;
 * this callback fails the chain with X509_V_ERR_CERT_REJECTED when the store holds that leaf marked rejected.
 * Otherwise it returns `ok` unchanged. */
int agc_tls_trust_verify(int ok, struct x509_store_ctx_st *ctx);

/* The platform loader, called once by agc_tls_trust_system on a private store, with no other thread inside. */
void agc_tls_trust_load(struct x509_store_st *store);

#endif
