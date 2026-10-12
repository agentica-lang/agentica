#include "http_parse.h"
#include "net.h"

#ifdef __linux__
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

#define MAX_BODY ((int64_t)64 * 1024 * 1024)
#define MAX_CONNECTIONS 65536
#define MAX_HOST 253
#define PORT_TEXT 8
#define CLIENT(ptr, field) ((client *)(void *)((char *)(ptr) - offsetof(client, field)))

typedef struct client client;
typedef struct origin origin;
typedef struct idle idle;
typedef struct exchange exchange;

typedef enum { X_CONFIG, X_WAIT, X_CONNECT, X_EXCHANGE, X_DONE } phase;

typedef enum { F_NONE, F_CONN, F_CONFIG, F_CLOSED, F_PROTOCOL, F_READ, F_WRITE, F_EOF } failure;

typedef struct {
  size_t name, value;
} field_size;

typedef struct {
  uint8_t *data;
  size_t len, cap;
} bytes;

struct idle {
  agc_conn *conn;
  origin *o;
  uint64_t since;
  idle *next;
};

struct origin {
  client *c;
  char *host;
  int64_t port;
  bool secure;
  size_t open, users;
  idle *idle;
  exchange *waiters, *waiters_tail;
  origin *next;
};

struct exchange {
  client *c;
  origin *o;
  agc_io_job *job;
  uint64_t id, units;
  phase at;
  failure failed;
  agc_http_error error;
  int sys;
  agc_conn *conn, *broken;
  exchange *next, *run_next, *active_next;
  uint8_t *request;
  size_t request_len, seen, fields;
  int interim, status;
  bool head_only, keep, sent, write_failed, queued, in_body, detached, written, reused, retried, idempotent;
  agc_http_body body;
  uint8_t *field_data;
  field_size *field_sizes;
};

struct client {
  agc_trace trace;
  uv_loop_t *loop;
  uv_timer_t timer;
  uv_work_t setup;
  int64_t timeout_ms, idle_ms, max_body;
  size_t max_connections, users, callbacks;
  char *ca_file;
  agc_tls_config *config;
  agc_tls_failure failure;
  bool closed, loading, loaded, timer_ready, draining;
  agc_conn_watch on_exchange, on_idle;
  uv_timer_cb on_timer;
  exchange *config_waiters, *runnable, *runnable_tail, *active;
  origin *origins;
};

static const char client_closed[] = "http: client is closed";
static const char *const header_fields[] = {"name", "value"};
static const char *const response_fields[] = {"status", "headers", "body"};
static const char *const managed_headers[] = {"host", "content-length", "transfer-encoding", "connection"};

static void put(bytes *b, const void *data, size_t n) {
  if (!n) return;
  if (b->cap - b->len < n) {
    size_t cap = b->cap ? b->cap : 256;
    while (cap - b->len < n) cap = agc_size_mul(cap, 2);
    uint8_t *bigger = realloc(b->data, cap);
    if (!bigger) agc_out_of_memory();
    b->data = bigger;
    b->cap = cap;
  }
  memcpy(b->data + b->len, data, n);
  b->len += n;
}

static void put_text(bytes *b, const char *text) { put(b, text, strlen(text)); }

static void settle_client(client *c) {
  if (c->users || c->callbacks) return;
  for (origin *o = c->origins, *next; o; o = next) {
    next = o->next;
    free(o->host);
    free(o);
  }
  agc_tls_config_free(c->config);
  free(c->ca_file);
  free(c);
}

static void prune(client *c) {
  for (origin **at = &c->origins; *at;) {
    origin *o = *at;
    if (o->users || o->open || o->idle || o->waiters) {
      at = &o->next;
      continue;
    }
    *at = o->next;
    free(o->host);
    free(o);
  }
}

static void schedule(exchange *x) {
  if (x->queued || x->at == X_DONE || x->detached) return;
  client *c = x->c;
  x->queued = true;
  x->run_next = NULL;
  if (c->runnable_tail)
    c->runnable_tail->run_next = x;
  else
    c->runnable = x;
  c->runnable_tail = x;
}

