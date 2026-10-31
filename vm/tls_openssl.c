/*
 * The TLS adapter over OpenSSL; only it, tls_trust.c, tls_trust_posix.c and
 * digest_openssl.c include OpenSSL. Each session uses two memory BIOs, the trust
 * store and the SNI or IP checks are set up here, and OpenSSL errors become our
 * own codes. Adapter layer, behind tls.h. Design: docs/vm/10-io-tls.md §10.3.
 */
#include "tls.h"
#include "tls_trust.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/bio.h>
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509_vfy.h>
#include <openssl/x509v3.h>

#if OPENSSL_VERSION_NUMBER < 0x30000000L || defined(LIBRESSL_VERSION_NUMBER)
#error "the VM needs OpenSSL 3.0 or newer (LibreSSL is not supported): install the OpenSSL 3 development files or build with AGENTICA_OPENSSL=vendored"
#endif

#define SCRATCH 4096

/* A config is shared by counts (agc_tls_config_ref): a TlsContext value, each socket or listener made from it and an
   HttpClient's lazy context each hold one, on any thread; the last agc_tls_config_free frees it. An SSL takes its own
   count on the SSL_CTX (SSL_new). */
struct agc_tls_config {
  _Atomic size_t refs;
  SSL_CTX *ctx;
  /* A server's ALPN protocols, in the wire form, for select_alpn; NULL for none and on a client. */
  uint8_t *alpn;
  unsigned alpn_len;
};

struct agc_tls {
  SSL *ssl;
  BIO *in, *out;
  bool shut;
};

typedef struct {
  unsigned long last;
  int sys;
  bool verify, mismatch, version, eof;
} queued;

static const int version_reasons[] = {
  SSL_R_UNSUPPORTED_PROTOCOL,     SSL_R_NO_PROTOCOLS_AVAILABLE,     SSL_R_TLSV1_ALERT_PROTOCOL_VERSION,
  SSL_R_NO_SHARED_CIPHER,         SSL_R_NO_CIPHERS_AVAILABLE,       SSL_R_VERSION_TOO_LOW,
  SSL_R_NO_SHARED_GROUPS,         SSL_R_NO_SHARED_SIGNATURE_ALGORITHMS,
};

static const char *const error_names[] = {
  "none",         "verify_untrusted", "verify_expired", "verify_hostname", "verify_failed",
  "handshake_failed", "no_shared_version_or_cipher", "unexpected_eof", "protocol", "bad_ca",
  "bad_cert",     "bad_key",          "key_mismatch",   "nomem",           "internal",
};

static void fail(agc_tls_failure *f, agc_tls_error code, const char *detail) {
  f->code = code;
  f->sys = 0;
  snprintf(f->detail, sizeof f->detail, "%s", detail);
}

static bool version_reason(int reason) {
  for (size_t k = 0; k < sizeof version_reasons / sizeof version_reasons[0]; k++)
    if (version_reasons[k] == reason) return true;
  return false;
}

static queued drain(void) {
  queued q = {0, 0, false, false, false, false};
  unsigned long e;
  while ((e = ERR_get_error()) != 0) {
    if (ERR_SYSTEM_ERROR(e)) {
      if (!q.sys) q.sys = ERR_GET_REASON(e);
      continue;
    }
    int lib = ERR_GET_LIB(e), reason = ERR_GET_REASON(e);
    if (lib == ERR_LIB_X509 && reason == X509_R_KEY_VALUES_MISMATCH) q.mismatch = true;
    if (lib == ERR_LIB_SSL && reason == SSL_R_CERTIFICATE_VERIFY_FAILED) q.verify = true;
    if (lib == ERR_LIB_SSL && reason == SSL_R_UNEXPECTED_EOF_WHILE_READING) q.eof = true;
    if (lib == ERR_LIB_SSL && version_reason(reason)) q.version = true;
    if (!q.last) q.last = e;
  }
  return q;
}

static void fail_queued(agc_tls_failure *f, agc_tls_error code, const queued *q) {
  const char *reason = q->last ? ERR_reason_error_string(q->last) : NULL;
  fail(f, code, reason ? reason : "unknown error");
  f->sys = q->sys;
}

static void take_errors(agc_tls_failure *f, agc_tls_error code) {
  queued q = drain();
  fail_queued(f, code, &q);
}

