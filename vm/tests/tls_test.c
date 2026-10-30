/*
 * The TLS adapter with two sessions in memory: handshakes in tiny slices, a
 * 100,000-byte transfer, close_notify, raw EOF, every verify error, the
 * trust sources and rejected certificates. No sockets: runs on every system.
 */
#include "../tls.h"
#include "../tls_trust.h"

#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/x509_vfy.h>
#include <openssl/x509v3.h>

#define CERTS "tests/fixtures/tls/"

typedef struct {
  agc_tls *client, *server;
  agc_tls_status client_status, server_status;
  agc_tls_failure client_failure, server_failure;
} pair;

static void set_cert_file(const char *value) {
#ifdef _WIN32
  assert(_putenv_s("SSL_CERT_FILE", value ? value : "") == 0);
#else
  assert(value ? setenv("SSL_CERT_FILE", value, 1) == 0 : unsetenv("SSL_CERT_FILE") == 0);
#endif
}

static void pass(agc_tls *from, agc_tls *to, size_t step) {
  const uint8_t *data;
  size_t len;
  while ((len = agc_tls_out_peek(from, &data)) > 0) {
    size_t take = len < step ? len : step;
    assert(agc_tls_feed_in(to, data, take));
    agc_tls_out_consume(from, take);
  }
}

static bool settled(agc_tls_status status) { return status != AGC_TLS_WANT_READ && status != AGC_TLS_WANT_WRITE; }

static void handshake(pair *p, size_t step) {
  p->client_status = p->server_status = AGC_TLS_WANT_READ;
  for (int round = 0; round < 50; round++) {
    if (!settled(p->client_status)) p->client_status = agc_tls_handshake(p->client, &p->client_failure);
    pass(p->client, p->server, step);
    if (!settled(p->server_status)) p->server_status = agc_tls_handshake(p->server, &p->server_failure);
    pass(p->server, p->client, step);
    if (settled(p->client_status) && settled(p->server_status)) return;
    if (p->client_status == AGC_TLS_ERROR || p->server_status == AGC_TLS_ERROR) return;
  }
}

/* A client and a server session on these configs, which the sessions keep alive (SSL_new up-refs the SSL_CTX). */
static pair pair_on(agc_tls_config *client, agc_tls_config *server, const char *host, size_t step) {
  pair p;
  memset(&p, 0, sizeof p);
  agc_tls_failure f;
  assert(client && server);
  p.client = agc_tls_client(client, host, &f);
  p.server = agc_tls_server(server, &f);
  assert(p.client && p.server);
  agc_tls_config_free(client);
  agc_tls_config_free(server);
  handshake(&p, step);
  return p;
}

static pair connect_pair(const char *ca, const char *host, const char *cert, const char *key, size_t step) {
  agc_tls_failure f;
  return pair_on(agc_tls_client_config(ca, NULL, NULL, &f), agc_tls_server_config(cert, key, &f), host, step);
}

static void free_pair(pair *p) {
  agc_tls_free(p->client);
  agc_tls_free(p->server);
}

static size_t read_all(agc_tls *t, uint8_t *buf, size_t cap, agc_tls_status *last) {
  agc_tls_failure f;
  size_t total = 0;
  for (;;) {
    size_t got = 0;
    *last = agc_tls_read(t, buf + total, cap - total, &got, &f);
    total += got;
    if (*last != AGC_TLS_OK || total == cap) return total;
  }
}

static void test_round_trip(void) {
  pair p = connect_pair(CERTS "ca.pem", "localhost", CERTS "server.pem", CERTS "server-key.pem", 7);
  assert(p.client_status == AGC_TLS_OK && p.server_status == AGC_TLS_OK);
  assert(strcmp(agc_tls_protocol(p.client), "TLSv1.3") == 0);
  agc_tls_failure f;
  static uint8_t big[100000], got[100000];
  for (size_t k = 0; k < sizeof big; k++) big[k] = (uint8_t)(k * 7);
  assert(agc_tls_write(p.client, big, sizeof big, &f) == AGC_TLS_OK);
  pass(p.client, p.server, 1000);
  agc_tls_status last;
  assert(read_all(p.server, got, sizeof got, &last) == sizeof got);
  assert(memcmp(big, got, sizeof big) == 0);
  assert(agc_tls_write(p.server, (const uint8_t *)"pong", 4, &f) == AGC_TLS_OK);
  agc_tls_close(p.server);
  pass(p.server, p.client, 3);
  size_t n = read_all(p.client, got, sizeof got, &last);
  assert(n == 4 && memcmp(got, "pong", 4) == 0 && last == AGC_TLS_CLOSED);
  free_pair(&p);
}