static void unqueue(exchange *x) {
  client *c = x->c;
  exchange *previous = NULL;
  for (exchange *k = c->runnable; k; previous = k, k = k->run_next) {
    if (k != x) continue;
    if (previous)
      previous->run_next = k->run_next;
    else
      c->runnable = k->run_next;
    if (c->runnable_tail == k) c->runnable_tail = previous;
    break;
  }
  x->queued = false;
}

static void unlink_from(exchange **head, exchange **tail, const exchange *x) {
  exchange *previous = NULL;
  for (exchange *k = *head; k; previous = k, k = k->next) {
    if (k != x) continue;
    if (previous)
      previous->next = k->next;
    else
      *head = k->next;
    if (tail && *tail == k) *tail = previous;
    return;
  }
}

static void close_conn(agc_conn *conn, const char *why) {
  agc_conn_shut(conn, why);
  agc_conn_release(conn);
}

static void lease(exchange *x, agc_conn *conn) {
  agc_conn_hold(conn, true);
  x->reused = true;
  x->conn = conn;
  x->at = X_EXCHANGE;
  agc_conn_observe(conn, x->c->on_exchange, x);
  schedule(x);
}

static void connect_to(exchange *x) {
  origin *o = x->o;
  client *c = x->c;
  o->open++;
  x->at = X_CONNECT;
  x->conn = agc_conn_open(&c->trace, c->loop, x->id, o->host, o->port, o->secure ? c->config : NULL, c->on_exchange, x);
  schedule(x);
}

static void drop_idle(idle *node, const char *why) {
  origin *o = node->o;
  idle *previous = NULL;
  for (idle *k = o->idle; k; previous = k, k = k->next) {
    if (k != node) continue;
    if (previous)
      previous->next = k->next;
    else
      o->idle = k->next;
    break;
  }
  close_conn(node->conn, why);
  o->open--;
  free(node);
}

static void expire(origin *o, uint64_t now) {
  int64_t limit = o->c->idle_ms;
  for (idle *k = o->idle, *next; k; k = next) {
    next = k->next;
    if (now - k->since >= (uint64_t)limit) drop_idle(k, "idle");
  }
}

static void arm_timer(client *c) {
  if (c->closed) return;
  uint64_t oldest = UINT64_MAX;
  bool handover = false;
  for (const origin *o = c->origins; o; o = o->next) {
    if (o->waiters && o->idle) handover = true;
    for (const idle *k = o->idle; k; k = k->next)
      if (k->since < oldest) oldest = k->since;
  }
  if (oldest == UINT64_MAX) return;
  if (!c->timer_ready) {
    uv_timer_init(c->loop, &c->timer);
    c->timer_ready = true;
    c->callbacks++;
  }
  uint64_t now = uv_now(c->loop), due = oldest + (uint64_t)c->idle_ms;
  uv_timer_start(&c->timer, c->on_timer, handover ? 1 : due > now ? due - now : 0, 0);
  if (handover)
    uv_ref((uv_handle_t *)&c->timer);
  else
    uv_unref((uv_handle_t *)&c->timer);
}

static void grant(origin *o) {
  while (!o->c->closed && o->waiters && (o->idle || o->open < o->c->max_connections)) {
    exchange *x = o->waiters;
    if (x->retried && o->open >= o->c->max_connections) drop_idle(o->idle, "retry");
    o->waiters = x->next;
    if (!o->waiters) o->waiters_tail = NULL;
    x->next = NULL;
    if (o->idle && !x->retried) {
      idle *node = o->idle;
      o->idle = node->next;
      agc_conn *conn = node->conn;
      free(node);
      lease(x, conn);
    } else {
      connect_to(x);
    }
  }
}

static void park_idle(origin *o, agc_conn *conn) {
  client *c = o->c;
  agc_conn_hold(conn, false);
  idle *node = calloc(1, sizeof(idle));
  if (!node) agc_out_of_memory();
  node->conn = conn;
  node->o = o;
  node->since = uv_now(c->loop);
  node->next = o->idle;
  o->idle = node;
  agc_conn_observe(conn, c->on_idle, node);
  arm_timer(c);
}

static void free_slot(origin *o) {
  o->open--;
  grant(o);
}

