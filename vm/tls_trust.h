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

/* Adds the system's certificates to `store`: the roots trusted for TLS server authentication, the intermediates the
 * system keeps for chains (Windows CA store), and the certificates the system distrusts, marked rejected for that
 * use. Returns how many it offered to the store, duplicates included (0 when no source loaded: verification then
 * fails closed). The platform store is read on the first call only, under a once guard, so a trust change while the
 * process runs is not seen, and a first load that failed lasts too. Safe on any thread; the first call blocks (file
 * reads, Keychain or Crypt32 queries), so callers run it in a pool job. The store keeps its own reference to each
 * certificate. */
size_t agc_tls_trust_system(struct x509_store_st *store);

/* Parses one DER certificate (exactly `len` bytes, nothing after it) and adds it to `store`; with `rejected`, it
 * carries an explicit reject of serverAuth, so a chain through it fails with X509_V_ERR_CERT_REJECTED. The store
 * keeps the first copy of a certificate and ignores later ones, so loaders add rejected certificates before trusted
 * ones. */
bool agc_tls_trust_add_der(struct x509_store_st *store, const unsigned char *der, size_t len, bool rejected);

/* Like agc_tls_trust_add_der for a certificate from a store of chain certificates (the Windows CA store): it is
 * added as an intermediate only. A self-issued certificate (subject equals issuer) is refused, since OpenSSL would
 * take it as a trust anchor, and so is one with the subject and public key of a self-signed certificate already in
 * `store` (a cross-signed copy of that anchor), which could hide the anchor from chain building. Call it after the
 * anchors are in. */
bool agc_tls_trust_add_intermediate_der(struct x509_store_st *store, const unsigned char *der, size_t len,
                                        bool rejected);

struct x509_store_ctx_st;

/* The verify callback of every client config. OpenSSL looks up rejected copies only for the certificates it takes
 * from the store (roots and intermediates), so a distrusted end-entity certificate sent by the peer would pass;
 * this callback fails the chain with X509_V_ERR_CERT_REJECTED when the store's in-memory objects hold that leaf
 * marked rejected (no lookup method is asked, so no file is read). Otherwise it returns `ok` unchanged. */
int agc_tls_trust_verify(int ok, struct x509_store_ctx_st *ctx);

/* The platform loader, called once by agc_tls_trust_system on a private store, with no other thread inside. */
void agc_tls_trust_load(struct x509_store_st *store);

/* The policy of each platform loader, exported for its C test (vm/tests/tls_trust_<system>_test.c). */
#ifdef __APPLE__
struct __CFArray;

typedef enum { AGC_TLS_TRUST_NONE, AGC_TLS_TRUST_ROOT, AGC_TLS_TRUST_DENIED } agc_tls_trust_verdict;

/* The verdict of one certificate's trust settings (a CFArrayRef of usage-constraints dictionaries) for TLS. */
agc_tls_trust_verdict agc_tls_trust_settings_verdict(const struct __CFArray *settings);
#endif
#ifdef _WIN32
struct _CERT_CONTEXT;

/* True when the certificate's valid uses (EKU extension and EKU property) include server authentication. */
bool agc_tls_trust_server_auth(const struct _CERT_CONTEXT *cert);

/* Copies three Crypt32 stores (HCERTSTORE, each may be NULL): every certificate of `disallowed` rejected first,
 * then the roots of `root` valid for server authentication, then the intermediates of `ca` (never as anchors),
 * rejected when their valid uses exclude server authentication. agc_tls_trust_load calls it with the system stores
 * Disallowed, ROOT and CA. */
void agc_tls_trust_copy_stores(struct x509_store_st *store, void *disallowed, void *root, void *ca);
#endif

#endif
