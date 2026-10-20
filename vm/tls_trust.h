/*
 * The system trust store of each platform, for a client with no ca_file.
 * Linux and other POSIX: the first readable PEM bundle of the usual paths
 * (tls_trust_posix.c). macOS: the Security framework anchors and trust
 * settings (tls_trust_darwin.c). Windows: the ROOT store of Crypt32
 * (tls_trust_windows.c). Adapter header, used by tls_openssl.c only.
 */
#ifndef AGC_TLS_TRUST_H
#define AGC_TLS_TRUST_H

#include <stddef.h>

struct x509_store_st;

/* Adds the roots the system trusts for TLS server authentication to `store`
 * and returns how many it added. A source that fails is skipped, so the count
 * may be 0: verification then fails closed. The store keeps its own reference
 * to each certificate. Safe on any thread; it blocks (file reads, IPC to the
 * system's trust daemon), so it runs in a pool job. */
size_t agc_tls_trust_system(struct x509_store_st *store);

#endif