static bool retry(exchange *x, failure why) {
  agc_conn *conn = x->conn;
  if (!conn || !x->reused || x->retried || !x->idempotent || x->c->closed) return false;
  if (why != F_EOF && why != F_READ && why != F_WRITE) return false;
  if (x->in_body || x->seen || x->interim || agc_inbuf_pending(agc_conn_input(conn))) return false;
  origin *o = x->o;
  close_conn(conn, "retry");
  o->open--;
  x->conn = NULL;
  x->retried = true;
  x->reused = x->sent = x->write_failed = x->written = false;
  x->sys = 0;
  x->at = X_WAIT;
  x->next = o->waiters;
  o->waiters = x;
  if (!o->waiters_tail) o->waiters_tail = x;
  grant(o);
  return true;
}

static void complete(exchange *x, failure why) {
  if (x->at == X_DONE) return;
  if (retry(x, why)) return;
  if (x->at == X_WAIT) unlink_from(&x->o->waiters, &x->o->waiters_tail, x);
  if (x->at == X_CONFIG) unlink_from(&x->c->config_waiters, NULL, x);
  x->failed = why;
  agc_conn *conn = x->conn;
  x->conn = NULL;
  if (conn && why == F_NONE && x->keep && !x->c->closed) {
    park_idle(x->o, conn);
  } else if (conn) {
    agc_conn_shut(conn, why == F_NONE ? "done" : "failed");
    if (why == F_CONN)
      x->broken = conn;
    else
      agc_conn_release(conn);
    free_slot(x->o);
  }
  x->at = X_DONE;
  agc_io_ready(x->job);
}

static void protocol_error(exchange *x, agc_http_error error) {
  x->error = error;
  complete(x, F_PROTOCOL);
}

static bool closes(const agc_http_head *head) {
  for (size_t k = 0; k < head->count; k++) {
    if (!agc_http_named(head->fields[k].name, "connection")) continue;
    agc_http_slice v = head->fields[k].value;
    size_t start = 0;
    for (size_t at = 0; at <= v.len; at++) {
      if (at < v.len && v.data[at] != ',') continue;
      if (agc_http_named(agc_http_trim((agc_http_slice){v.data + start, at - start}), "close")) return true;
      start = at + 1;
    }
  }
  return false;
}

static void keep_fields(exchange *x, const agc_http_head *head) {
  size_t total = 0;
  for (size_t k = 0; k < head->count; k++) total += head->fields[k].name.len + head->fields[k].value.len;
  x->fields = head->count;
  x->field_sizes = calloc(head->count ? head->count : 1, sizeof(field_size));
  x->field_data = malloc(total ? total : 1);
  if (!x->field_sizes || !x->field_data) agc_out_of_memory();
  size_t at = 0;
  for (size_t k = 0; k < head->count; k++) {
    const agc_http_field *f = &head->fields[k];
    for (size_t b = 0; b < f->name.len; b++) {
      uint8_t ch = f->name.data[b];
      x->field_data[at++] = ch >= 'A' && ch <= 'Z' ? (uint8_t)(ch + 32) : ch;
    }
    if (f->value.len) memcpy(x->field_data + at, f->value.data, f->value.len);
    at += f->value.len;
    x->field_sizes[k].name = f->name.len;
    x->field_sizes[k].value = f->value.len;
  }
}

static void consume(agc_inbuf *in, size_t n) {
  in->start += n;
  in->scanned = 0;
}

static bool head_step(exchange *x, agc_inbuf *in) {
  size_t pending = agc_inbuf_pending(in);
  if (pending == 0) return false;
  const uint8_t *data = in->data + in->start;
  if (pending <= AGC_HTTP_MAX_HEAD && !memchr(data + x->seen, '\n', pending - x->seen)) {
    x->seen = pending;
    return false;
  }
  agc_http_head head;
  size_t used;
  agc_http_error error;
  agc_http_status status = agc_http_parse_response_head(data, pending, &head, &used, &error);
  x->seen = pending;
  if (status == AGC_HTTP_INCOMPLETE) return false;
  if (status == AGC_HTTP_ERROR) {
    protocol_error(x, error);
    return false;
  }
  if (head.status < 200) {
    consume(in, used);
    x->seen = 0;
    if (++x->interim > AGC_HTTP_MAX_INTERIM) {
      protocol_error(x, AGC_HTTP_ERR_INTERIM);
      return false;
    }
    return true;
  }
  x->status = head.status;
  keep_fields(x, &head);
  if (closes(&head)) x->keep = false;
  if (x->head_only || head.status == 204 || head.status == 304) {
    bool announced = head.frame == AGC_HTTP_FRAME_CHUNKED || (head.frame == AGC_HTTP_FRAME_LENGTH && head.length > 0);
    if (announced && !x->head_only) x->keep = false;
    head.frame = AGC_HTTP_FRAME_LENGTH;
    head.length = 0;
  }
  if (head.frame == AGC_HTTP_FRAME_CLOSE) x->keep = false;
  agc_http_body_init(&x->body, head.frame, head.length, (uint64_t)x->c->max_body);
  consume(in, used);
  x->in_body = true;
  return true;
}

