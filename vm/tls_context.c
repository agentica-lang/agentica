/*
 * TLS.client_context and TLS.server_context: a TlsContext, the TLS config of
 * one role built once from its options record (the CA file, or a certificate
 * chain and key, read and checked when it is built) and shared by every socket,
 * listener and HttpClient made from it; and the role check of the calls that
 * take one. The build is one pool job, so it parks only its task. Service layer.
 * Design: docs/vm/10-io-tls.md §10.3 (Contexts).
 */
#include "net.h"

#include <inttypes.h>
#include <stdlib.h>
#include <string.h>

/* TlsClientOptions and TlsServerOptions as compiler/catalog/builtins_data.agc lays them out. */
#define CLIENT_FIELDS 4
#define SERVER_FIELDS 3
/* RFC 7301: a protocol name is 1 to 255 bytes, and the list goes in a 16-bit length. */
#define ALPN_NAME_MAX 255
#define ALPN_LIST_MAX 65535

/* One build: the paths (malloc'd; NULL for a field left empty, ca NULL for the system trust), the ALPN protocols in
   their wire form (NULL for none), and what the pool work made. Only the pool work writes `config` and `failure`; the
   done half owns the rest. */
typedef struct {
  char *ca, *cert, *key;
  uint8_t *alpn;
  size_t alpn_len, protocols;
  bool server;
  agc_tls_config *config;
  agc_tls_failure failure;
} build;

static void release_config(void *config) { agc_tls_config_free(config); }

static void free_build(build *b) {
  agc_tls_config_free(b->config);
  free(b->ca);
  free(b->cert);
  free(b->key);
  free(b->alpn);
  free(b);
}

static void work(void *data) {
  build *b = data;
  b->config = b->server ? agc_tls_server_config(b->cert, b->key, &b->failure)
                        : agc_tls_client_config(b->ca ? b->ca : "", b->cert, b->key, &b->failure);
  if (b->config && b->alpn && !agc_tls_config_set_alpn(b->config, b->alpn, b->alpn_len, b->server, &b->failure)) {
    agc_tls_config_free(b->config);
    b->config = NULL;
  }
}

static agc_value build_error(agc_vm *vm, const build *b) {
  const agc_tls_failure *f = &b->failure;
  if (f->code == AGC_TLS_ERR_BAD_CA) return agc_tls_load_error(vm, "ssl-load-verify-source!", b->ca, f);
  if (f->code == AGC_TLS_ERR_BAD_CERT) return agc_tls_load_error(vm, "ssl-load-certificate-chain!", b->cert, f);
  if (f->code == AGC_TLS_ERR_BAD_KEY || f->code == AGC_TLS_ERR_KEY_MISMATCH)
    return agc_tls_load_error(vm, "ssl-load-private-key!", b->key, f);
  return agc_tls_failure_error(vm, b->server ? "ssl-make-server-context: setup failed"
                                             : "ssl-make-client-context: setup failed", f);
}

static agc_value done(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  build *b = data;
  agc_value result;
  if (b->config) {
    AGC_TRACE(&vm->rt->trace, AGC_TRACE_TLS, "tls_context role=%s ca=%s alpn=%zu", b->server ? "server" : "client",
              b->server ? "none" : b->ca ? "file" : "system", b->protocols);
    result = agc_result_value(true, agc_tls_context_value(b->config, release_config, b->server));
    b->config = NULL;
  } else {
    result = build_error(vm, b);
  }
  free_build(b);
  return result;
}

/* No deadline: the job is never expired, and a detached one runs to its end and is dropped here. */
static agc_value expired(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)data;
  (void)context;
  return agc_error_value("network: operation timed out");
}

static void drop(void *data) { free_build(data); }

static const agc_io_kind context_io = {work, done, expired, drop, false, "tls", NULL, false, NULL};

/* The path of a field: NULL for "", false for a path with NUL. */
static bool path_of(agc_vm *vm, agc_value field, char **path) {
  const agc_string *s = agc_as_string(vm, field);
  *path = NULL;
  if (s->bytes == 0) return true;
  *path = agc_cstr(s);
  return *path != NULL;
}

/* The size of the alpn field in the wire form of RFC 7301, each name after its length byte, into *LEN: NULL, or the
   refusal of a name that is empty or longer than 255 bytes, or of a list longer than 65535 bytes. */
