/*
 * The system trust store, shared by every platform: the once-per-process copy
 * of what the platform loader (tls_trust.h) reads, and the DER helper that
 * marks distrusted certificates rejected. Adapter behind tls_trust.h.
 */
#include "tls_trust.h"

#include <limits.h>

#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/objects.h>
#include <openssl/x509.h>
#include <openssl/x509_vfy.h>
#include <openssl/x509v3.h>

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

/* One DER certificate, exactly `len` bytes with nothing after it, or NULL. */
static X509 *parse_der(const unsigned char *der, size_t len) {
  if (len > LONG_MAX) return NULL;
  const unsigned char *p = der;
  X509 *x = d2i_X509(NULL, &p, (long)len);
  if (x && p != der + len) {
    X509_free(x);
    x = NULL;
  }
  return x;
}

/* OpenSSL's check_trust (crypto/x509/x509_vfy.c) asks X509_check_trust of each chain certificate that came from the
 * store; for the SSL server trust id, an explicit reject of serverAuth answers X509_TRUST_REJECTED
 * (obj_trust in crypto/x509/x509_trust.c), and the chain fails with X509_V_ERR_CERT_REJECTED. */
bool agc_tls_trust_add_der(struct x509_store_st *store, const unsigned char *der, size_t len, bool rejected) {
  X509 *x = parse_der(der, len);
  bool ok = x && (!rejected || X509_add1_reject_object(x, OBJ_nid2obj(NID_server_auth)) == 1) &&
            X509_STORE_add_cert(store, x) == 1;
  X509_free(x);
  ERR_clear_error();
  return ok;
}

/* Whether `store` already holds a self-signed certificate with the subject and public key of `x`, so `x` is a
 * cross-signed copy of that anchor. OpenSSL looks an issuer up by subject name and may take the copy, whose own
 * issuer is often missing or distrusted, instead of the anchor: the chain then fails or not by store order, which
 * neither Crypt32 nor OpenSSL's sorted object list keeps stable. A store that cannot be locked answers yes, so the
 * certificate is left out (fail closed). */
static bool stands_for_anchor(X509_STORE *store, X509 *x) {
  EVP_PKEY *key = X509_get0_pubkey(x);
  if (!key || X509_STORE_lock(store) != 1) return true;
  STACK_OF(X509_OBJECT) *objects = X509_STORE_get0_objects(store);
  bool found = false;
  for (int k = 0; k < sk_X509_OBJECT_num(objects) && !found; k++) {
    X509 *y = X509_OBJECT_get0_X509(sk_X509_OBJECT_value(objects, k));
    found = y && (X509_get_extension_flags(y) & EXFLAG_SS) &&
            X509_NAME_cmp(X509_get_subject_name(y), X509_get_subject_name(x)) == 0 &&
            EVP_PKEY_eq(X509_get0_pubkey(y), key) == 1;
  }
  X509_STORE_unlock(store);
  return found;
}

/* A store certificate with no trust settings is an anchor only when it is self-signed (trust_compat in
 * crypto/x509/x509_trust.c); X509_V_FLAG_PARTIAL_CHAIN stays off, so any other one only helps build a chain that
 * must still end at a root. EXFLAG_SI (subject equals issuer) covers every certificate OpenSSL calls self-signed,
 * so refusing it is what keeps an intermediate store from adding an anchor. A rejected copy carries an explicit
 * reject of serverAuth, as in agc_tls_trust_add_der. */
bool agc_tls_trust_add_intermediate_der(struct x509_store_st *store, const unsigned char *der, size_t len,
                                        bool rejected) {
  X509 *x = parse_der(der, len);
  bool ok = x && !(X509_get_extension_flags(x) & EXFLAG_SI) && !stands_for_anchor(store, x) &&
            (!rejected || X509_add1_reject_object(x, OBJ_nid2obj(NID_server_auth)) == 1) &&
            X509_STORE_add_cert(store, x) == 1;
  X509_free(x);
  ERR_clear_error();
  return ok;
}