static void finish(exchange *x, const agc_inbuf *in) {
  if (!x->sent || x->write_failed || agc_inbuf_pending(in) || in->eof || in->error) x->keep = false;
  complete(x, F_NONE);
}

static void pump(exchange *x) {
  agc_conn *conn = x->conn;
  agc_inbuf *in = agc_conn_input(conn);
  if (!x->sent && agc_conn_sent(conn)) x->sent = true;
  if (agc_conn_write_status(conn) < 0) {
    x->write_failed = true;
    x->sys = -agc_conn_write_status(conn);
  }
  while (!x->in_body && head_step(x, in)) {
  }
  if (x->at == X_DONE) return;
  if (x->in_body) {
    size_t used;
    size_t pending = agc_inbuf_pending(in);
    agc_http_status status = pending ? agc_http_body_feed(&x->body, in->data + in->start, pending, &used)
                                     : agc_http_body_feed(&x->body, NULL, 0, &used);
    consume(in, used);
    if (status == AGC_HTTP_ERROR) {
      protocol_error(x, x->body.error);
      return;
    }
    if (status == AGC_HTTP_OK) {
      finish(x, in);
      return;
    }
  }
  if (in->error) {
    if (!x->write_failed) x->sys = in->error;
    complete(x, x->write_failed ? F_WRITE : F_READ);
  } else if (in->eof && x->in_body) {
    if (x->body.frame == AGC_HTTP_FRAME_CLOSE && !agc_conn_clean_eof(conn))
      protocol_error(x, AGC_HTTP_ERR_TRUNCATED);
    else if (agc_http_body_end(&x->body) == AGC_HTTP_OK)
      finish(x, in);
    else
      protocol_error(x, x->body.error);
  } else if (in->eof) {
    complete(x, x->write_failed ? F_WRITE : F_EOF);
  }
}

static void enqueue(origin *o, exchange *x) {
  x->next = NULL;
  if (o->waiters_tail)
    o->waiters_tail->next = x;
  else
    o->waiters = x;
  o->waiters_tail = x;
}

static void send_request(exchange *x) {
  agc_conn_read(x->conn);
  if (agc_conn_send(x->conn, x->request, x->request_len) < 0) {
    x->write_failed = true;
    x->sys = -agc_conn_write_status(x->conn);
  }
  x->written = true;
}

static void step(exchange *x) {
  client *c = x->c;
  switch (x->at) {
    case X_CONFIG:
      if (x->o->secure && !c->loaded) return;
      if (x->o->secure && !c->config) {
        complete(x, F_CONFIG);
        return;
      }
      unlink_from(&c->config_waiters, NULL, x);
      x->at = X_WAIT;
      uv_update_time(c->loop);
      expire(x->o, uv_now(c->loop));
      enqueue(x->o, x);
      grant(x->o);
      return;
    case X_CONNECT:
      if (agc_conn_failed(x->conn)) {
        complete(x, F_CONN);
        return;
      }
      if (!agc_conn_ready(x->conn)) return;
      x->at = X_EXCHANGE;
      send_request(x);
      pump(x);
      return;
    case X_EXCHANGE:
      if (!x->written) send_request(x);
      pump(x);
      return;
    default:
      return;
  }
}

static void drain(client *c) {
  if (c->draining) return;
  c->draining = true;
  while (c->runnable) {
    exchange *x = c->runnable;
    c->runnable = x->run_next;
    if (!c->runnable) c->runnable_tail = NULL;
    x->queued = false;
    step(x);
  }
  c->draining = false;
}

static void watch_exchange(void *watcher) {
  exchange *x = watcher;
  client *c = x->c;
  schedule(x);
  drain(c);
}

