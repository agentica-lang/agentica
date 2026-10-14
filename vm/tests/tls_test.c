/*
 * The TLS adapter with two sessions in memory: handshakes in tiny slices, a
 * 100,000-byte transfer, close_notify, raw EOF and every verify error.
 */
#include "../tls.h"

#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

#define CERTS "tests/fixtures/tls/"

typedef struct {
  agc_tls *client, *server;
  agc_tls_status client_status, server_status;
  agc_tls_failure client_failure, server_failure;
} pair;

#ifdef __linux__
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

static pair connect_pair(const char *ca, const char *host, const char *cert, const char *key, size_t step) {
  pair p;
  memset(&p, 0, sizeof p);
  agc_tls_failure f;
  agc_tls_config *client = agc_tls_client_config(ca, &f);
  agc_tls_config *server = agc_tls_server_config(cert, key, &f);
  assert(client && server);
  p.client = agc_tls_client(client, host, &f);
  p.server = agc_tls_server(server, &f);
  assert(p.client && p.server);
  agc_tls_config_free(client);
  agc_tls_config_free(server);
  handshake(&p, step);
  return p;
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
  agc_tls_config *client = agc_tls_client_config(CERTS "ca.pem", &f);
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
  expect_config(agc_tls_client_config(CERTS "missing.pem", &f), &f, AGC_TLS_ERR_BAD_CA, ENOENT);
  expect_config(agc_tls_client_config(CERTS "make-certs.sh", &f), &f, AGC_TLS_ERR_BAD_CA, 0);
  agc_tls_config *system = agc_tls_client_config("", &f);
  assert(system);
  agc_tls_config_free(system);
}

static void test_names(void) {
  assert(strcmp(agc_tls_error_name(AGC_TLS_ERR_NONE), "none") == 0);
  assert(strcmp(agc_tls_error_name(AGC_TLS_ERR_INTERNAL), "internal") == 0);
  assert(strcmp(agc_tls_error_name(AGC_TLS_ERR_KEY_MISMATCH), "key_mismatch") == 0);
  assert(strncmp(agc_tls_version(), "3.5.", 4) == 0);
}

int main(void) {
  test_names();
  test_config_errors();
  test_round_trip();
  test_raw_eof();
  test_verify_errors();
  test_eof_in_handshake();
  test_garbage();
  puts("tls tests passed");
  return 0;
}
#else
int main(void) {
  puts("tls skipped");
  return 0;
}
#endif