static agc_tls_error verify_kind(long result) {
  switch (result) {
    case X509_V_ERR_CERT_HAS_EXPIRED:
    case X509_V_ERR_CERT_NOT_YET_VALID: return AGC_TLS_ERR_VERIFY_EXPIRED;
    case X509_V_ERR_HOSTNAME_MISMATCH:
    case X509_V_ERR_IP_ADDRESS_MISMATCH: return AGC_TLS_ERR_VERIFY_HOSTNAME;
    case X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT:
    case X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY:
    case X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT:
    case X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN:
    case X509_V_ERR_UNABLE_TO_VERIFY_LEAF_SIGNATURE:
    case X509_V_ERR_CERT_UNTRUSTED:
    case X509_V_ERR_CERT_REJECTED: return AGC_TLS_ERR_VERIFY_UNTRUSTED;
    default: return AGC_TLS_ERR_VERIFY_FAILED;
  }
}

static void classify(const agc_tls *t, agc_tls_failure *f, agc_tls_error otherwise) {
  queued q = drain();
  if (q.verify) {
    long result = SSL_get_verify_result(t->ssl);
    fail(f, verify_kind(result), "");
    snprintf(f->detail, sizeof f->detail, "certificate verify failed: %s", X509_verify_cert_error_string(result));
    return;
  }
  agc_tls_error code = q.eof ? AGC_TLS_ERR_UNEXPECTED_EOF : q.version ? AGC_TLS_ERR_NO_SHARED_VERSION_OR_CIPHER : otherwise;
  fail_queued(f, code, &q);
}

static agc_tls_status status_of(const agc_tls *t, int r, agc_tls_failure *f, agc_tls_error otherwise) {
  switch (SSL_get_error(t->ssl, r)) {
    case SSL_ERROR_WANT_READ: return AGC_TLS_WANT_READ;
    case SSL_ERROR_WANT_WRITE: return AGC_TLS_WANT_WRITE;
    case SSL_ERROR_ZERO_RETURN: ERR_clear_error(); return AGC_TLS_CLOSED;
    case SSL_ERROR_SYSCALL:
      ERR_clear_error();
      fail(f, AGC_TLS_ERR_UNEXPECTED_EOF, "unexpected eof while reading");
      return AGC_TLS_ERROR;
    case SSL_ERROR_SSL: classify(t, f, otherwise); return AGC_TLS_ERROR;
    default: take_errors(f, AGC_TLS_ERR_INTERNAL); return AGC_TLS_ERROR;
  }
}

static int no_password(char *buf, int size, int rwflag, void *data) {
  (void)buf;
  (void)size;
  (void)rwflag;
  (void)data;
  return 0;
}

static SSL_CTX *new_ctx(const SSL_METHOD *method, agc_tls_failure *f) {
  if (OPENSSL_init_ssl(OPENSSL_INIT_NO_LOAD_CONFIG | OPENSSL_INIT_NO_ATEXIT, NULL) != 1) {
    take_errors(f, AGC_TLS_ERR_INTERNAL);
    return NULL;
  }
  /* The queue is per thread, and a pool thread builds many contexts: errors that an earlier build left (the system
     trust skips the certificates it cannot read) must not become the failure of this one. */
  ERR_clear_error();
  SSL_CTX *ctx = SSL_CTX_new(method);
  if (!ctx || SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION) != 1) {
    take_errors(f, AGC_TLS_ERR_INTERNAL);
    SSL_CTX_free(ctx);
    return NULL;
  }
  SSL_CTX_set_security_level(ctx, 2);
  SSL_CTX_set_options(ctx, SSL_OP_IGNORE_UNEXPECTED_EOF | SSL_OP_NO_RENEGOTIATION);
  SSL_CTX_set_default_passwd_cb(ctx, no_password);
  return ctx;
}

static agc_tls_config *wrap(SSL_CTX *ctx, agc_tls_failure *f) {
  agc_tls_config *c = malloc(sizeof *c);
  if (!c) {
    fail(f, AGC_TLS_ERR_NOMEM, "out of memory");
    SSL_CTX_free(ctx);
    return NULL;
  }
  atomic_init(&c->refs, 1);
  c->ctx = ctx;
  c->alpn = NULL;
  c->alpn_len = 0;
  return c;
}

/* SSL_CERT_FILE, when set, replaces the platform's store (tls_trust.h) on every system; SSL_CERT_DIR adds to either. */
static void system_trust(SSL_CTX *ctx) {
  const char *file = getenv("SSL_CERT_FILE");
  if (!file || !*file) {
    (void)agc_tls_trust_system(SSL_CTX_get_cert_store(ctx));
    ERR_clear_error();
  } else if (SSL_CTX_load_verify_file(ctx, file) != 1)
    ERR_clear_error();
  const char *dir = getenv("SSL_CERT_DIR");
  if (dir && *dir && SSL_CTX_load_verify_dir(ctx, dir) != 1) ERR_clear_error();
}

const char *agc_tls_version(void) { return OpenSSL_version(OPENSSL_VERSION_STRING); }