static void watch_idle(void *watcher) {
  idle *node = watcher;
  agc_inbuf *in = agc_conn_input(node->conn);
  if (!agc_inbuf_pending(in) && !in->eof && !in->error && !agc_conn_failed(node->conn)) return;
  origin *o = node->o;
  client *c = o->c;
  drop_idle(node, "idle");
  grant(o);
  drain(c);
  prune(c);
}

static void timer_fired(uv_timer_t *timer) {
  client *c = CLIENT(timer, timer);
  uint64_t now = uv_now(c->loop);
  for (origin *o = c->origins; o; o = o->next) {
    expire(o, now);
    grant(o);
  }
  drain(c);
  prune(c);
  arm_timer(c);
}

static void timer_closed(uv_handle_t *handle) {
  client *c = CLIENT(handle, timer);
  c->callbacks--;
  settle_client(c);
}

static void setup_work(uv_work_t *w) {
  client *c = CLIENT(w, setup);
  c->config = agc_tls_client_config(c->ca_file, &c->failure);
}

static void setup_done(uv_work_t *w, int status) {
  client *c = CLIENT(w, setup);
  c->loading = false;
  c->loaded = true;
  c->callbacks--;
  if (!c->config && status < 0) {
    c->failure.code = AGC_TLS_ERR_INTERNAL;
    c->failure.sys = -status;
  }
  for (exchange *x = c->config_waiters; x; x = x->next) schedule(x);
  drain(c);
  settle_client(c);
}

static void wait_config(client *c, exchange *x) {
  x->next = c->config_waiters;
  c->config_waiters = x;
  if (c->loading) return;
  sigset_t saved;
  agc_io_block_stop(&saved);
  int rc = uv_queue_work(c->loop, &c->setup, setup_work, setup_done);
  pthread_sigmask(SIG_SETMASK, &saved, NULL);
  if (rc) {
    c->loaded = true;
    c->failure.code = AGC_TLS_ERR_INTERNAL;
    c->failure.sys = -rc;
    schedule(x);
    return;
  }
  c->loading = true;
  c->callbacks++;
}

static void shut_client(client *c) {
  if (c->closed) return;
  c->closed = true;
  for (exchange *x = c->active; x; x = x->active_next) complete(x, F_CLOSED);
  for (origin *o = c->origins; o; o = o->next)
    while (o->idle) drop_idle(o->idle, "close");
  if (c->loading) uv_cancel((uv_req_t *)&c->setup);
  if (c->timer_ready) {
    c->timer_ready = false;
    uv_close((uv_handle_t *)&c->timer, timer_closed);
  }
}

static void release_client(void *native) {
  client *c = native;
  shut_client(c);
  c->users--;
  settle_client(c);
}

static void detach(exchange *x) {
  if (x->detached) return;
  client *c = x->c;
  unqueue(x);
  if (x->at == X_WAIT) unlink_from(&x->o->waiters, &x->o->waiters_tail, x);
  if (x->at == X_CONFIG) unlink_from(&c->config_waiters, NULL, x);
  exchange *previous = NULL;
  for (exchange *k = c->active; k; previous = k, k = k->active_next) {
    if (k != x) continue;
    if (previous)
      previous->active_next = k->active_next;
    else
      c->active = k->active_next;
    break;
  }
  if (x->conn) {
    close_conn(x->conn, "timeout");
    x->conn = NULL;
    free_slot(x->o);
  }
  if (x->broken) agc_conn_release(x->broken);
  x->broken = NULL;
  x->at = X_DONE;
  x->detached = true;
  drain(c);
}

static void free_exchange(exchange *x) {
  client *c = x->c;
  detach(x);
  x->o->users--;
  prune(c);
  agc_http_body_free(&x->body);
  free(x->request);
  free(x->field_data);
  free(x->field_sizes);
  free(x);
  c->users--;
  settle_client(c);
}

static agc_string *latin1(const uint8_t *data, size_t len) {
  size_t extra = 0;
  for (size_t k = 0; k < len; k++) extra += data[k] >= 0x80;
  agc_string *s = agc_new_string(agc_size_add(len, extra), len);
  size_t at = 0;
  for (size_t k = 0; k < len; k++) {
    if (data[k] < 0x80) {
      s->data[at++] = (char)data[k];
    } else {
      s->data[at++] = (char)(0xC0 | (data[k] >> 6));
      s->data[at++] = (char)(0x80 | (data[k] & 0x3F));
    }
  }
  return s;
}