static void test_raw_eof(void) {
  pair p = connect_pair(CERTS "ca.pem", "127.0.0.1", CERTS "server.pem", CERTS "server-key.pem", 4096);
  assert(p.client_status == AGC_TLS_OK && p.server_status == AGC_TLS_OK);
  agc_tls_failure f;
  assert(agc_tls_write(p.server, (const uint8_t *)"x", 1, &f) == AGC_TLS_OK);
  pass(p.server, p.client, 4096);
  agc_tls_feed_eof(p.client);
  uint8_t got[16];
  agc_tls_status last;
  assert(read_all(p.client, got, sizeof got, &last) == 1 && last == AGC_TLS_CLOSED);
  free_pair(&p);
}

static void expect_client_error(const char *ca, const char *host, const char *cert, const char *key, agc_tls_error code) {
  pair p = connect_pair(ca, host, cert, key, 4096);
  assert(p.client_status == AGC_TLS_ERROR);
  assert(p.client_failure.code == code);
  assert(strstr(p.client_failure.detail, "certificate verify failed") != NULL);
  free_pair(&p);
}

static void test_verify_errors(void) {
  expect_client_error(CERTS "ca.pem", "wrong.example", CERTS "server.pem", CERTS "server-key.pem",
                      AGC_TLS_ERR_VERIFY_HOSTNAME);
  expect_client_error(CERTS "ca.pem", "10.0.0.1", CERTS "server.pem", CERTS "server-key.pem", AGC_TLS_ERR_VERIFY_HOSTNAME);
  expect_client_error(CERTS "ca.pem", "localhost", CERTS "wrong-host.pem", CERTS "wrong-host-key.pem",
                      AGC_TLS_ERR_VERIFY_HOSTNAME);
  expect_client_error(CERTS "ca.pem", "localhost", CERTS "expired.pem", CERTS "expired-key.pem",
                      AGC_TLS_ERR_VERIFY_EXPIRED);
  expect_client_error(CERTS "ca.pem", "localhost", CERTS "self-signed.pem", CERTS "self-signed-key.pem",
                      AGC_TLS_ERR_VERIFY_UNTRUSTED);
  expect_client_error(CERTS "self-signed.pem", "localhost", CERTS "server.pem", CERTS "server-key.pem",
                      AGC_TLS_ERR_VERIFY_UNTRUSTED);
}

static void test_eof_in_handshake(void) {
  agc_tls_failure f;
  agc_tls_config *client = agc_tls_client_config(CERTS "ca.pem", NULL, NULL, &f);
  assert(client);
  agc_tls *t = agc_tls_client(client, "localhost", &f);
  assert(agc_tls_handshake(t, &f) == AGC_TLS_WANT_READ);
  const uint8_t *data;
  assert(agc_tls_out_peek(t, &data) > 0);
  agc_tls_feed_eof(t);
  agc_tls_status status = agc_tls_handshake(t, &f);
  assert(status == AGC_TLS_CLOSED || (status == AGC_TLS_ERROR && f.code == AGC_TLS_ERR_UNEXPECTED_EOF));
  agc_tls_free(t);
  agc_tls_config_free(client);
}

static void test_garbage(void) {
  agc_tls_failure f;
  agc_tls_config *server = agc_tls_server_config(CERTS "server.pem", CERTS "server-key.pem", &f);
  agc_tls *t = agc_tls_server(server, &f);
  const char *request = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
  assert(agc_tls_feed_in(t, (const uint8_t *)request, strlen(request)));
  assert(agc_tls_handshake(t, &f) == AGC_TLS_ERROR);
  assert(f.code == AGC_TLS_ERR_HANDSHAKE_FAILED);
  assert(strcmp(f.detail, "http request") == 0);
  agc_tls_free(t);
  agc_tls_config_free(server);
}