const char *agc_tls_error_name(agc_tls_error code) {
  size_t k = (size_t)code;
  return k < sizeof error_names / sizeof error_names[0] ? error_names[k] : "internal";
}

/* Loads a PEM certificate chain and its private key into CTX, the server's identity or the client's: false with the
   failure (bad cert, bad key or key mismatch) and CTX freed. */
static bool use_identity(SSL_CTX *ctx, const char *cert_file, const char *key_file, agc_tls_failure *f) {
  if (SSL_CTX_use_certificate_chain_file(ctx, cert_file) != 1) {
    take_errors(f, AGC_TLS_ERR_BAD_CERT);
    SSL_CTX_free(ctx);
    return false;
  }
  if (SSL_CTX_use_PrivateKey_file(ctx, key_file, SSL_FILETYPE_PEM) != 1 || SSL_CTX_check_private_key(ctx) != 1) {
    queued q = drain();
    fail_queued(f, q.mismatch ? AGC_TLS_ERR_KEY_MISMATCH : AGC_TLS_ERR_BAD_KEY, &q);
    SSL_CTX_free(ctx);
    return false;
  }
  return true;
}

agc_tls_config *agc_tls_client_config(const char *ca_file, const char *cert_file, const char *key_file,
                                      agc_tls_failure *failure) {
  SSL_CTX *ctx = new_ctx(TLS_client_method(), failure);
  if (!ctx) return NULL;
  SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, agc_tls_trust_verify);
  if (!*ca_file) {
    system_trust(ctx);
  } else if (SSL_CTX_load_verify_file(ctx, ca_file) != 1) {
    take_errors(failure, AGC_TLS_ERR_BAD_CA);
    SSL_CTX_free(ctx);
    return NULL;
  }
  if (cert_file && !use_identity(ctx, cert_file, key_file, failure)) return NULL;
  return wrap(ctx, failure);
}

agc_tls_config *agc_tls_server_config(const char *cert_file, const char *key_file, agc_tls_failure *failure) {
  SSL_CTX *ctx = new_ctx(TLS_server_method(), failure);
  if (!ctx || !use_identity(ctx, cert_file, key_file, failure)) return NULL;
  return wrap(ctx, failure);
}

/* The server's choice (RFC 7301 §3.2): the first of its protocols that the client offers too, or the fatal alert. It
   runs during a handshake, whose owner holds a count on the config (vm/tcp.c), and OpenSSL copies the choice OUT
   points to into the session. */
static int select_alpn(SSL *ssl, const unsigned char **out, unsigned char *outlen, const unsigned char *in,
                       unsigned inlen, void *arg) {
  (void)ssl;
  const agc_tls_config *c = arg;
  unsigned char *chosen = NULL;
  if (SSL_select_next_proto(&chosen, outlen, c->alpn, c->alpn_len, in, inlen) != OPENSSL_NPN_NEGOTIATED)
    return SSL_TLSEXT_ERR_ALERT_FATAL;
  *out = chosen;
  return SSL_TLSEXT_ERR_OK;
}

bool agc_tls_config_set_alpn(agc_tls_config *config, const uint8_t *wire, size_t len, bool server,
                             agc_tls_failure *failure) {
  if (!len || len > 65535) {
    fail(failure, AGC_TLS_ERR_INTERNAL, "bad ALPN list");
    return false;
  }
  if (!server) {
    /* SSL_CTX_set_alpn_protos returns 0 on success, unlike the other setters. */
    if (SSL_CTX_set_alpn_protos(config->ctx, wire, (unsigned)len) == 0) return true;
    take_errors(failure, AGC_TLS_ERR_INTERNAL);
    return false;
  }
  config->alpn = malloc(len);
  if (!config->alpn) {
    fail(failure, AGC_TLS_ERR_NOMEM, "out of memory");
    return false;
  }
  memcpy(config->alpn, wire, len);
  config->alpn_len = (unsigned)len;
  SSL_CTX_set_alpn_select_cb(config->ctx, select_alpn, config);
  return true;
}

agc_tls_config *agc_tls_config_ref(agc_tls_config *config) {
  if (config) atomic_fetch_add_explicit(&config->refs, 1, memory_order_relaxed);
  return config;
}

void agc_tls_config_free(agc_tls_config *config) {
  if (!config || atomic_fetch_sub_explicit(&config->refs, 1, memory_order_acq_rel) != 1) return;
  SSL_CTX_free(config->ctx);
  free(config->alpn);
  free(config);
}

struct x509_store_st *agc_tls_config_store(agc_tls_config *config) { return SSL_CTX_get_cert_store(config->ctx); }