static agc_value response_value(agc_vm *vm, const exchange *x) {
  const uint8_t *data = x->body.data ? x->body.data : (const uint8_t *)"";
  size_t chars;
  if (!agc_utf8_chars(data, x->body.len, &chars)) return agc_error_value("http: response body is not valid UTF-8");
  uint32_t header_type = agc_builtin_struct(vm, "Header", header_fields, 2);
  uint32_t response_type = agc_builtin_struct(vm, "HttpResponse", response_fields, 3);
  agc_list *headers = agc_new_list(x->fields);
  size_t at = 0;
  for (size_t k = 0; k < x->fields; k++) {
    agc_struct *h = agc_new_struct(header_type, 2);
    size_t name = x->field_sizes[k].name, value = x->field_sizes[k].value;
    h->fields[0] = agc_string_value(agc_make_string((const char *)x->field_data + at, name, name));
    h->fields[1] = agc_string_value(latin1(x->field_data + at + name, value));
    at += name + value;
    headers->items[k] = agc_struct_value(h);
  }
  agc_struct *r = agc_new_struct(response_type, 3);
  r->fields[0] = agc_int(x->status);
  r->fields[1] = agc_list_value(headers);
  r->fields[2] = agc_string_value(agc_make_string((const char *)data, x->body.len, chars));
  return agc_result_value(true, agc_struct_value(r));
}

static agc_value failure_value(agc_vm *vm, const exchange *x) {
  size_t size;
  char *text;
  switch (x->failed) {
    case F_CONN: return agc_conn_error(vm, x->broken);
    case F_CONFIG: return agc_tls_load_error(vm, "ssl-load-verify-source!", x->c->ca_file, &x->c->failure);
    case F_CLOSED: return agc_error_value(client_closed);
    case F_READ: return agc_system_error(vm, "error reading from stream port", x->sys);
    case F_WRITE: return agc_system_error(vm, "error writing to stream port", x->sys);
    case F_EOF: return agc_error_value("http: connection closed before the response was complete");
    default:
      size = strlen(agc_http_error_text(x->error)) + 8;
      text = agc_alloc_atomic(size);
      snprintf(text, size, "http: %s", agc_http_error_text(x->error));
      return agc_error_value(text);
  }
}

static agc_value exchange_done(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  exchange *x = data;
  agc_value result = x->failed == F_NONE ? response_value(vm, x) : failure_value(vm, x);
  uint64_t cost = x->units + x->body.len / AGC_COST_BYTES + x->fields;
  free_exchange(x);
  agc_charge(vm, cost);
  return result;
}

static agc_value exchange_expired(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)context;
  detach(data);
  return agc_stream_timed_out();
}

static void exchange_drop(void *data) { free_exchange(data); }

static const agc_io_kind http_io = {NULL, exchange_done, exchange_expired, exchange_drop, true, "http"};