static void expect_config(agc_tls_config *config, const agc_tls_failure *f, agc_tls_error code, int sys) {
  assert(!config);
  assert(f->code == code);
  assert(f->sys == sys);
}

static void test_config_errors(void) {
  agc_tls_failure f;
  expect_config(agc_tls_server_config(CERTS "missing.pem", CERTS "server-key.pem", &f), &f, AGC_TLS_ERR_BAD_CERT, ENOENT);
  expect_config(agc_tls_server_config(CERTS "server-key.pem", CERTS "server-key.pem", &f), &f, AGC_TLS_ERR_BAD_CERT, 0);
  expect_config(agc_tls_server_config(CERTS "server.pem", CERTS "missing.pem", &f), &f, AGC_TLS_ERR_BAD_KEY, ENOENT);
  expect_config(agc_tls_server_config(CERTS "server.pem", CERTS "server.pem", &f), &f, AGC_TLS_ERR_BAD_KEY, 0);
  expect_config(agc_tls_server_config(CERTS "server.pem", CERTS "wrong-host-key.pem", &f), &f, AGC_TLS_ERR_KEY_MISMATCH,
                0);
  expect_config(agc_tls_client_config(CERTS "missing.pem", NULL, NULL, &f), &f, AGC_TLS_ERR_BAD_CA, ENOENT);
  expect_config(agc_tls_client_config(CERTS "make-certs.sh", NULL, NULL, &f), &f, AGC_TLS_ERR_BAD_CA, 0);
  /* A client certificate fails as the server's does. */
  expect_config(agc_tls_client_config(CERTS "ca.pem", CERTS "client.pem", CERTS "server-key.pem", &f), &f,
                AGC_TLS_ERR_KEY_MISMATCH, 0);
  agc_tls_config *system = agc_tls_client_config("", NULL, NULL, &f);
  assert(system);
  agc_tls_config_free(system);
}

/* An empty ca_file means system trust: the platform store does not know the test CA, SSL_CERT_FILE replaces that
 * store, and a non-empty ca_file still wins over SSL_CERT_FILE. */
static void test_trust_sources(void) {
  set_cert_file(NULL);
  expect_client_error("", "localhost", CERTS "server.pem", CERTS "server-key.pem", AGC_TLS_ERR_VERIFY_UNTRUSTED);
  set_cert_file(CERTS "ca.pem");
  pair p = connect_pair("", "localhost", CERTS "server.pem", CERTS "server-key.pem", 4096);
  assert(p.client_status == AGC_TLS_OK && p.server_status == AGC_TLS_OK);
  free_pair(&p);
  expect_client_error(CERTS "self-signed.pem", "localhost", CERTS "server.pem", CERTS "server-key.pem",
                      AGC_TLS_ERR_VERIFY_UNTRUSTED);
  set_cert_file(NULL);
}

static X509 *read_pem(const char *path) {
  FILE *f = fopen(path, "rb");
  assert(f);
  X509 *x = PEM_read_X509(f, NULL, NULL, NULL);
  fclose(f);
  assert(x);
  return x;
}

/* Adds a fixture certificate through a loaders' helper (the intermediate one or not), rejected for serverAuth or
 * trusted. */
static bool add_fixture(X509_STORE *store, const char *path, bool rejected, bool intermediate) {
  X509 *x = read_pem(path);
  unsigned char *der = NULL;
  int len = i2d_X509(x, &der);
  assert(len > 0);
  bool ok = intermediate ? agc_tls_trust_add_intermediate_der(store, der, (size_t)len, rejected)
                         : agc_tls_trust_add_der(store, der, (size_t)len, rejected);
  OPENSSL_free(der);
  X509_free(x);
  return ok;
}

static bool add_pem(X509_STORE *store, const char *path, bool rejected) {
  return add_fixture(store, path, rejected, false);
}

/* X509_verify_cert of `leaf`, with the certificates the peer also sent (`sent`, or NULL), against `store` for a TLS
 * server, with the clients' verify callback; the error, or 0. */
