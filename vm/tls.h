/*
 * The TLS adapter interface: our own types for a config and a session, the
 * status codes (OK, WANT_READ, WANT_WRITE, CLOSED, ERROR) and the error record.
 * The OpenSSL code is in tls_openssl.c. Adapter header. Design:
 * docs/vm/10-io-tls.md §10.3.
 */
#ifndef AGC_TLS_H
#define AGC_TLS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define AGC_TLS_DETAIL 160

typedef struct agc_tls_config agc_tls_config;
typedef struct agc_tls agc_tls;

typedef enum { AGC_TLS_OK, AGC_TLS_WANT_READ, AGC_TLS_WANT_WRITE, AGC_TLS_CLOSED, AGC_TLS_ERROR } agc_tls_status;

typedef enum {
  AGC_TLS_ERR_NONE,
  AGC_TLS_ERR_VERIFY_UNTRUSTED,
  AGC_TLS_ERR_VERIFY_EXPIRED,
  AGC_TLS_ERR_VERIFY_HOSTNAME,
  AGC_TLS_ERR_VERIFY_FAILED,
  AGC_TLS_ERR_HANDSHAKE_FAILED,
  AGC_TLS_ERR_NO_SHARED_VERSION_OR_CIPHER,
  AGC_TLS_ERR_UNEXPECTED_EOF,
  AGC_TLS_ERR_PROTOCOL,
  AGC_TLS_ERR_BAD_CA,
  AGC_TLS_ERR_BAD_CERT,
  AGC_TLS_ERR_BAD_KEY,
  AGC_TLS_ERR_KEY_MISMATCH,
  AGC_TLS_ERR_NOMEM,
  AGC_TLS_ERR_INTERNAL
} agc_tls_error;

typedef struct {
  agc_tls_error code;
  int sys;
  char detail[AGC_TLS_DETAIL];
} agc_tls_failure;

const char *agc_tls_version(void);
const char *agc_tls_error_name(agc_tls_error code);
/* A client config: an empty CA_FILE is the system trust; CERT_FILE and KEY_FILE (PEM) are the client's certificate
   chain and key, both NULL for none. */
agc_tls_config *agc_tls_client_config(const char *ca_file, const char *cert_file, const char *key_file,
                                      agc_tls_failure *failure);
agc_tls_config *agc_tls_server_config(const char *cert_file, const char *key_file, agc_tls_failure *failure);
/* One more count on CONFIG (NULL stays NULL); agc_tls_config_free gives one back and frees the config with the last. */
agc_tls_config *agc_tls_config_ref(agc_tls_config *config);
void agc_tls_config_free(agc_tls_config *config);
/* The config's OpenSSL X509_STORE, for the C tests that check which certificates a config trusts. */
struct x509_store_st *agc_tls_config_store(agc_tls_config *config);
agc_tls *agc_tls_client(agc_tls_config *config, const char *host, agc_tls_failure *failure);
agc_tls *agc_tls_server(agc_tls_config *config, agc_tls_failure *failure);
void agc_tls_free(agc_tls *t);
agc_tls_status agc_tls_handshake(agc_tls *t, agc_tls_failure *failure);
bool agc_tls_feed_in(agc_tls *t, const uint8_t *data, size_t len);
void agc_tls_feed_eof(agc_tls *t);
size_t agc_tls_out_peek(agc_tls *t, const uint8_t **data);
void agc_tls_out_consume(agc_tls *t, size_t len);
agc_tls_status agc_tls_read(agc_tls *t, uint8_t *buf, size_t cap, size_t *got, agc_tls_failure *failure);
agc_tls_status agc_tls_write(agc_tls *t, const uint8_t *data, size_t len, agc_tls_failure *failure);
void agc_tls_close(agc_tls *t);
const char *agc_tls_protocol(const agc_tls *t);
const char *agc_tls_cipher(const agc_tls *t);

#endif