static const char *alpn_size(agc_vm *vm, agc_value field, size_t *len) {
  agc_list_cursor cursor;
  agc_value item;
  *len = 0;
  agc_list_cursor_begin(&cursor, agc_as_list(vm, field), 0);
  while (agc_list_cursor_next(&cursor, &item)) {
    size_t bytes = agc_as_string(vm, item)->bytes;
    if (bytes == 0 || bytes > ALPN_NAME_MAX) return "network: an ALPN protocol name is 1 to 255 bytes";
    *len += 1 + bytes;
    if (*len > ALPN_LIST_MAX) return "network: the ALPN protocols take more than 65535 bytes";
  }
  return NULL;
}

/* The alpn field of LEN bytes (alpn_size) in its wire form into B; an empty list leaves b->alpn NULL. */
static void alpn_of(agc_vm *vm, agc_value field, size_t len, build *b) {
  if (!len) return;
  b->alpn = malloc(len);
  if (!b->alpn) agc_out_of_memory();
  b->alpn_len = len;
  agc_list_cursor cursor;
  agc_value item;
  size_t at = 0;
  agc_list_cursor_begin(&cursor, agc_as_list(vm, field), 0);
  while (agc_list_cursor_next(&cursor, &item)) {
    const agc_string *name = agc_as_string(vm, item);
    b->alpn[at++] = (uint8_t)name->bytes;
    memcpy(b->alpn + at, name->data, name->bytes);
    at += name->bytes;
    b->protocols++;
  }
}

/* A field count other than the record's is bytecode the front end would not write: a wrong-type failure, as for any
   other argument. */
static agc_value start_build(agc_vm *vm, agc_value options, bool server, uint32_t span) {
  if (vm->rt->no_files) agc_fail(vm, "RUNTIME-INTERNAL", "network access is off in this run", span);
  const agc_struct *o = agc_as_struct(vm, options);
  if (o->n != (server ? SERVER_FIELDS : CLIENT_FIELDS)) agc_wrong_tag(vm);
  if (vm->rt->deny_net) return agc_error_value(AGC_DENIED_NET);
  agc_value alpn = o->fields[server ? 2 : 3];
  size_t alpn_len;
  const char *refused = alpn_size(vm, alpn, &alpn_len);
  if (refused) return agc_error_value(refused);
  build *b = calloc(1, sizeof *b);
  if (!b) agc_out_of_memory();
  b->server = server;
  bool paths = server ? path_of(vm, o->fields[0], &b->cert) && path_of(vm, o->fields[1], &b->key)
                      : path_of(vm, o->fields[0], &b->ca) && path_of(vm, o->fields[1], &b->cert) &&
                          path_of(vm, o->fields[2], &b->key);
  if (!paths)
    refused = "network: path cannot contain NUL";
  else if (server && (!b->cert || !b->key))
    refused = "network: a server context needs cert_file and key_file";
  else if (!b->cert != !b->key)
    refused = "network: cert_file and key_file go together";
  else if (vm->rt->deny_fs && (b->ca || b->cert))
    refused = AGC_DENIED_FS;
  if (refused) {
    free_build(b);
    return agc_error_value(refused);
  }
  alpn_of(vm, alpn, alpn_len, b);
  agc_io_start(vm, &context_io, b, agc_void(), -1);
  return agc_void();
}

static agc_value builtin_client_context(agc_vm *vm, agc_value *args, uint32_t span) {
  return start_build(vm, args[0], false, span);
}

static agc_value builtin_server_context(agc_vm *vm, agc_value *args, uint32_t span) {
  return start_build(vm, args[0], true, span);
}

void agc_tls_context_check(agc_vm *vm, agc_value context, bool server, const char *message, uint32_t at) {
  if (agc_as_tls_context(vm, context)->server != server) agc_fail(vm, "RUNTIME-TLS-CONTEXT-ROLE", message, at);
}

void agc_tls_http1_check(agc_vm *vm, const agc_tls_config *config, uint32_t at) {
  if (config && !agc_tls_config_http1(config))
    agc_fail(vm, "RUNTIME-TLS-CONTEXT-ALPN",
             "std/http speaks only HTTP/1.1, so the alpn of its TlsContext must be [] or [\"http/1.1\"]", at);
}

agc_tls_config *agc_tls_context_take(agc_vm *vm, agc_value context, bool server, const char *message, uint32_t at) {
  agc_tls_context_check(vm, context, server, message, at);
  return agc_tls_config_ref(agc_as_tls_context(vm, context)->config);
}

const agc_builtin agc_tls_context_builtins[] = {
  {"TLS.client_context", 1, builtin_client_context, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"TLS.server_context", 1, builtin_server_context, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
};

const size_t agc_tls_context_builtin_count = sizeof agc_tls_context_builtins / sizeof agc_tls_context_builtins[0];