static int verify_sent(X509_STORE *store, X509 *leaf, STACK_OF(X509) *sent) {
  X509_STORE_CTX *ctx = X509_STORE_CTX_new();
  assert(ctx && X509_STORE_CTX_init(ctx, store, leaf, sent) == 1);
  assert(X509_STORE_CTX_set_purpose(ctx, X509_PURPOSE_SSL_SERVER) == 1);
  X509_STORE_CTX_set_verify_cb(ctx, agc_tls_trust_verify);
  int ok = X509_verify_cert(ctx);
  int error = ok == 1 ? 0 : X509_STORE_CTX_get_error(ctx);
  assert(ok == 1 || error != 0);
  X509_STORE_CTX_free(ctx);
  return error;
}

static int verify(X509_STORE *store, X509 *leaf) { return verify_sent(store, leaf, NULL); }

/* A certificate the system distrusts is in the store marked rejected. The test CA trusted verifies server.pem;
 * rejected it gives X509_V_ERR_CERT_REJECTED, also when a trusted copy is added after it (the store keeps the first
 * copy). A rejected leaf is refused by the verify callback, which OpenSSL alone would accept. DER with trailing
 * bytes is refused. */
static void test_rejected(void) {
  X509 *leaf = read_pem(CERTS "server.pem");
  X509_STORE *trusted = X509_STORE_new();
  assert(add_pem(trusted, CERTS "ca.pem", false));
  assert(verify(trusted, leaf) == 0);
  X509_STORE_free(trusted);
  X509_STORE *rejected = X509_STORE_new();
  assert(add_pem(rejected, CERTS "ca.pem", true));
  assert(add_pem(rejected, CERTS "ca.pem", false));
  assert(verify(rejected, leaf) == X509_V_ERR_CERT_REJECTED);
  X509_STORE_free(rejected);
  X509_STORE *leaf_rejected = X509_STORE_new();
  assert(add_pem(leaf_rejected, CERTS "server.pem", true));
  assert(add_pem(leaf_rejected, CERTS "ca.pem", false));
  assert(verify(leaf_rejected, leaf) == X509_V_ERR_CERT_REJECTED);
  X509_STORE_free(leaf_rejected);
  X509_STORE *garbage = X509_STORE_new();
  assert(!agc_tls_trust_add_der(garbage, (const unsigned char *)"not der", 7, true));
  unsigned char *der = NULL;
  int len = i2d_X509(leaf, &der);
  assert(len > 0);
  unsigned char *longer = OPENSSL_malloc((size_t)len + 1);
  assert(longer);
  memcpy(longer, der, (size_t)len);
  longer[len] = 0;
  assert(!agc_tls_trust_add_der(garbage, longer, (size_t)len + 1, false));
  assert(agc_tls_trust_add_der(garbage, longer, (size_t)len, false));
  OPENSSL_free(longer);
  OPENSSL_free(der);
  X509_STORE_free(garbage);
  X509_free(leaf);
}

#define CHAIN CERTS "chain-"

/* The intermediate-store rule on every system (the Windows CA store uses it): an intermediate completes a chain
 * that still ends at a root, and is never an anchor itself; a self-issued certificate and a cross-signed copy of a
 * store anchor are refused; a rejected intermediate fails the chain even when the peer sends it too. A sibling of
 * the intermediate whose EKU extension allows only email is refused, so a peer that sends the valid one still
 * verifies; a plain store copy of that sibling would be taken first and fail the chain. */