static agc_tls *new_session(const agc_tls_config *config, agc_tls_failure *f) {
  agc_tls *t = calloc(1, sizeof *t);
  if (!t) {
    fail(f, AGC_TLS_ERR_NOMEM, "out of memory");
    return NULL;
  }
  t->ssl = SSL_new(config->ctx);
  t->in = BIO_new(BIO_s_mem());
  t->out = BIO_new(BIO_s_mem());
  if (!t->ssl || !t->in || !t->out) {
    take_errors(f, AGC_TLS_ERR_NOMEM);
    SSL_free(t->ssl);
    BIO_free(t->in);
    BIO_free(t->out);
    free(t);
    return NULL;
  }
  BIO_set_mem_eof_return(t->in, -1);
  BIO_set_mem_eof_return(t->out, -1);
  SSL_set_bio(t->ssl, t->in, t->out);
  return t;
}

agc_tls *agc_tls_client(agc_tls_config *config, const char *host, agc_tls_failure *failure) {
  agc_tls *t = new_session(config, failure);
  if (!t) return NULL;
  SSL_set_connect_state(t->ssl);
  SSL_set_hostflags(t->ssl, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
  if (X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(t->ssl), host) == 1) return t;
  ERR_clear_error();
  if (SSL_set_tlsext_host_name(t->ssl, host) != 1 || SSL_set1_host(t->ssl, host) != 1) {
    take_errors(failure, AGC_TLS_ERR_HANDSHAKE_FAILED);
    agc_tls_free(t);
    return NULL;
  }
  return t;
}

agc_tls *agc_tls_server(agc_tls_config *config, agc_tls_failure *failure) {
  agc_tls *t = new_session(config, failure);
  if (t) SSL_set_accept_state(t->ssl);
  return t;
}

void agc_tls_free(agc_tls *t) {
  if (!t) return;
  SSL_free(t->ssl);
  free(t);
}

agc_tls_status agc_tls_handshake(agc_tls *t, agc_tls_failure *failure) {
  int r = SSL_do_handshake(t->ssl);
  return r == 1 ? AGC_TLS_OK : status_of(t, r, failure, AGC_TLS_ERR_HANDSHAKE_FAILED);
}

bool agc_tls_feed_in(agc_tls *t, const uint8_t *data, size_t len) {
  size_t written = 0;
  if (len == 0 || (BIO_write_ex(t->in, data, len, &written) == 1 && written == len)) return true;
  ERR_clear_error();
  return false;
}

void agc_tls_feed_eof(agc_tls *t) { BIO_set_mem_eof_return(t->in, 0); }

size_t agc_tls_out_peek(agc_tls *t, const uint8_t **data) {
  char *p = NULL;
  long n = BIO_get_mem_data(t->out, &p);
  *data = (const uint8_t *)p;
  return n > 0 ? (size_t)n : 0;
}

void agc_tls_out_consume(agc_tls *t, size_t len) {
  const uint8_t *data;
  if (len >= agc_tls_out_peek(t, &data)) {
    (void)BIO_reset(t->out);
    return;
  }
  uint8_t scratch[SCRATCH];
  while (len) {
    size_t got = 0;
    if (BIO_read_ex(t->out, scratch, len < SCRATCH ? len : SCRATCH, &got) != 1 || !got) break;
    len -= got;
  }
}

agc_tls_status agc_tls_read(agc_tls *t, uint8_t *buf, size_t cap, size_t *got, agc_tls_failure *failure) {
  *got = 0;
  int r = SSL_read_ex(t->ssl, buf, cap, got);
  return r == 1 ? AGC_TLS_OK : status_of(t, r, failure, AGC_TLS_ERR_PROTOCOL);
}

agc_tls_status agc_tls_write(agc_tls *t, const uint8_t *data, size_t len, agc_tls_failure *failure) {
  size_t written = 0;
  if (len == 0) return AGC_TLS_OK;
  int r = SSL_write_ex(t->ssl, data, len, &written);
  return r == 1 ? AGC_TLS_OK : status_of(t, r, failure, AGC_TLS_ERR_PROTOCOL);
}

void agc_tls_close(agc_tls *t) {
  if (t->shut) return;
  t->shut = true;
  if (SSL_is_init_finished(t->ssl)) (void)SSL_shutdown(t->ssl);
  ERR_clear_error();
}

const char *agc_tls_protocol(const agc_tls *t) { return SSL_get_version(t->ssl); }

const char *agc_tls_cipher(const agc_tls *t) { return SSL_get_cipher_name(t->ssl); }

size_t agc_tls_alpn(const agc_tls *t, const uint8_t **data) {
  const unsigned char *chosen = NULL;
  unsigned len = 0;
  SSL_get0_alpn_selected(t->ssl, &chosen, &len);
  *data = chosen;
  return chosen ? len : 0;
}