static bool host_text(const agc_string *host) {
  if (host->bytes == 0 || host->bytes > MAX_HOST) return false;
  for (size_t k = 0; k < host->bytes; k++) {
    char ch = host->data[k];
    bool alnum = (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
    if (!alnum && !strchr("-._~:", ch)) return false;
  }
  return true;
}

static bool text_is(const agc_string *s, const char *text) {
  return s->bytes == strlen(text) && memcmp(s->data, text, s->bytes) == 0;
}

static const char *put_value(bytes *b, const agc_string *value) {
  for (size_t at = 0; at < value->bytes;) {
    uint32_t cp = agc_utf8_next((const uint8_t *)value->data, value->bytes, &at);
    if (cp > 255 || !agc_http_value_byte((uint8_t)cp)) return "http: header values must be Latin-1 text without control characters";
    uint8_t ch = (uint8_t)cp;
    put(b, &ch, 1);
  }
  return NULL;
}

static const char *put_headers(agc_vm *vm, bytes *b, const agc_list *headers, size_t *count) {
  size_t block = b->len;
  for (size_t k = 0; k < headers->len; k++) {
    const agc_struct *h = agc_as_struct(vm, headers->items[k]);
    if (h->n != 2) return "http: invalid header";
    const agc_string *name = agc_as_string(vm, h->fields[0]);
    const agc_string *value = agc_as_string(vm, h->fields[1]);
    if (!agc_http_token((const uint8_t *)name->data, name->bytes)) return "http: header names must be HTTP tokens";
    agc_http_slice slice = {(const uint8_t *)name->data, name->bytes};
    for (size_t m = 0; m < sizeof managed_headers / sizeof managed_headers[0]; m++)
      if (agc_http_named(slice, managed_headers[m])) return "http: Host, Content-Length, Transfer-Encoding and Connection are set by the client";
    size_t start = b->len;
    put(b, name->data, name->bytes);
    put_text(b, ": ");
    const char *bad = put_value(b, value);
    if (bad) return bad;
    put_text(b, "\r\n");
    if (b->len - start > AGC_HTTP_MAX_LINE + 2) return "http: a header line is too large";
    if (++*count > AGC_HTTP_MAX_HEADERS) return "http: too many headers";
  }
  if (b->len - block > AGC_HTTP_MAX_BLOCK) return "http: headers are too large";
  return NULL;
}

static const char *build_request(agc_vm *vm, bytes *b, const agc_value *args, bool secure) {
  const agc_string *host = agc_as_string(vm, args[2]);
  int64_t port = agc_as_int(vm, args[3]);
  const agc_string *method = agc_as_string(vm, args[4]);
  const agc_string *target = agc_as_string(vm, args[5]);
  const agc_string *body = agc_as_string(vm, args[7]);
  if (!agc_http_token((const uint8_t *)method->data, method->bytes) || text_is(method, "CONNECT"))
    return "http: invalid method";
  if (target->bytes == 0) return "http: invalid request target";
  for (size_t k = 0; k < target->bytes; k++)
    if ((uint8_t)target->data[k] < 33 || (uint8_t)target->data[k] > 126) return "http: invalid request target";
  put(b, method->data, method->bytes);
  put_text(b, " ");
  put(b, target->data, target->bytes);
  put_text(b, " HTTP/1.1\r\nHost: ");
  bool literal = memchr(host->data, ':', host->bytes) != NULL;
  if (literal) put_text(b, "[");
  put(b, host->data, host->bytes);
  if (literal) put_text(b, "]");
  char number[64];
  if (port != (secure ? 443 : 80)) {
    snprintf(number, sizeof number, ":%" PRId64, port);
    put_text(b, number);
  }
  put_text(b, "\r\n");
  size_t count = 1;
  bool post = text_is(method, "POST") || text_is(method, "PUT") || text_is(method, "PATCH");
  if (body->bytes || post) {
    snprintf(number, sizeof number, "Content-Length: %zu\r\n", body->bytes);
    put_text(b, number);
    count++;
  }
  const char *bad = put_headers(vm, b, agc_as_list(vm, args[6]), &count);
  if (bad) return bad;
  put_text(b, "\r\n");
  put(b, body->data, body->bytes);
  return NULL;
}

static origin *origin_of(client *c, const agc_string *host, int64_t port, bool secure) {
  for (origin *o = c->origins; o; o = o->next)
    if (o->port == port && o->secure == secure && strlen(o->host) == host->bytes &&
        memcmp(o->host, host->data, host->bytes) == 0)
      return o;
  origin *o = calloc(1, sizeof(origin));
  char *name = agc_cstr(host);
  if (!o || !name) agc_out_of_memory();
  o->c = c;
  o->host = name;
  o->port = port;
  o->secure = secure;
  o->next = c->origins;
  c->origins = o;
  return o;
}

static agc_value check_target(agc_vm *vm, const agc_value *args, bool *secure) {
  const agc_string *scheme = agc_as_string(vm, args[1]);
  if (!text_is(scheme, "http") && !text_is(scheme, "https")) return agc_error_value("http: the scheme must be http or https");
  *secure = text_is(scheme, "https");
  if (!host_text(agc_as_string(vm, args[2]))) return agc_error_value("http: invalid host");
  int64_t port = agc_as_int(vm, args[3]);
  if (port < 1 || port > 65535) return agc_error_value("http: port must be 1..65535");
  return agc_void();
}

static agc_value builtin_exchange(agc_vm *vm, agc_value *args, uint32_t span) {
  if (vm->rt->no_files) agc_fail(vm, "RUNTIME-INTERNAL", "network access is off in this run", span);
  client *c = agc_as_http_client(vm, args[0])->state->native;
  if (!c || c->closed) return agc_error_value(client_closed);
  bool secure = false;
  agc_value bad = check_target(vm, args, &secure);
  if (!agc_is(bad, AGC_T_VOID)) return bad;
  if ((int64_t)agc_as_string(vm, args[7])->bytes > c->max_body)
    return agc_error_value("http: request body exceeds max_body_bytes");
  bytes request = {0};
  const char *problem = build_request(vm, &request, args, secure);
  if (problem) {
    free(request.data);
    return agc_error_value(problem);
  }
  exchange *x = calloc(1, sizeof(exchange));
  if (!x) agc_out_of_memory();
  x->c = c;
  x->id = agc_resource_id(vm);
  x->units = agc_value_units(args[6]) + request.len / AGC_COST_BYTES;
  x->request = request.data;
  x->request_len = request.len;
  const agc_string *method = agc_as_string(vm, args[4]);
  x->head_only = text_is(method, "HEAD");
  x->idempotent = x->head_only || text_is(method, "GET") || text_is(method, "OPTIONS") || text_is(method, "PUT") ||
                  text_is(method, "DELETE");
  x->keep = true;
  x->o = origin_of(c, agc_as_string(vm, args[2]), agc_as_int(vm, args[3]), secure);
  x->o->users++;
  x->active_next = c->active;
  c->active = x;
  c->users++;
  AGC_TRACE(&c->trace, AGC_TRACE_IO, "http_exchange job=%" PRIu64 " host=%s port=%" PRId64, x->id, x->o->host,
            x->o->port);
  x->job = agc_io_start(vm, &http_io, x, args[0], c->timeout_ms);
  x->at = X_CONFIG;
  if (secure && !c->loaded)
    wait_config(c, x);
  else
    schedule(x);
  drain(c);
  return agc_void();
}

static agc_value builtin_client(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  int64_t timeout = agc_as_int(vm, args[0]), idle_ms = agc_as_int(vm, args[1]);
  int64_t connections = agc_as_int(vm, args[2]), max_body = agc_as_int(vm, args[3]);
  if (timeout <= 0 || idle_ms <= 0 || connections <= 0 || max_body <= 0)
    return agc_error_value("http: options must be positive");
  if (connections > MAX_CONNECTIONS) return agc_error_value("http: max_connections must be at most 65536");
  if (max_body > MAX_BODY) return agc_error_value("http: max_body_bytes must be at most 67108864");
  char *ca_file = agc_cstr(agc_as_string(vm, args[4]));
  if (!ca_file) return agc_error_value("http: ca_file cannot contain NUL");
  client *c = calloc(1, sizeof(client));
  if (!c) agc_out_of_memory();
  c->trace = vm->rt->trace;
  c->loop = agc_io_uv(vm);
  c->timeout_ms = timeout;
  c->idle_ms = idle_ms;
  c->max_connections = (size_t)connections;
  c->max_body = max_body;
  c->ca_file = ca_file;
  c->users = 1;
  c->on_exchange = watch_exchange;
  c->on_idle = watch_idle;
  c->on_timer = timer_fired;
  agc_http_client *hc = agc_alloc(sizeof(agc_http_client));
  hc->state = agc_register(vm, c, release_client);
  return agc_result_value(true, agc_http_client_value(hc));
}

static agc_value builtin_close_client(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_resource *r = agc_as_http_client(vm, args[0])->state;
  client *c = r->native;
  if (!c) return agc_void();
  r->native = NULL;
  agc_unregister(vm, r);
  release_client(c);
  return agc_void();
}

const agc_builtin agc_http_builtins[] = {
  {"HttpWire.client", 5, builtin_client, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"HttpWire.exchange", 8, builtin_exchange, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"HttpWire.close_client", 1, builtin_close_client, AGC_NATIVE_NONE, AGC_COST_NONE},
};

const size_t agc_http_builtin_count = sizeof agc_http_builtins / sizeof agc_http_builtins[0];
#else
const agc_builtin agc_http_builtins[] = {{"", 0, NULL, AGC_NATIVE_NONE, AGC_COST_NONE}};

const size_t agc_http_builtin_count = 0;
#endif