static void test_intermediates(void) {
  X509 *leaf = read_pem(CHAIN "leaf.pem"), *inter = read_pem(CHAIN "intermediate.pem");
  X509_STORE *store = X509_STORE_new();
  assert(add_pem(store, CHAIN "cross-signer.pem", true));
  assert(add_pem(store, CHAIN "root.pem", false));
  assert(verify(store, leaf) == X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY);
  assert(!add_fixture(store, CHAIN "root-cross.pem", false, true));
  assert(!add_fixture(store, CERTS "ca.pem", false, true));
  assert(add_fixture(store, CHAIN "intermediate.pem", false, true));
  assert(verify(store, leaf) == 0);
  X509_STORE_free(store);
  X509_STORE *alone = X509_STORE_new();
  assert(add_fixture(alone, CHAIN "intermediate.pem", false, true));
  assert(verify(alone, leaf) == X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT);
  X509_STORE_free(alone);
  X509_STORE *rejected = X509_STORE_new();
  assert(add_pem(rejected, CHAIN "root.pem", false));
  assert(add_fixture(rejected, CHAIN "intermediate.pem", true, true));
  assert(verify(rejected, leaf) == X509_V_ERR_CERT_REJECTED);
  STACK_OF(X509) *sent = sk_X509_new_null();
  assert(sent && sk_X509_push(sent, inter) > 0);
  assert(verify_sent(rejected, leaf, sent) == X509_V_ERR_CERT_REJECTED);
  X509_STORE *siblings = X509_STORE_new(), *shadowed = X509_STORE_new();
  assert(add_pem(siblings, CHAIN "root.pem", false) && add_pem(shadowed, CHAIN "root.pem", false));
  assert(!add_fixture(siblings, CHAIN "intermediate-email.pem", false, true));
  assert(!add_fixture(siblings, CHAIN "intermediate-email.pem", true, true));
  assert(verify_sent(siblings, leaf, sent) == 0);
  assert(add_pem(shadowed, CHAIN "intermediate-email.pem", false));
  assert(verify_sent(shadowed, leaf, sent) == X509_V_ERR_INVALID_PURPOSE);
  X509_STORE_free(shadowed);
  X509_STORE_free(siblings);
  sk_X509_free(sent);
  X509_STORE_free(rejected);
  X509_free(inter);
  X509_free(leaf);
}

/* A client config with no ca_file and no SSL_CERT_FILE holds the platform store, and at least one of its roots
 * verifies as a TLS server chain against it (some system roots are expired). Required on macOS and Windows; a Linux
 * machine without a CA bundle (a minimal container) has none, and the client then fails closed. */
static void test_system_store(void) {
  set_cert_file(NULL);
  agc_tls_failure f;
  agc_tls_config *config = agc_tls_client_config("", NULL, NULL, &f);
  assert(config);
  X509_STORE *store = agc_tls_config_store(config);
  STACK_OF(X509) *certs = X509_STORE_get1_all_certs(store);
  assert(certs);
  int held = sk_X509_num(certs), verified = 0;
  for (int k = 0; k < held && !verified; k++)
    if (verify(store, sk_X509_value(certs, k)) == 0) verified++;
#if defined(_WIN32) || defined(__APPLE__)
  assert(held > 0);
#endif
  assert(held == 0 || verified > 0);
  printf("tls: %d system certificates\n", held);
  sk_X509_pop_free(certs, X509_free);
  agc_tls_config_free(config);
  X509_STORE *direct = X509_STORE_new();
  assert(direct && agc_tls_trust_system(direct) == (size_t)held);
  X509_STORE_free(direct);
}

/* The same through a client config and a handshake: a rejected copy of the server's certificate in the config's
 * store fails the client with VERIFY_UNTRUSTED, so the config uses the verify callback. */
static void test_rejected_handshake(void) {
  agc_tls_failure f;
  agc_tls_config *client = agc_tls_client_config(CERTS "ca.pem", NULL, NULL, &f);
  assert(client && add_pem(agc_tls_config_store(client), CERTS "server.pem", true));
  pair p = pair_on(client, agc_tls_server_config(CERTS "server.pem", CERTS "server-key.pem", &f), "localhost", 4096);
  assert(p.client_status == AGC_TLS_ERROR && p.client_failure.code == AGC_TLS_ERR_VERIFY_UNTRUSTED);
  assert(strstr(p.client_failure.detail, "certificate verify failed") != NULL);
  free_pair(&p);
}

static void test_names(void) {
  assert(strcmp(agc_tls_error_name(AGC_TLS_ERR_NONE), "none") == 0);
  assert(strcmp(agc_tls_error_name(AGC_TLS_ERR_INTERNAL), "internal") == 0);
  assert(strcmp(agc_tls_error_name(AGC_TLS_ERR_KEY_MISMATCH), "key_mismatch") == 0);
  unsigned int major = 0;
  assert(sscanf(agc_tls_version(), "%u.", &major) == 1);
  assert(major >= 3);
}

int main(void) {
  test_names();
  test_config_errors();
  test_round_trip();
  test_raw_eof();
  test_verify_errors();
  test_eof_in_handshake();
  test_garbage();
  test_trust_sources();
  test_rejected();
  test_intermediates();
  test_rejected_handshake();
  test_system_store();
  puts("tls tests passed");
  return 0;
}
