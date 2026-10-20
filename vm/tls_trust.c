/*
 * The system trust store, shared by every platform: the once-per-process copy
 * of what the platform loader (tls_trust.h) reads, and the DER helper that
 * marks distrusted certificates rejected. Adapter behind tls_trust.h.
 */
#include "tls_trust.h"

#include <limits.h>

#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/objects.h>
#include <openssl/x509.h>
#include <openssl/x509_vfy.h>

/* The process-wide copy of the platform store: written once by load_system under system_once, read-only after.
 * Its X509 objects are shared by every store (reference counted, never changed after loading). Never freed. The
 * list is STACK_OF(X509), spelled out because the style scanner reads that macro as a function prototype. */
static CRYPTO_ONCE system_once = CRYPTO_ONCE_STATIC_INIT; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
static struct stack_st_X509 *system_certs; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)

static void load_system(void) {
  X509_STORE *store = X509_STORE_new();
  if (!store) return;
  agc_tls_trust_load(store);
  system_certs = X509_STORE_get1_all_certs(store);
  X509_STORE_free(store);
  ERR_clear_error();
}

size_t agc_tls_trust_system(struct x509_store_st *store) {
  if (CRYPTO_THREAD_run_once(&system_once, load_system) != 1 || !system_certs) {
    ERR_clear_error();
    return 0;
  }
  size_t added = 0;
  for (int k = 0; k < sk_X509_num(system_certs); k++)
    if (X509_STORE_add_cert(store, sk_X509_value(system_certs, k)) == 1) added++;
  ERR_clear_error();
  return added;
}

/* Only the store's in-memory objects are scanned, under its lock: X509_STORE_CTX_get1_certs would also ask the
 * lookup methods, which with SSL_CERT_DIR probe files on the I/O thread at every handshake. A store that cannot be
 * locked fails the chain closed. */
int agc_tls_trust_verify(int ok, struct x509_store_ctx_st *ctx) {
  if (!ok || X509_STORE_CTX_get_error_depth(ctx) != 0) return ok;
  X509 *leaf = X509_STORE_CTX_get_current_cert(ctx);
  X509_STORE *store = X509_STORE_CTX_get0_store(ctx);
  if (!leaf || !store) return ok;
  if (X509_STORE_lock(store) != 1) {
    ERR_clear_error();
    X509_STORE_CTX_set_error(ctx, X509_V_ERR_UNSPECIFIED);
    return 0;
  }
  STACK_OF(X509_OBJECT) *objects = X509_STORE_get0_objects(store);
  bool rejected = false;
  for (int k = 0; k < sk_X509_OBJECT_num(objects) && !rejected; k++) {
    X509 *x = X509_OBJECT_get0_X509(sk_X509_OBJECT_value(objects, k));
    rejected = x && X509_cmp(x, leaf) == 0 && X509_check_trust(x, X509_TRUST_SSL_SERVER, 0) == X509_TRUST_REJECTED;
  }
  X509_STORE_unlock(store);
  ERR_clear_error();
  if (!rejected) return ok;
  X509_STORE_CTX_set_error(ctx, X509_V_ERR_CERT_REJECTED);
  return 0;
}

/* OpenSSL's check_trust (crypto/x509/x509_vfy.c) asks X509_check_trust of each chain certificate that came from the
 * store; for the SSL server trust id, an explicit reject of serverAuth answers X509_TRUST_REJECTED
 * (obj_trust in crypto/x509/x509_trust.c), and the chain fails with X509_V_ERR_CERT_REJECTED. */
bool agc_tls_trust_add_der(struct x509_store_st *store, const unsigned char *der, size_t len, bool rejected) {
  if (len > LONG_MAX) return false;
  const unsigned char *p = der;
  X509 *x = d2i_X509(NULL, &p, (long)len);
  bool ok = x && p == der + len && (!rejected || X509_add1_reject_object(x, OBJ_nid2obj(NID_server_auth)) == 1) &&
            X509_STORE_add_cert(store, x) == 1;
  X509_free(x);
  ERR_clear_error();
  return ok;
}
