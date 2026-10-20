/*
 * The TCP and TLS builtins (Linux, macOS and Windows): sockets and listeners
 * over libuv, with the TLS handshake and close_notify through tls.h and the
 * host's error numbers through net_os.h. Every `net` belongs to the I/O
 * thread; a builtin reaches it through a step posted there, and a done half
 * reads only what that thread copied into the request. Service layer.
 * Design: docs/vm/10-io-tls.md §10.3 and §10.3.1, docs/vm/16-architecture.md §16.9.
 */
#include "http_fields.h"
#include "net.h"
#include "net_os.h"

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

#define LIMIT ((size_t)1048576)
#define BACKLOG 128
#define BIND_TRIES 8
#define PORT_TEXT 8
#define CIPHER_SIZE ((size_t)16384)
#define TLS_CHUNK ((size_t)16384)
#define NET(ptr, field) ((net *)(void *)((char *)(ptr) - offsetof(net, field)))
#define TCP_LINK(ptr, field) ((tcp_link *)(void *)((char *)(ptr) - offsetof(tcp_link, field)))

typedef enum { REQ_CONNECT, REQ_LISTEN, REQ_ACCEPT, REQ_LINE, REQ_BYTES, REQ_TEXT, REQ_HEAD, REQ_RESPONSE, REQ_SEND } req_kind;

typedef agc_conn net;
typedef struct tcp_link tcp_link;
typedef struct request request;

struct tcp_link {
  uv_tcp_t tcp;
  uv_connect_t connect;
  net *owner;
  tcp_link *next;
  /* Connections libuv has reported and uv_accept has not taken. libuv calls the connection callback once per
     connection: on Unix it holds one accepted socket and waits for uv_accept before it reports another, but on
     Windows several AcceptEx requests may complete before the first uv_accept, so this is a count, not a flag. */
  size_t backlog;
};

/* A request is the data of a job. The builtin fills its arguments; its START step (begin_*, on the I/O thread) takes
   a count on the net and links it in its slot; `finish` copies the result into it (the fields after `stopped`),
   unlinks it and readies the job, and from then on the I/O thread does not touch it until `drop_request` frees it. */
struct request {
  req_kind kind;
  net *n, *child;
  agc_io_job *job;
  request *next;
  size_t count;
  uint8_t *data;
  size_t len;
  int error, accept_rc;
  bool sends, counted, finished, stopped;
  bool closed, opened, resolved, tls_failed;
  int64_t port;
  int write_status, open_error;
  agc_inbuf_cut cut;
  /* HttpWire.read_text: the carry before the bytes. HttpWire.read_head: the
     body limit, the rest to put back first (a malloc'd copy, or NULL), and
     where the look for an LF stopped. HttpWire.read_response: the body limit,
     where the look stopped, and whether the request was HEAD. Their cut goes
     in `cut` (the carry first), with `bytes`, `buffered` and `ended` (the input
     had already ended or failed at the cut). */
  uint8_t carry[3], kept;
  bool head_only, ended;
  uint64_t limit;
  uint8_t *rest;
  size_t rest_len, scanned, bytes, buffered;
};

typedef struct tls_shared tls_shared;

/* A socket or a listener. Every field belongs to the I/O thread (the builtins post steps to it), with two exceptions:
   `closed` is atomic, so a builtin can refuse a closed socket at once (a stale false only means its step finds it
   closed), and `id` is atomic, since the scheduler that adopts an accepted socket names it while the I/O thread may
   be tracing it. The error fields (`error`, `resolved`, `failure`, `tls_failed`) are not written after the failure
   that a finished request reported, so its done half may read them. */
struct agc_conn {
  agc_trace trace;
  agc_loop *io;
  uv_loop_t *loop;
  uv_getaddrinfo_t dns;
  uv_write_t write_req;
  uv_shutdown_t shutdown;
  tcp_link *conn;
  struct addrinfo *addrs, *next_addr;
  char *host;
  int64_t port;
  _Atomic uint64_t id;
  uint64_t parent;
  size_t users, callbacks;
  bool listener, resolving, resolved, connected, reading;
  _Atomic bool closed;
  int error, write_status;
  uint8_t *write_data;
  agc_inbuf in;
  request *opener, *reader, *writer, *accepts, *accepts_tail, *handshakes;
  uv_work_t setup;
  char *ca_file, *cert_file, *key_file;
  agc_tls_config *config;
  /* An HttpClient's context (HttpWire.connect_tls), instead of `config`: the net holds one count on it, and waits in
     its list (next_waiter) while it is built. */
  tls_shared *shared;
  net *next_waiter;
  agc_tls *tls;
  agc_tls_failure failure;
  uint8_t *cipher, *plain;
  size_t plain_at, plain_len;
  bool secure, setting_up, handshaken, tls_failed, flushing, raw_eof, clean_eof, half_closed;
  agc_conn_watch watch;
  void *watcher;
};

/* A posted close: release_step runs it on the I/O thread. */
typedef struct {
  net *n;
  const char *why;
} release_call;

static const char socket_closed[] = "network: socket is closed";
static const char listener_closed[] = "network: listener is closed";
static const char write_failed[] = "error writing to stream port";

/* The TLS client context of an HttpClient (#394): built once, on a pool thread, when the first https connection of the
   client needs it, then used by every later connection, so the CA file is read once per client. Counts (`refs`): the
   client's (HttpWire.drop_tls gives it back), one per net that names it, and one for a build in progress; the last
   one frees it, on whatever thread gives it back. An SSL takes its own count on the SSL_CTX (SSL_new), so a session
   never outlives its context. `ca_file` is fixed at creation. The rest belongs to the I/O thread; the pool job writes
   only `built` and `failure`, which libuv hands back to that thread in shared_done. A failed build is not kept: the
   next connection tries again. A queued build is never cancelled, even when every waiter leaves or the client dropped
   its count: it holds its own count, runs to its end and shared_done gives back the last count. Until then it keeps
   the loop alive at the end of the run, for as long as reading the CA file takes, as TLS.connect's own setup does. */
struct tls_shared {
  _Atomic size_t refs;
  char *ca_file;
  agc_tls_config *config, *built;
  agc_tls_failure failure;
  net *waiters, *waiters_tail;
  bool building;
  uv_work_t work;
};

static void shared_unref(tls_shared *s) {
  if (atomic_fetch_sub_explicit(&s->refs, 1, memory_order_acq_rel) != 1) return;
  agc_tls_config_free(s->config);
  free(s->ca_file);
  free(s);
}

static agc_value ok_value(agc_value v) { return agc_result_value(true, v); }

static void settle(net *n) {
  if (n->users || n->callbacks) return;
  uv_freeaddrinfo(n->addrs);
  agc_inbuf_free(&n->in);
  agc_tls_free(n->tls);
  agc_tls_config_free(n->config);
  if (n->shared) shared_unref(n->shared);
  free(n->cipher);
  free(n->plain);
  free(n->ca_file);
  free(n->cert_file);
  free(n->key_file);
  free(n->write_data);
  free(n->host);
  free(n);
}

static void link_closed(uv_handle_t *h) {
  tcp_link *k = TCP_LINK(h, tcp);
  net *n = k->owner;
  free(k);
  n->callbacks--;
  settle(n);
}

static void drop_link(tcp_link *k) {
  if (!uv_is_closing((uv_handle_t *)&k->tcp)) uv_close((uv_handle_t *)&k->tcp, link_closed);
}

static tcp_link *new_link(net *n) {
  tcp_link *k = calloc(1, sizeof(tcp_link));
  if (!k) agc_out_of_memory();
  k->owner = n;
  uv_tcp_init(n->loop, &k->tcp);
  n->callbacks++;
  return k;
}

static void remove_request(request **head, request **tail, const request *q) {
  request *previous = NULL;
  for (request *k = *head; k; previous = k, k = k->next) {
    if (k != q) continue;
    if (previous)
      previous->next = k->next;
    else
      *head = k->next;
    if (tail && *tail == k) *tail = previous;
    return;
  }
}

static bool reads(req_kind kind) {
  return kind == REQ_LINE || kind == REQ_BYTES || kind == REQ_TEXT || kind == REQ_HEAD || kind == REQ_RESPONSE;
}

static bool heads(req_kind kind) { return kind == REQ_HEAD || kind == REQ_RESPONSE; }

/* The status of the request head (or response head) at the start of the
   input; *used is its length when it is whole. */
static agc_http_status head_status(const agc_inbuf *in, size_t len, req_kind kind, size_t *used) {
  agc_http_head head;
  agc_http_error error;
  const uint8_t *data = in->data + in->start;
  return kind == REQ_RESPONSE ? agc_http_parse_response_head(data, len, &head, used, &error)
                              : agc_http_parse_request_head(data, len, &head, used, &error);
}

/* HttpWire.read_head and read_response wait for a whole head or a parse error, more bytes than
   a head may hold, or the end of input. The head is parsed only when an LF
   came in past q->scanned, so a head that arrives a byte at a time is parsed
   once per line, and it stays in the input until it is whole. */
static bool head_ready(const agc_inbuf *in, request *q) {
  if (in->eof || in->error) return true;
  size_t have = agc_inbuf_pending(in), used;
  if (have > AGC_HTTP_MAX_HEAD) return true;
  if (q->scanned >= have) return false;
  bool lf = memchr(in->data + in->start + q->scanned, '\n', have - q->scanned) != NULL;
  q->scanned = have;
  return lf && head_status(in, have, q->kind, &used) != AGC_HTTP_INCOMPLETE;
}

/* I/O thread only (or the N = 1 scheduler, which is that thread). */
static bool read_ready(net *n, request *q) {
  if (n->closed) return true;
  if (heads(q->kind)) return head_ready(&n->in, q);
  if (q->kind == REQ_TEXT && q->count == 0) return true;
  return agc_inbuf_ready(&n->in, q->kind == REQ_LINE, 1);
}

/* Whether the end of input or a read error has come (TLS: the TCP FIN, even before close_notify is decided). std/http
   does not keep such a connection. I/O thread only. */
static bool input_ended(const net *n) { return n->in.eof || n->in.error || n->raw_eof; }

/* The cut of HttpWire.read_text: the carry, then up to q->count read bytes,
   and the count of bytes left in the input. I/O thread only. */
static void cut_text(net *n, request *q) {
  size_t have = agc_inbuf_pending(&n->in);
  q->bytes = have < q->count ? have : q->count;
  q->cut.error = n->in.error;
  q->cut.status = AGC_CUT_DATA;
  q->cut.len = q->kept + q->bytes;
  q->cut.data = malloc(q->cut.len ? q->cut.len : 1);
  if (!q->cut.data) agc_out_of_memory();
  memcpy(q->cut.data, q->carry, q->kept);
  if (q->bytes) memcpy(q->cut.data + q->kept, n->in.data + n->in.start, q->bytes);
  agc_inbuf_take(&n->in, q->bytes);
  q->buffered = agc_inbuf_pending(&n->in);
  q->ended = input_ended(n);
}

/* The cut of HttpWire.read_head and read_response: the head's bytes when it is whole, else what
   is there up to one byte past the largest head (a parse error, a head too
   large, or a head the end of input cut short). I/O thread only. */
static void cut_head(net *n, request *q) {
  size_t have = agc_inbuf_pending(&n->in), used = 0;
  size_t window = have < AGC_HTTP_MAX_HEAD + 1 ? have : AGC_HTTP_MAX_HEAD + 1;
  q->cut.error = n->in.error;
  q->cut.status = AGC_CUT_DATA;
  q->cut.len = window && head_status(&n->in, window, q->kind, &used) == AGC_HTTP_OK ? used : window;
  q->cut.data = malloc(q->cut.len ? q->cut.len : 1);
  if (!q->cut.data) agc_out_of_memory();
  if (q->cut.len) memcpy(q->cut.data, n->in.data + n->in.start, q->cut.len);
  agc_inbuf_take(&n->in, q->cut.len);
  q->buffered = agc_inbuf_pending(&n->in);
  q->ended = input_ended(n);
}

/* The values of the two cuts, built on a scheduler from the request alone. std/http matches on "error reading from
   stream port" (a prefix) and "network: end of input" of both (READ_FAILED and END_OF_INPUT in stdlib/http.agc). */
static agc_value text_value(agc_vm *vm, const request *q) {
  if (q->bytes == 0 && q->count && q->cut.error)
    return agc_system_error(vm, "error reading from stream port", q->cut.error);
  return agc_result_value(true, agc_http_text_value(vm, q->cut.data, q->cut.len, q->bytes, q->buffered, q->ended));
}

static agc_value head_value(agc_vm *vm, const request *q) {
  if (q->cut.len && q->kind == REQ_RESPONSE)
    return agc_http_response_value(vm, q->cut.data, q->cut.len, q->head_only, q->limit, q->cut.error, q->buffered, q->ended);
  if (q->cut.len) return agc_http_head_value(vm, q->cut.data, q->cut.len, q->limit, q->buffered);
  if (q->cut.error) return agc_system_error(vm, "error reading from stream port", q->cut.error);
  return agc_error_value("network: end of input");
}

/* HttpWire.read_head's rest goes back in front of the input before the head
   is looked for. I/O thread only. */
static void put_back(net *n, request *q) {
  if (!agc_inbuf_unread(&n->in, q->rest, q->rest_len)) agc_out_of_memory();
  free(q->rest);
  q->rest = NULL;
  q->rest_len = 0;
}

static void unlink_request(request *q) {
  net *n = q->n;
  if (n->opener == q) n->opener = NULL;
  if (n->reader == q) n->reader = NULL;
  if (n->writer == q) n->writer = NULL;
  remove_request(&n->accepts, &n->accepts_tail, q);
  remove_request(&n->handshakes, NULL, q);
  if (q->child && q->child->opener == q) q->child->opener = NULL;
  q->next = NULL;
}

/* The request is over: its result goes into it (what the done half reads on a scheduler), it leaves its slot, and
   its job is readied. A read takes its line or bytes out of the input here, so the input buffer stays the I/O
   thread's. I/O thread only; once finished the request is the job's. */
static void finish(request *q) {
  if (!q || q->finished) return;
  net *n = q->n;
  const net *c = q->child;
  q->finished = true;
  unlink_request(q);
  q->closed = n->closed;
  switch (q->kind) {
    case REQ_CONNECT:
    case REQ_LISTEN:
      q->opened = n->conn && !n->closed && (n->listener || (n->connected && (!n->secure || n->handshaken)));
      q->port = n->port;
      q->resolved = n->resolved;
      q->open_error = n->error;
      q->tls_failed = n->tls_failed;
      break;
    case REQ_ACCEPT:
      if (c) {
        q->opened = !c->closed && (!c->secure || c->handshaken);
        q->tls_failed = c->tls_failed;
      }
      break;
    case REQ_LINE:
      if (!n->closed) agc_inbuf_cut_line(&n->in, &q->cut);
      break;
    case REQ_BYTES:
      if (!n->closed) agc_inbuf_cut_bytes(&n->in, q->count, &q->cut);
      break;
    case REQ_TEXT:
      if (!n->closed) cut_text(n, q);
      break;
    case REQ_HEAD:
    case REQ_RESPONSE:
      if (!n->closed) cut_head(n, q);
      break;
    case REQ_SEND:
      q->write_status = n->write_status;
      break;
  }
  agc_io_ready(q->job);
}

static void notify(const net *n, request *q) {
  finish(q);
  if (n->watch) n->watch(n->watcher);
}

static const char *kind_name(const net *n) { return n->listener ? "listener" : "socket"; }

static void drop_links(net *n) {
  for (tcp_link *k = n->conn, *next; k; k = next) {
    next = k->next;
    drop_link(k);
  }
  n->conn = NULL;
}

static void goodbye(net *n) {
  if (!n->tls || !n->handshaken || n->tls_failed || !n->connected || !n->conn || n->write_status < 0) return;
  agc_tls_close(n->tls);
  const uint8_t *data;
  size_t len = agc_tls_out_peek(n->tls, &data);
  if (len && len <= CIPHER_SIZE && !n->flushing) {
    uv_buf_t b = uv_buf_init((char *)data, (unsigned)len);
    (void)uv_try_write((uv_stream_t *)&n->conn->tcp, &b, 1);
  }
  agc_tls_out_consume(n->tls, len);
}

/* A net that waits for its client's context leaves the list at its close, so the build that others may still wait
   for is not cancelled. I/O thread only. */
static void shared_leave(net *n) {
  tls_shared *s = n->shared;
  net *prev = NULL;
  for (net *w = s->waiters; w; prev = w, w = w->next_waiter) {
    if (w != n) continue;
    if (prev)
      prev->next_waiter = n->next_waiter;
    else
      s->waiters = n->next_waiter;
    if (s->waiters_tail == n) s->waiters_tail = prev;
    break;
  }
  n->next_waiter = NULL;
  n->setting_up = false;
  n->callbacks--;
}

static void shut_one(net *n, const char *why) {
  if (n->closed) return;
  goodbye(n);
  n->closed = true;
  AGC_TRACE(&n->trace, AGC_TRACE_IO, "tcp_close %s=%" PRIu64 " why=%s", kind_name(n), n->id, why);
  if (n->tls) AGC_TRACE(&n->trace, AGC_TRACE_TLS, "tls_close %s=%" PRIu64 " why=%s", kind_name(n), n->id, why);
  if (n->resolving) uv_cancel((uv_req_t *)&n->dns);
  if (n->setting_up && n->shared)
    shared_leave(n);
  else if (n->setting_up)
    uv_cancel((uv_req_t *)&n->setup);
  drop_links(n);
  n->reading = false;
  agc_inbuf_free(&n->in);
  notify(n, n->opener);
  notify(n, n->reader);
  notify(n, n->writer);
  while (n->accepts) finish(n->accepts);
}

/* A listener's close also closes the connections still in their handshake; closing one finishes its accept, and one
   closed before leaves its accept to be finished here. */
static void shut(net *n, const char *why) {
  shut_one(n, why);
  while (n->handshakes) {
    request *q = n->handshakes;
    shut_one(q->child, why);
    finish(q);
  }
}

static void say_goodbye(void *native) { goodbye(native); }

/* The resource gave its count back: the close and the count, on the I/O thread. */
static void release_step(void *data) {
  release_call *call = data;
  net *n = call->n;
  shut(n, call->why);
  free(call);
  n->users--;
  settle(n);
}

static void post_release(net *n, const char *why) {
  release_call *call = malloc(sizeof *call);
  if (!call) agc_out_of_memory();
  call->n = n;
  call->why = why;
  agc_loop_call(n->io, release_step, call);
}

/* The registry's release: from the end of the run (on the I/O thread) or from the drop of a detached job's result
   (on a scheduler), so it is a step. */
static void release_net(void *native) { post_release(native, "exit"); }

static net *make_net(const agc_trace *trace, agc_loop *io, char *host, int64_t port, bool listener) {
  net *n = calloc(1, sizeof(net));
  if (!n) agc_out_of_memory();
  n->trace = *trace;
  n->io = io;
  n->host = host;
  n->port = port;
  n->listener = listener;
  return n;
}

static net *new_net(agc_vm *vm, char *host, int64_t port, bool listener) {
  return make_net(&vm->rt->trace, agc_io_loop(vm), host, port, listener);
}

/* The scheduler's half of a close (the resource, under rt->sync); the net's half is a step. */
static void disown(agc_vm *vm, agc_resource *r, const char *why) {
  net *n = r->native;
  if (!n) return;
  r->native = NULL;
  agc_unregister(vm, r);
  post_release(n, why);
}

static void close_net(agc_vm *vm, agc_resource *r, agc_task *ender) {
  (void)ender;
  disown(vm, r, "owner");
}

/* COUNTED: the resource takes a new count on the net, which only a net that no other thread has seen yet may do (a
   socket or listener this builtin just made); an accepted socket comes with the count its accept took on the I/O
   thread, so the counts are not touched here. */
static agc_resource *own(agc_vm *vm, net *n, bool counted) {
  agc_resource *r = agc_register(vm, n, release_net);
  r->goodbye = say_goodbye;
  agc_own(vm, r, close_net);
  if (counted) n->users++;
  n->id = r->id;
  return r;
}

static request *new_request(net *n, req_kind kind) {
  request *q = calloc(1, sizeof(request));
  if (!q) agc_out_of_memory();
  q->kind = kind;
  q->n = n;
  return q;
}

/* The START step of a request: its count on the net and its slot. */
static void link_request(request *q, agc_io_job *job) {
  net *n = q->n;
  q->job = job;
  q->counted = true;
  n->users++;
  if (reads(q->kind)) {
    n->reader = q;
  } else if (q->kind == REQ_SEND) {
    n->writer = q;
  } else if (q->kind != REQ_ACCEPT) {
    n->opener = q;
  } else if (n->accepts_tail) {
    n->accepts_tail->next = q;
    n->accepts_tail = q;
  } else {
    n->accepts = n->accepts_tail = q;
  }
}

static void release_child(request *q) {
  net *c = q->child;
  if (!c) return;
  q->child = NULL;
  c->opener = NULL;
  shut(c, "failed");
  c->users--;
  settle(c);
}

/* The end of a request, on the I/O thread: posted by its done half, or the job's drop. A request whose START never
   ran (the run ended first) holds nothing on the net. */
static void drop_request(void *data) {
  request *q = data;
  net *n = q->n;
  free(q->data);
  free(q->rest);
  agc_inbuf_cut_free(&q->cut);
  if (!q->counted) {
    free(q);
    return;
  }
  unlink_request(q);
  release_child(q);
  free(q);
  n->users--;
  settle(n);
}

static agc_value net_error(agc_vm *vm, const net *n, const char *what, int err) {
  const char *host = n->host ? n->host : "";
  size_t size = agc_size_add(strlen(host), strlen(what) + 64);
  char *head = agc_alloc_atomic(size);
  int len = snprintf(head, size, "%s\n  hostname: %s\n  port number: %" PRId64, what, host, n->port);
  if (len < 0) len = 0;
  /* getaddrinfo failures (UV_EAI_*, -3000 down to -3014 on every system) have no errno: libuv names them. */
  if (err > UV_EAI_ADDRFAMILY || err < UV_EAI_PROTOCOL) return agc_system_error(vm, head, agc_net_errno(err));
  const char *reason = uv_strerror(err);
  size_t total = agc_size_add((size_t)len, strlen(reason) + 20);
  char *text = agc_alloc_atomic(total);
  int full = snprintf(text, total, "%s\n  system error: %s", head, reason);
  size_t n_text = full < 0 ? 0 : (size_t)full;
  return agc_result_value(false, agc_string_value(agc_utf8_decode((const uint8_t *)text, n_text, "?", true)));
}

static agc_value tls_failure(agc_vm *vm, const char *head, const agc_tls_failure *f) {
  if (f->sys) return agc_system_error(vm, head, f->sys);
  size_t size = agc_size_add(strlen(head), sizeof f->detail + 4);
  char *text = agc_alloc_atomic(size);
  int len = snprintf(text, size, "%s (%s)", head, f->detail);
  size_t n_text = len < 0 ? 0 : (size_t)len;
  return agc_result_value(false, agc_string_value(agc_utf8_decode((const uint8_t *)text, n_text, "?", true)));
}

agc_value agc_tls_load_error(agc_vm *vm, const char *what, const char *path, const agc_tls_failure *f) {
  size_t size = agc_size_add(strlen(what), agc_size_add(strlen(path), 32));
  char *head = agc_alloc_atomic(size);
  snprintf(head, size, "%s: load failed from: \"%s\"", what, path);
  return tls_failure(vm, head, f);
}

static agc_value secure_error(agc_vm *vm, const net *n) {
  const agc_tls_failure *f = &n->failure;
  if (n->parent) return tls_failure(vm, "port->ssl-ports: accept failed", f);
  if (f->code == AGC_TLS_ERR_BAD_CERT) return agc_tls_load_error(vm, "ssl-load-certificate-chain!", n->cert_file, f);
  if (f->code == AGC_TLS_ERR_BAD_KEY || f->code == AGC_TLS_ERR_KEY_MISMATCH)
    return agc_tls_load_error(vm, "ssl-load-private-key!", n->key_file, f);
  if (f->code == AGC_TLS_ERR_BAD_CA) return agc_tls_load_error(vm, "ssl-load-verify-source!", n->ca_file, f);
  return tls_failure(vm, n->listener ? "ssl-make-server-context: setup failed" : "ssl-connect: connect failed", f);
}

static agc_value open_failure(agc_vm *vm, const net *n, bool found, int err) {
  if (n->listener) return net_error(vm, n, found ? "tcp-listen: listen failed" : "tcp-listen: host not found", err);
  return net_error(vm, n, found ? "tcp-connect: connection failed" : "tcp-connect: host not found", err);
}

static void read_port(net *n, const tcp_link *k) {
  struct sockaddr_storage address;
  int len = sizeof address;
  if (uv_tcp_getsockname(&k->tcp, (struct sockaddr *)&address, &len)) return;
  if (address.ss_family == AF_INET) n->port = ntohs(((const struct sockaddr_in *)&address)->sin_port);
  if (address.ss_family == AF_INET6) n->port = ntohs(((const struct sockaddr_in6 *)&address)->sin6_port);
}

static void stop_reading(net *n) {
  if (!n->reading) return;
  uv_read_stop((uv_stream_t *)&n->conn->tcp);
  n->reading = false;
}

static void handshake_failed(net *n, agc_tls_status status) {
  if (status != AGC_TLS_ERROR) {
    n->failure.code = AGC_TLS_ERR_UNEXPECTED_EOF;
    n->failure.sys = n->in.error ? n->in.error : n->write_status < 0 ? agc_net_errno(n->write_status) : 0;
    snprintf(n->failure.detail, sizeof n->failure.detail, "%s", "connection closed during handshake");
  }
  n->tls_failed = true;
  stop_reading(n);
  if (n->plain) {
    n->write_status = UV_EPROTO;
    notify(n, n->writer);
  }
  AGC_TRACE(&n->trace, AGC_TRACE_TLS, "tls_handshake_error socket=%" PRIu64 " listener=%" PRIu64 " error=%s detail=%s",
            n->id, n->parent, agc_tls_error_name(n->failure.code), n->failure.detail);
  notify(n, n->opener);
}

static void flush(net *n, uv_write_cb wrote) {
  while (!n->flushing && !n->closed && n->write_status >= 0) {
    const uint8_t *data;
    size_t len = agc_tls_out_peek(n->tls, &data);
    if (len) {
      int rc = agc_stream_write((uv_stream_t *)&n->conn->tcp, &n->write_req, &n->write_data, data, len, wrote);
      agc_tls_out_consume(n->tls, len);
      if (rc < 0) n->write_status = rc;
      if (rc == 1) n->flushing = true;
      continue;
    }
    if (n->plain_at >= n->plain_len || !n->handshaken) break;
    size_t left = n->plain_len - n->plain_at;
    size_t step = left < TLS_CHUNK ? left : TLS_CHUNK;
    if (agc_tls_write(n->tls, n->plain + n->plain_at, step, &n->failure) != AGC_TLS_OK) {
      n->write_status = UV_EPROTO;
      break;
    }
    n->plain_at += step;
  }
  if (n->plain && (n->write_status < 0 || n->plain_at >= n->plain_len)) {
    free(n->plain);
    n->plain = NULL;
    n->plain_at = n->plain_len = 0;
  }
  if (n->write_status < 0 || (!n->flushing && !n->plain)) notify(n, n->writer);
}

static void tls_wrote(uv_write_t *w, int status) {
  net *n = NET(w, write_req);
  free(n->write_data);
  n->write_data = NULL;
  n->flushing = false;
  if (status < 0 && n->write_status >= 0) n->write_status = status;
  if (n->closed) return;
  if (n->write_status < 0 && !n->handshaken && !n->tls_failed) {
    handshake_failed(n, AGC_TLS_WANT_WRITE);
    return;
  }
  flush(n, tls_wrote);
}

static void decrypt(net *n) {
  while (!n->in.eof && !n->in.error) {
    uint8_t *room = agc_inbuf_room(&n->in, TLS_CHUNK);
    if (!room) {
      n->in.error = ENOMEM;
      return;
    }
    size_t got = 0;
    agc_tls_status status = agc_tls_read(n->tls, room, TLS_CHUNK, &got, &n->failure);
    if (got) agc_inbuf_got(&n->in, (int64_t)got, false);
    if (status == AGC_TLS_OK) continue;
    if (status == AGC_TLS_CLOSED || (status == AGC_TLS_WANT_READ && n->raw_eof)) n->in.eof = true;
    if (status == AGC_TLS_CLOSED && !n->raw_eof) n->clean_eof = true;
    if (status == AGC_TLS_ERROR) {
      AGC_TRACE(&n->trace, AGC_TRACE_TLS, "tls_read_error socket=%" PRIu64 " error=%s", n->id,
                agc_tls_error_name(n->failure.code));
      n->in.error = EPROTO;
    }
    return;
  }
}

static void advance(net *n) {
  if (n->tls_failed) return;
  if (!n->handshaken) {
    agc_tls_status status = agc_tls_handshake(n->tls, &n->failure);
    flush(n, tls_wrote);
    if (status != AGC_TLS_OK) {
      if (status == AGC_TLS_ERROR || status == AGC_TLS_CLOSED || n->raw_eof || n->in.error || n->write_status < 0)
        handshake_failed(n, status);
      return;
    }
    n->handshaken = true;
    AGC_TRACE(&n->trace, AGC_TRACE_TLS, "tls_handshake_done socket=%" PRIu64 " listener=%" PRIu64 " protocol=%s cipher=%s",
              n->id, n->parent, agc_tls_protocol(n->tls), agc_tls_cipher(n->tls));
    notify(n, n->opener);
  }
  decrypt(n);
  flush(n, tls_wrote);
}

static void alloc_in(uv_handle_t *h, size_t suggested, uv_buf_t *buf) {
  (void)suggested;
  net *n = TCP_LINK(h, tcp)->owner;
  if (n->tls) {
    *buf = uv_buf_init((char *)n->cipher, (unsigned)CIPHER_SIZE);
    return;
  }
  const request *q = n->reader;
  bool counted = q && (q->kind == REQ_BYTES || q->kind == REQ_TEXT);
  size_t size = agc_inbuf_want(&n->in, !counted, counted ? q->count : 0);
  uint8_t *room = agc_inbuf_room(&n->in, size);
  *buf = room ? uv_buf_init((char *)room, (unsigned)size) : uv_buf_init(NULL, 0);
}

/* The reader's line or bytes are in: a line longer than the limit closes the socket, as take does. */
static void finish_reader(net *n) {
  request *q = n->reader;
  finish(q);
  if (q && q->kind == REQ_LINE && q->cut.status == AGC_CUT_OVER) shut(n, "line");
}

static void tls_read_in(net *n, ssize_t got) {
  if (got > 0 && !agc_tls_feed_in(n->tls, n->cipher, (size_t)got)) n->in.error = ENOMEM;
  if (got == UV_EOF) {
    n->raw_eof = true;
    agc_tls_feed_eof(n->tls);
  } else if (got < 0) {
    n->in.error = agc_net_errno((int)got);
  }
  if (got < 0)
    AGC_TRACE(&n->trace, AGC_TRACE_IO, "tcp_eof socket=%" PRIu64 " error=%d", n->id, got == UV_EOF ? 0 : agc_net_errno((int)got));
  advance(n);
  request *q = n->reader;
  bool done = n->handshaken && q && read_ready(n, q);
  if (got < 0 || n->tls_failed || (n->handshaken && ((!q && !n->watch) || done))) stop_reading(n);
  if (done) finish_reader(n);
  if (n->watch) n->watch(n->watcher);
}

static void read_in(uv_stream_t *s, ssize_t got, const uv_buf_t *buf) {
  (void)buf;
  net *n = TCP_LINK(s, tcp)->owner;
  if (n->tls) {
    tls_read_in(n, got);
    return;
  }
  agc_inbuf_got(&n->in, got, got == UV_EOF);
  if (got < 0)
    AGC_TRACE(&n->trace, AGC_TRACE_IO, "tcp_eof socket=%" PRIu64 " error=%d", n->id, got == UV_EOF ? 0 : agc_net_errno((int)got));
  request *q = n->reader;
  bool done = q && read_ready(n, q);
  if (got < 0 || (!q && !n->watch) || done) stop_reading(n);
  if (done) finish_reader(n);
  if (n->watch) n->watch(n->watcher);
}

static void start_reading(net *n) {
  if (n->reading || n->in.eof || n->in.error || n->raw_eof) return;
  int rc = uv_read_start((uv_stream_t *)&n->conn->tcp, alloc_in, read_in);
  if (rc)
    n->in.error = agc_net_errno(rc);
  else
    n->reading = true;
}

static void begin_tls(net *n, agc_tls *t) {
  n->tls = t;
  if (!t) {
    n->tls_failed = true;
    notify(n, n->opener);
    return;
  }
  n->cipher = malloc(CIPHER_SIZE);
  if (!n->cipher) agc_out_of_memory();
  advance(n);
  if (n->tls_failed) return;
  start_reading(n);
  if (n->in.error) handshake_failed(n, AGC_TLS_WANT_READ);
}

static net *accept_link(net *l, tcp_link *k, int *rc) {
  k->backlog--;
  net *c = make_net(&l->trace, l->io, NULL, 0, false);
  c->loop = l->loop;
  tcp_link *link = new_link(c);
  *rc = uv_accept((uv_stream_t *)&k->tcp, (uv_stream_t *)&link->tcp);
  if (*rc) {
    drop_link(link);
    return NULL;
  }
  c->conn = link;
  c->connected = true;
  c->parent = l->id;
  uv_tcp_nodelay(&link->tcp, 1);
  return c;
}

static request *next_accept(net *n) {
  request *q = n->accepts;
  if (!q) return NULL;
  n->accepts = q->next;
  if (!n->accepts) n->accepts_tail = NULL;
  q->next = NULL;
  return q;
}

/* Waiting accepts take the connections in the backlog, here on the I/O thread: the accepted socket travels in the
   request, which holds a count on it until its done half adopts it. A TLS connection first handshakes, under the
   accept's deadline, and finishes its accept when the handshake ends. A failed uv_accept closes the listener: on Unix
   libuv stops watching that link, and on Windows the socket it held is gone, so the link is not trusted again. */
static void serve(net *n) {
  while (n->accepts) {
    tcp_link *k = n->conn;
    while (k && !k->backlog) k = k->next;
    if (!k) return;
    request *q = next_accept(n);
    int rc = 0;
    net *c = accept_link(n, k, &rc);
    if (!c) {
      q->accept_rc = rc;
      finish(q);
      shut(n, "accept");
      return;
    }
    c->users++;
    q->child = c;
    if (!n->secure) {
      finish(q);
      continue;
    }
    c->secure = true;
    c->opener = q;
    q->next = n->handshakes;
    n->handshakes = q;
    AGC_TRACE(&n->trace, AGC_TRACE_TLS, "tls_handshake socket=0 listener=%" PRIu64 " role=server", n->id);
    begin_tls(c, agc_tls_server(n->config, &c->failure));
  }
}

static void incoming(uv_stream_t *server, int status) {
  tcp_link *k = TCP_LINK(server, tcp);
  net *n = k->owner;
  /* Only Windows reports an error here (Unix libuv retries or sheds load itself), and only once it has stopped
     listening on the link (src/win/tcp.c uv__process_tcp_accept_req), so no connection would ever come: the head
     waiter gets the error and the listener closes, which ends every other wait. */
  if (status < 0) {
    AGC_TRACE(&n->trace, AGC_TRACE_IO, "tcp_accept_error listener=%" PRIu64 " error=%d", n->id, agc_net_errno(status));
    request *q = next_accept(n);
    if (q) q->error = status;
    finish(q);
    shut(n, "accept");
    return;
  }
  k->backlog++;
  serve(n);
  if (n->watch) n->watch(n->watcher);
}

static bool seen(const struct addrinfo *list, const struct addrinfo *a) {
  for (; list != a; list = list->ai_next)
    if (list->ai_family == a->ai_family && list->ai_addrlen == a->ai_addrlen &&
        !memcmp(list->ai_addr, a->ai_addr, a->ai_addrlen))
      return true;
  return false;
}

static int listen_on(net *n, const struct addrinfo *a, int64_t port) {
  struct sockaddr_storage address;
  if (a->ai_addrlen > sizeof address) return UV_EAFNOSUPPORT;
  memcpy(&address, a->ai_addr, a->ai_addrlen);
  if (port >= 0 && address.ss_family == AF_INET) ((struct sockaddr_in *)&address)->sin_port = htons((uint16_t)port);
  if (port >= 0 && address.ss_family == AF_INET6) ((struct sockaddr_in6 *)&address)->sin6_port = htons((uint16_t)port);
  unsigned flags = a->ai_family == AF_INET6 && n->addrs->ai_next ? UV_TCP_IPV6ONLY : 0;
  tcp_link *k = new_link(n);
  int rc = uv_tcp_bind(&k->tcp, (const struct sockaddr *)&address, flags);
  if (!rc) rc = uv_listen((uv_stream_t *)&k->tcp, BACKLOG, incoming);
  if (rc) {
    drop_link(k);
    return rc;
  }
  k->next = n->conn;
  n->conn = k;
  return 0;
}

static int bind_from(net *n, const struct addrinfo *first, bool *bound) {
  *bound = false;
  int rc = listen_on(n, first, -1);
  if (rc) return rc;
  *bound = true;
  read_port(n, n->conn);
  for (const struct addrinfo *a = first->ai_next; a; a = a->ai_next) {
    if (seen(n->addrs, a)) continue;
    rc = listen_on(n, a, n->port);
    if (rc && rc != UV_EADDRNOTAVAIL && rc != UV_EAFNOSUPPORT) return rc;
  }
  return 0;
}

static void bind_all(net *n) {
  int64_t wanted = n->port;
  int tries = 0;
  const struct addrinfo *a = n->addrs;
  while (a) {
    bool bound;
    int rc = bind_from(n, a, &bound);
    if (!rc) {
      size_t count = 0;
      for (const tcp_link *k = n->conn; k; k = k->next) count++;
      AGC_TRACE(&n->trace, AGC_TRACE_IO, "tcp_listen listener=%" PRIu64 " host=%s port=%" PRId64 " addresses=%zu", n->id,
                n->host, n->port, count);
      notify(n, n->opener);
      return;
    }
    n->error = rc;
    drop_links(n);
    n->port = wanted;
    if (!bound && (rc == UV_EADDRNOTAVAIL || rc == UV_EAFNOSUPPORT))
      a = a->ai_next;
    else if (!bound || wanted || rc != UV_EADDRINUSE || ++tries >= BIND_TRIES)
      break;
  }
  notify(n, n->opener);
}

static void attempt(net *n, uv_connect_cb done) {
  while (n->next_addr) {
    const struct addrinfo *a = n->next_addr;
    n->next_addr = a->ai_next;
    tcp_link *k = new_link(n);
    int rc = uv_tcp_connect(&k->connect, &k->tcp, a->ai_addr, done);
    if (!rc) {
      n->conn = k;
      return;
    }
    n->error = rc;
    drop_link(k);
  }
  notify(n, n->opener);
}

static void connected(uv_connect_t *req, int status) {
  tcp_link *k = TCP_LINK(req, connect);
  net *n = k->owner;
  if (n->closed) return;
  if (status == 0) {
    n->connected = true;
    uv_tcp_nodelay(&k->tcp, 1);
    AGC_TRACE(&n->trace, AGC_TRACE_IO, "tcp_connected socket=%" PRIu64, n->id);
    if (n->secure) {
      AGC_TRACE(&n->trace, AGC_TRACE_TLS, "tls_handshake socket=%" PRIu64 " listener=0 role=client host=%s", n->id,
                n->host);
      begin_tls(n, agc_tls_client(n->shared ? n->shared->config : n->config, n->host, &n->failure));
      return;
    }
    notify(n, n->opener);
    return;
  }
  AGC_TRACE(&n->trace, AGC_TRACE_IO, "tcp_connect_error socket=%" PRIu64 " error=%d", n->id, agc_net_errno(status));
  n->error = status;
  n->conn = NULL;
  drop_link(k);
  attempt(n, connected);
}

static void resolved(uv_getaddrinfo_t *req, int status, struct addrinfo *res) {
  net *n = NET(req, dns);
  n->resolving = false;
  n->callbacks--;
  n->addrs = res;
  if (n->closed || (!n->opener && !n->watch)) {
    settle(n);
    return;
  }
  if (status < 0) {
    n->error = status;
    notify(n, n->opener);
    return;
  }
  n->resolved = true;
  n->next_addr = res;
  if (n->listener)
    bind_all(n);
  else
    attempt(n, connected);
}

static int resolve(net *n) {
  char service[PORT_TEXT];
  snprintf(service, sizeof service, "%" PRId64, n->port);
  struct addrinfo hints;
  memset(&hints, 0, sizeof hints);
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags = n->listener ? AI_PASSIVE : 0;
  int rc = uv_getaddrinfo(n->loop, &n->dns, resolved, n->host, service, &hints);
  if (!rc) {
    n->resolving = true;
    n->callbacks++;
  }
  return rc;
}

/* A system with TLS sockets off (net_os.h) fails the context build with this detail, as the TLS stub once did. */
static bool tls_refused(agc_tls_failure *f) {
  if (agc_net_tls_enabled()) return false;
  f->code = AGC_TLS_ERR_INTERNAL;
  f->sys = 0;
  snprintf(f->detail, sizeof f->detail, "%s", "TLS needs Linux or macOS");
  return true;
}

static void setup_work(uv_work_t *w) {
  net *n = NET(w, setup);
  if (tls_refused(&n->failure)) n->config = NULL;
  else
    n->config = n->listener ? agc_tls_server_config(n->cert_file, n->key_file, &n->failure)
                            : agc_tls_client_config(n->ca_file, &n->failure);
}

/* A context build for N is over: its open fails with the build's failure (in n->failure), or goes on to DNS. I/O
   thread only. */
static void setup_over(net *n, bool built, int status) {
  if (n->closed || !n->opener) {
    settle(n);
    return;
  }
  if (!built) {
    if (status < 0) {
      n->failure.code = AGC_TLS_ERR_INTERNAL;
      n->failure.sys = agc_net_errno(status);
    }
    n->tls_failed = true;
    AGC_TRACE(&n->trace, AGC_TRACE_TLS, "tls_setup_error %s=%" PRIu64 " error=%s", kind_name(n), n->id,
              agc_tls_error_name(n->failure.code));
    notify(n, n->opener);
    return;
  }
  int rc = resolve(n);
  if (rc) {
    n->error = rc;
    notify(n, n->opener);
  }
}

static void setup_done(uv_work_t *w, int status) {
  net *n = NET(w, setup);
  n->setting_up = false;
  n->callbacks--;
  if (n->config) AGC_TRACE(&n->trace, AGC_TRACE_TLS, "tls_config %s=%" PRIu64 " shared=0", kind_name(n), n->id);
  setup_over(n, n->config != NULL, status);
}

static int start_setup(net *n) {
  int rc = agc_io_queue_work(n->loop, &n->setup, setup_work, setup_done);
  if (!rc) {
    n->setting_up = true;
    n->callbacks++;
  }
  return rc;
}

static void shared_work(uv_work_t *w) {
  tls_shared *s = (tls_shared *)(void *)((char *)w - offsetof(tls_shared, work));
  s->built = tls_refused(&s->failure) ? NULL : agc_tls_client_config(s->ca_file, &s->failure);
}

/* The client's context is built (or failed): every net that waited goes on, as after its own build. The build's
   count keeps the context alive while they do. */
static void shared_done(uv_work_t *w, int status) {
  tls_shared *s = (tls_shared *)(void *)((char *)w - offsetof(tls_shared, work));
  s->building = false;
  s->config = s->built;
  s->built = NULL;
  net *n = s->waiters;
  s->waiters = s->waiters_tail = NULL;
  if (s->config && n) AGC_TRACE(&n->trace, AGC_TRACE_TLS, "tls_config socket=%" PRIu64 " shared=1", n->id);
  while (n) {
    net *next = n->next_waiter;
    n->next_waiter = NULL;
    n->setting_up = false;
    n->callbacks--;
    if (!s->config) n->failure = s->failure;
    setup_over(n, s->config != NULL, status);
    n = next;
  }
  shared_unref(s);
}

/* The open of a net on its client's context: at once when the context is built, else after the build, which the
   first such net starts. I/O thread only. */
static int shared_open(net *n) {
  tls_shared *s = n->shared;
  if (s->config) return resolve(n);
  if (!s->building) {
    int rc = agc_io_queue_work(n->loop, &s->work, shared_work, shared_done);
    if (rc) return rc;
    s->building = true;
    atomic_fetch_add_explicit(&s->refs, 1, memory_order_relaxed);
  }
  if (s->waiters_tail)
    s->waiters_tail->next_waiter = n;
  else
    s->waiters = n;
  s->waiters_tail = n;
  n->setting_up = true;
  n->callbacks++;
  return 0;
}

/* A read at N = 1 whose input is ready: the cut and the value in one step. */
static agc_value take(agc_vm *vm, net *n, request *q) {
  if (n->closed) return agc_error_value(socket_closed);
  if (q->kind == REQ_TEXT || heads(q->kind)) {
    if (q->kind == REQ_TEXT) cut_text(n, q);
    else cut_head(n, q);
    agc_value result = q->kind == REQ_TEXT ? text_value(vm, q) : head_value(vm, q);
    agc_inbuf_cut_free(&q->cut);
    return result;
  }
  if (q->kind == REQ_BYTES) return agc_inbuf_bytes(vm, &n->in, q->count);
  bool over;
  agc_value line = agc_inbuf_line(vm, &n->in, "network: line exceeds 1048576 bytes", "network: end of input", &over);
  if (over) shut(n, "line");
  return line;
}

static agc_socket *new_socket(agc_vm *vm, net *n, bool counted) {
  agc_socket *sk = agc_alloc(sizeof(agc_socket));
  sk->state = own(vm, n, counted);
  sk->reader = agc_new_lock(vm);
  sk->writer = agc_new_lock(vm);
  return sk;
}

/* The accepted socket moves from the request to a socket value, with the count the request held: the request no
   longer closes it when it ends (drop_request). */
static agc_value adopt(agc_vm *vm, request *q, const net *l) {
  net *c = q->child;
  q->child = NULL;
  agc_socket *sk = new_socket(vm, c, false);
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "tcp_accept listener=%" PRIu64 " socket=%" PRIu64, l->id, sk->state->id);
  return ok_value(agc_socket_value(sk));
}

static agc_value accept_done(agc_vm *vm, request *q, const net *l) {
  if (q->accept_rc) return agc_system_error(vm, "tcp-accept: accept failed", agc_net_errno(q->accept_rc));
  if (q->closed) return agc_error_value(listener_closed);
  if (q->child && q->opened) return adopt(vm, q, l);
  if (q->child && q->tls_failed) return tls_failure(vm, "port->ssl-ports: accept failed", &q->child->failure);
  if (q->child) return agc_error_value(socket_closed);
  if (q->error) return agc_system_error(vm, "tcp-accept: accept failed", agc_net_errno(q->error));
  return agc_error_value(listener_closed);
}

static agc_value opened(agc_vm *vm, const request *q, agc_value context) {
  const net *n = q->n;
  if (q->opened) {
    if (!n->listener) return ok_value(context);
    agc_listener *lv = agc_as_listener(vm, context);
    lv->port = q->port;
    return ok_value(context);
  }
  agc_value result = q->tls_failed ? secure_error(vm, n) : open_failure(vm, n, q->resolved, q->open_error);
  disown(vm, n->listener ? agc_as_listener(vm, context)->state : agc_as_socket(vm, context)->state, "failed");
  return result;
}

/* The done half reads the request only (finish filled it), then gives the request back to the I/O thread. */
static agc_value request_done(agc_vm *vm, void *data, agc_value context) {
  request *q = data;
  net *n = q->n;
  if (q->kind == REQ_SEND) agc_charge(vm, q->count);
  agc_value result;
  if (q->kind == REQ_CONNECT || q->kind == REQ_LISTEN) {
    result = opened(vm, q, context);
  } else if (q->kind == REQ_ACCEPT) {
    result = accept_done(vm, q, n);
  } else if (reads(q->kind)) {
    if (q->closed)
      result = agc_error_value(socket_closed);
    else if (q->kind == REQ_TEXT)
      result = text_value(vm, q);
    else if (heads(q->kind))
      result = head_value(vm, q);
    else if (q->kind == REQ_BYTES)
      result = agc_inbuf_cut_bytes_value(vm, &q->cut);
    else
      result = agc_inbuf_cut_line_value(vm, &q->cut, "network: line exceeds 1048576 bytes", "network: end of input");
    agc_charge(vm, agc_value_units(result));
  } else if (q->closed) {
    result = agc_error_value(socket_closed);
  } else {
    result = q->write_status < 0 ? agc_system_error(vm, write_failed, agc_net_errno(q->write_status)) : ok_value(agc_void());
  }
  agc_loop_call(agc_io_loop(vm), drop_request, q);
  return result;
}

/* The timer's stop, on the I/O thread before EXPIRED is published (the kind's `pause`): the request leaves its slot,
   and a timed-out connect, read or send closes the socket. */
static void stop_request(void *data) {
  request *q = data;
  if (q->stopped || !q->counted) return;
  q->stopped = true;
  unlink_request(q);
  if (q->kind != REQ_ACCEPT && q->kind != REQ_LISTEN) shut(q->n, "timeout");
}

/* The timer's `pause` (stop_request) has run already: a task parked on a TCP job is woken by nothing else. */
static agc_value request_expired(agc_vm *vm, void *data, agc_value context) {
  const request *q = data;
  if (q->kind == REQ_CONNECT) disown(vm, agc_as_socket(vm, context)->state, "timeout");
  return agc_stream_timed_out();
}

/* On the I/O thread without rt->sync: it stops the request and the net only. A cancelled connect's socket resource is
   closed by its owner's end (agc_close_owned), on a scheduler. */
static bool request_cancel(agc_vm *vm, void *data, agc_value context, bool deadline) {
  (void)vm;
  (void)context;
  request *q = data;
  if (!deadline || q->kind == REQ_SEND || !q->counted) return false;
  unlink_request(q);
  if (q->kind == REQ_CONNECT) shut(q->n, "cancel");
  return true;
}

static const agc_io_kind tcp_io = {NULL,          request_done, request_expired, drop_request, true, "tcp",
                                   request_cancel, true,        stop_request};

/* Parks the task on the request; BEGIN, its START step, runs on the I/O thread (at once at N = 1). */
static void park(agc_vm *vm, request *q, agc_value context, int64_t timeout, agc_more_fn begin) {
  (void)agc_io_start_then(vm, &tcp_io, q, context, timeout, begin);
}

static void no_network(agc_vm *vm, uint32_t span) {
  if (vm->rt->no_files) agc_fail(vm, "RUNTIME-INTERNAL", "network access is off in this run", span);
}

static bool begin_open(void *data, agc_io_job *job) {
  request *q = data;
  net *n = q->n;
  link_request(q, job);
  n->loop = agc_loop_uv(n->io);
  int rc = n->shared ? shared_open(n) : n->secure ? start_setup(n) : resolve(n);
  if (rc) {
    n->error = rc;
    finish(q);
  }
  return true;
}

static agc_value start_open(agc_vm *vm, net *n, agc_value value, int64_t timeout) {
  park(vm, new_request(n, n->listener ? REQ_LISTEN : REQ_CONNECT), value, timeout, begin_open);
  return agc_void();
}

static bool tls_paths(agc_vm *vm, const agc_value *args, size_t count, char **paths) {
  bool all = true;
  for (size_t k = 0; k < count; k++) {
    paths[k] = agc_cstr(agc_as_string(vm, args[k]));
    all = all && paths[k];
  }
  if (all) return true;
  for (size_t k = 0; k < count; k++) free(paths[k]);
  return false;
}

/* The client's context, with a count for the caller: made on first use, NULL once HttpWire.drop_tls gave it back.
   Under rt->sync, so a drop on another scheduler cannot free it between the look and the count. */
static tls_shared *client_context(agc_vm *vm, agc_http_client *c, const char *ca_file) {
  agc_sync_take(vm);
  tls_shared *s = c->tls;
  if (!s && !c->tls_dropped) {
    s = calloc(1, sizeof *s);
    char *ca = strdup(ca_file);
    if (!s || !ca) agc_out_of_memory();
    s->ca_file = ca;
    atomic_init(&s->refs, 1);
    c->tls = s;
  }
  if (s) atomic_fetch_add_explicit(&s->refs, 1, memory_order_relaxed);
  agc_sync_drop(vm);
  return s;
}

/* CLIENT, when not NULL, is the HttpClient whose context the net takes a count on (HttpWire.connect_tls); CA is then
   its ca_file, kept for the error text. */
static agc_value connect_net(agc_vm *vm, char *name, int64_t port, bool secure, char *ca, agc_http_client *client,
                             int64_t timeout) {
  net *n = new_net(vm, name, port, false);
  n->secure = secure;
  n->ca_file = ca;
  agc_socket *sk = new_socket(vm, n, true);
  /* The count is taken once the socket exists, so a failure in making it cannot lose one. */
  if (client) n->shared = client_context(vm, client, ca);
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "tcp_connect socket=%" PRIu64 " host=%s port=%" PRId64, sk->state->id, name,
            port);
  return start_open(vm, n, agc_socket_value(sk), timeout);
}

static agc_value open_socket(agc_vm *vm, const agc_value *args, uint32_t span, bool secure) {
  no_network(vm, span);
  const agc_string *host = agc_as_string(vm, args[0]);
  int64_t port = agc_as_int(vm, args[1]);
  int64_t timeout = agc_as_int(vm, args[secure ? 3 : 2]);
  if (timeout <= 0) return agc_stream_bad_timeout();
  if (port < 1 || port > 65535) return agc_error_value("network: port must be 1..65535");
  char *ca = NULL;
  if (secure && !tls_paths(vm, args + 2, 1, &ca)) return agc_error_value("network: path cannot contain NUL");
  char *name = agc_cstr(host);
  if (!name) {
    free(ca);
    return agc_error_value("network: host cannot contain NUL");
  }
  return connect_net(vm, name, port, secure, ca, NULL, timeout);
}

/* HttpWire.connect_tls(client, host, port, timeout_ms) (std-only): TLS.connect with the client's ca_file, on the
   context that the client's connections share, so it is built once (#394). After HttpWire.drop_tls a call builds
   its own context, as TLS.connect does. */
static agc_value builtin_connect_tls(agc_vm *vm, agc_value *args, uint32_t span) {
  no_network(vm, span);
  agc_http_client *c = agc_as_http_client(vm, args[0]);
  const agc_string *host = agc_as_string(vm, args[1]);
  int64_t port = agc_as_int(vm, args[2]);
  int64_t timeout = agc_as_int(vm, args[3]);
  if (timeout <= 0) return agc_stream_bad_timeout();
  if (port < 1 || port > 65535) return agc_error_value("network: port must be 1..65535");
  /* HttpWire.service checked the shape; checked again, since a bad read here goes past the struct. */
  const agc_struct *o = agc_as_struct(vm, c->options);
  if (o->n != AGC_HTTP_OPTIONS_FIELDS) return agc_error_value("http: invalid client options");
  char *name = agc_cstr(host);
  if (!name) return agc_error_value("network: host cannot contain NUL");
  /* HTTP.client refuses a ca_file with NUL, so only bytecode that skipped it gets here. */
  char *ca = agc_cstr(agc_as_string(vm, o->fields[AGC_HTTP_OPTION_CA_FILE]));
  if (!ca) {
    free(name);
    return agc_error_value("http: invalid client options");
  }
  return connect_net(vm, name, port, true, ca, c, timeout);
}

/* HttpWire.drop_tls(client) (std-only): the client gives its count on its context back, when its owner task ends.
   Connections still open or in their handshake keep their own counts. */
static agc_value builtin_drop_tls(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_http_client *c = agc_as_http_client(vm, args[0]);
  agc_sync_take(vm);
  tls_shared *s = c->tls;
  c->tls = NULL;
  c->tls_dropped = true;
  agc_sync_drop(vm);
  if (s) shared_unref(s);
  return agc_void();
}

static agc_value open_listener(agc_vm *vm, const agc_value *args, uint32_t span, bool secure) {
  no_network(vm, span);
  const agc_string *host = agc_as_string(vm, args[0]);
  int64_t port = agc_as_int(vm, args[1]);
  if (port < 0 || port > 65535) return agc_error_value("network: port must be 0..65535");
  char *files[2] = {NULL, NULL};
  if (secure && !tls_paths(vm, args + 2, 2, files)) return agc_error_value("network: path cannot contain NUL");
  char *name = agc_cstr(host);
  if (!name) {
    free(files[0]);
    free(files[1]);
    return agc_error_value("network: host cannot contain NUL");
  }
  net *n = new_net(vm, name, port, true);
  n->secure = secure;
  n->cert_file = files[0];
  n->key_file = files[1];
  agc_listener *lv = agc_alloc(sizeof(agc_listener));
  lv->state = own(vm, n, true);
  lv->port = port;
  return start_open(vm, n, agc_listener_value(lv), -1);
}

static agc_value builtin_connect(agc_vm *vm, agc_value *args, uint32_t span) { return open_socket(vm, args, span, false); }

static agc_value builtin_tls_connect(agc_vm *vm, agc_value *args, uint32_t span) {
  return open_socket(vm, args, span, true);
}

static agc_value builtin_listen(agc_vm *vm, agc_value *args, uint32_t span) { return open_listener(vm, args, span, false); }

static agc_value builtin_tls_listen(agc_vm *vm, agc_value *args, uint32_t span) {
  return open_listener(vm, args, span, true);
}

static bool begin_accept(void *data, agc_io_job *job) {
  request *q = data;
  link_request(q, job);
  if (q->n->closed)
    finish(q);
  else
    serve(q->n);
  return true;
}

static agc_value builtin_accept(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  net *n = agc_as_listener(vm, args[0])->state->native;
  int64_t timeout = agc_as_int(vm, args[1]);
  if (!n || n->closed) return agc_error_value(listener_closed);
  if (timeout <= 0) return agc_stream_bad_timeout();
  park(vm, new_request(n, REQ_ACCEPT), args[0], timeout, begin_accept);
  return agc_void();
}

static agc_value builtin_local_port(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int(agc_as_listener(vm, args[0])->port);
}

static agc_value builtin_close_listener(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  disown(vm, agc_as_listener(vm, args[0])->state, "close");
  return agc_void();
}

static agc_value builtin_close(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  disown(vm, agc_as_socket(vm, args[0])->state, "close");
  return agc_void();
}

static net *live(const agc_socket *sk) {
  net *n = sk->state->native;
  return n && !n->closed ? n : NULL;
}

static bool begin_read(void *data, agc_io_job *job) {
  request *q = data;
  net *n = q->n;
  link_request(q, job);
  /* A closed net's input is gone; drop_request frees the rest. */
  if (q->rest && !n->closed) put_back(n, q);
  if (!read_ready(n, q)) start_reading(n);
  if (read_ready(n, q)) finish_reader(n);
  return true;
}

/* A read as read_op takes it: the kind, the count, the carry of
   HttpWire.read_text (copied, as the request holds no GC value) and the body
   limit of HttpWire.read_head, whose rest goes back in front of the input on
   the I/O thread (here at N = 1, else in begin_read). */
static agc_value read_op(agc_vm *vm, const agc_value *args, request *want, uint32_t span) {
  req_kind kind = want->kind;
  if (kind == REQ_BYTES || kind == REQ_TEXT) {
    int64_t wanted = agc_as_int(vm, args[1]);
    /* read_text of 0 bytes does not wait: std/http asks it how many bytes are still buffered after a body. */
    int64_t least = kind == REQ_TEXT ? 0 : 1;
    if (wanted < least || (uint64_t)wanted > LIMIT)
      return agc_error_value(least ? "network: read size must be 1..1048576" : "network: read size must be 0..1048576");
    want->count = (size_t)wanted;
  }
  if (kind == REQ_TEXT) {
    const agc_list *carry = agc_as_list(vm, args[2]);
    const uint8_t *kept = agc_byte_list(vm, carry, sizeof want->carry);
    if (!kept) agc_fail(vm, "RUNTIME-INTERNAL", "HttpWire.read_text: the carry must be at most 3 bytes", span);
    want->kept = (uint8_t)agc_list_len(carry);
    memcpy(want->carry, kept, want->kept);
  }
  const uint8_t *rest = NULL;
  size_t rest_len = 0;
  if (kind == REQ_HEAD) {
    const agc_list *list = agc_as_list(vm, args[1]);
    rest = agc_byte_list(vm, list, LIMIT);
    if (!rest) agc_fail(vm, "RUNTIME-INTERNAL", "HttpWire.read_head: rest must be at most 1048576 bytes", span);
    rest_len = agc_list_len(list);
    want->limit = (uint64_t)agc_http_max_body(vm, args[2], span);
  }
  if (kind == REQ_RESPONSE) {
    want->head_only = agc_as_bool(vm, args[1]);
    want->limit = (uint64_t)agc_http_max_body(vm, args[2], span);
  }
  int64_t timeout = agc_as_int(vm, args[kind == REQ_LINE ? 1 : kind == REQ_BYTES ? 2 : 3]);
  agc_socket *sk = agc_as_socket(vm, args[0]);
  agc_value result;
  if (!agc_stream_lock(vm, sk->reader, &timeout, &result)) return result;
  net *n = live(sk);
  if (!n) return agc_error_value(socket_closed);
  /* At N = 1 the input is this thread's: what is buffered is taken without a park. */
  if (agc_io_here(vm)) {
    if (!agc_inbuf_unread(&n->in, rest, rest_len)) agc_out_of_memory();
    rest_len = 0;
    if (read_ready(n, want)) return take(vm, n, want);
  }
  request *q = new_request(n, kind);
  q->count = want->count;
  q->kept = want->kept;
  memcpy(q->carry, want->carry, sizeof q->carry);
  q->limit = want->limit;
  q->head_only = want->head_only;
  q->scanned = want->scanned;
  if (rest_len) {
    q->rest = malloc(rest_len);
    if (!q->rest) agc_out_of_memory();
    memcpy(q->rest, rest, rest_len);
    q->rest_len = rest_len;
  }
  park(vm, q, agc_handle_value(sk->reader), timeout, begin_read);
  return agc_void();
}

static agc_value builtin_read_line(agc_vm *vm, agc_value *args, uint32_t span) {
  return read_op(vm, args, &(request){.kind = REQ_LINE}, span);
}

static agc_value builtin_recv_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return read_op(vm, args, &(request){.kind = REQ_BYTES}, span);
}

/* HttpWire.read_text (std-only): like recv_bytes, but the bytes come back as
   UTF-8 text after carry, so a body never passes through a List[Int]. */
static agc_value builtin_read_text(agc_vm *vm, agc_value *args, uint32_t span) {
  return read_op(vm, args, &(request){.kind = REQ_TEXT}, span);
}

/* HttpWire.read_head (std-only): the next request head, parsed from the
   socket's input, where it stays until it is whole; the bytes after it stay
   there for the body or the next request. rest (the bytes a chunked body's
   last read took past its end) is put back first. */
static agc_value builtin_read_head(agc_vm *vm, agc_value *args, uint32_t span) {
  return read_op(vm, args, &(request){.kind = REQ_HEAD}, span);
}

/* HttpWire.read_response (std-only): the next response head, read like
   read_head, with the framing rules of a response to HEAD when head_only. */
static agc_value builtin_read_response(agc_vm *vm, agc_value *args, uint32_t span) {
  return read_op(vm, args, &(request){.kind = REQ_RESPONSE}, span);
}

/* HttpWire.clean_eof? (std-only): whether the end of input that a read has
   reported was clean: always on plain TCP, and over TLS only after the peer's
   close_notify. The flag is written on the I/O thread before that end is
   reported and never after, and the read's job hand-off orders it before this
   load. */
static agc_value builtin_clean_eof(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const net *n = live(agc_as_socket(vm, args[0]));
  return agc_bool(n && agc_conn_clean_eof(n));
}

static void half_close_step(void *data) { agc_conn_half_close(data); }

/* HttpWire.close_write (std-only): the half-close of std/http's lingering
   close, a step on the I/O thread. The caller has already sent everything
   (TCP.send returns once the bytes are written), so only the FIN (and TLS
   close_notify) is left. The socket's owner is the caller, and its close is
   posted after this step from the same thread, so the net outlives it. */
static agc_value builtin_close_write(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  net *n = live(agc_as_socket(vm, args[0]));
  if (n) agc_loop_call(agc_io_loop(vm), half_close_step, n);
  return agc_void();
}

static void wrote(uv_write_t *w, int status) {
  net *n = NET(w, write_req);
  free(n->write_data);
  n->write_data = NULL;
  n->write_status = status;
  notify(n, n->writer);
}

static void tls_queue(net *n, const uint8_t *data, size_t len) {
  if (len) {
    n->plain = malloc(len);
    if (!n->plain) agc_out_of_memory();
    memcpy(n->plain, data, len);
  }
  n->plain_at = 0;
  n->plain_len = len;
  flush(n, tls_wrote);
}

/* Starts a send on the I/O thread's side of the socket: 0 when it is out, 1 when it waits for libuv (the writer is
   told by `wrote` or `flush`), and a libuv error. */
static int send_now(net *n, const uint8_t *data, size_t len) {
  if (n->tls) {
    if (n->write_status < 0) return n->write_status;
    if (!n->handshaken) start_reading(n);
    tls_queue(n, data, len);
    if (n->write_status < 0) return n->write_status;
    return n->flushing || n->plain ? 1 : 0;
  }
  n->write_status = 0;
  int rc = agc_stream_write((uv_stream_t *)&n->conn->tcp, &n->write_req, &n->write_data, data, len, wrote);
  if (rc < 0) n->write_status = rc;
  return rc;
}

/* A send at N > 1 carries a copy of its bytes and starts here; at N = 1 the builtin started it and the request only
   waits for its end. */
static bool begin_send(void *data, agc_io_job *job) {
  request *q = data;
  net *n = q->n;
  link_request(q, job);
  bool out = !n->closed && q->sends && send_now(n, q->data, q->len) != 1;
  /* send_now keeps its own copy of what it could not write (tls_queue, agc_stream_write). */
  free(q->data);
  q->data = NULL;
  if (n->closed || out) finish(q);
  return true;
}

static agc_value write_op(agc_vm *vm, const agc_value *args, bool text) {
  const uint8_t *data;
  size_t len;
  if (text) {
    const agc_string *s = agc_as_string(vm, args[1]);
    data = (const uint8_t *)s->data;
    len = s->bytes;
  } else {
    const agc_list *values = agc_as_list(vm, args[1]);
    data = agc_byte_list(vm, values, LIMIT);
    len = agc_list_len(values);
    if (!data) return agc_error_value("network: bytes must be 0..255 and at most 1048576 per call");
  }
  int64_t timeout = agc_as_int(vm, args[2]);
  agc_socket *sk = agc_as_socket(vm, args[0]);
  agc_value result;
  if (!agc_stream_lock(vm, sk->writer, &timeout, &result)) return result;
  net *n = live(sk);
  if (!n) return agc_error_value(socket_closed);
  bool here = agc_io_here(vm);
  if (here) {
    /* At N = 1 the socket is this thread's: a send that goes out at once returns without a park. */
    int rc = send_now(n, data, len);
    if (rc < 0) return agc_system_error(vm, write_failed, agc_net_errno(rc));
    if (rc == 0) return ok_value(agc_void());
  }
  request *q = new_request(n, REQ_SEND);
  q->count = (size_t)agc_value_units(args[1]);
  if (!here) {
    q->sends = true;
    q->len = len;
    if (len) {
      q->data = malloc(len);
      if (!q->data) agc_out_of_memory();
      memcpy(q->data, data, len);
    }
  }
  park(vm, q, agc_handle_value(sk->writer), timeout, begin_send);
  return agc_void();
}

static agc_value builtin_send(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return write_op(vm, args, true);
}

static agc_value builtin_send_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return write_op(vm, args, false);
}

void agc_conn_observe(agc_conn *c, agc_conn_watch watch, void *watcher) {
  c->watch = watch;
  c->watcher = watcher;
}

bool agc_conn_clean_eof(const agc_conn *c) { return !c->secure || c->clean_eof; }

static void write_side_shut(uv_shutdown_t *req, int status) {
  (void)status;
  net *n = req->data;
  n->callbacks--;
  settle(n);
}

void agc_conn_half_close(agc_conn *c) {
  if (c->closed || c->half_closed || !c->conn || c->write_status < 0) return;
  c->half_closed = true;
  goodbye(c);
  c->shutdown.data = c;
  if (uv_shutdown(&c->shutdown, (uv_stream_t *)&c->conn->tcp, write_side_shut) == 0) c->callbacks++;
}

void agc_conn_release(agc_conn *c) {
  c->watch = NULL;
  c->users--;
  settle(c);
}

void agc_conn_retain(agc_conn *c) { c->users++; }

bool agc_conn_closed(const agc_conn *c) { return c->closed; }

void agc_net_close(agc_vm *vm, agc_resource *r, const char *why) { disown(vm, r, why); }

/* A TLS connection is returned before its handshake: the session is made
   here and the handshake runs on the first read or write, under that
   call's timeout, so a slow client never stalls the accept loop. */
agc_conn *agc_conn_accept(agc_conn *l) {
  if (l->closed) return NULL;
  tcp_link *k = l->conn;
  while (k && !k->backlog) k = k->next;
  if (!k) return NULL;
  int rc = 0;
  net *c = accept_link(l, k, &rc);
  if (!c) {
    AGC_TRACE(&l->trace, AGC_TRACE_IO, "tcp_accept_error listener=%" PRIu64 " error=%d", l->id, agc_net_errno(rc));
    return NULL;
  }
  /* The count that agc_conn_socket's resource then holds, taken here on the I/O thread. */
  c->users++;
  if (!l->secure) return c;
  c->secure = true;
  c->tls = agc_tls_server(l->config, &c->failure);
  c->tls_failed = c->tls == NULL;
  if (c->tls) {
    c->cipher = malloc(CIPHER_SIZE);
    if (!c->cipher) agc_out_of_memory();
  }
  AGC_TRACE(&l->trace, AGC_TRACE_TLS, "tls_handshake socket=0 listener=%" PRIu64 " role=server", l->id);
  return c;
}

agc_value agc_conn_socket(agc_vm *vm, agc_conn *c) {
  agc_socket *sk = new_socket(vm, c, false);
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "tcp_accept listener=%" PRIu64 " socket=%" PRIu64, c->parent, c->id);
  return agc_socket_value(sk);
}

const agc_builtin agc_tcp_builtins[] = {
  {"TCP.connect", 3, builtin_connect, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"TCP.listen", 2, builtin_listen, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"TCP.accept", 2, builtin_accept, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"TCP.local_port", 1, builtin_local_port, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"TCP.close_listener", 1, builtin_close_listener, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"TCP.close", 1, builtin_close, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"TCP.send", 3, builtin_send, AGC_NATIVE_NONE, AGC_COST_SIZE, true},
  {"TCP.send_bytes", 3, builtin_send_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, true},
  {"TCP.recv_bytes", 3, builtin_recv_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, true},
  {"TCP.read_line", 2, builtin_read_line, AGC_NATIVE_NONE, AGC_COST_SIZE, true},
  {"TLS.connect", 4, builtin_tls_connect, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"TLS.listen", 4, builtin_tls_listen, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"HttpWire.close_write", 1, builtin_close_write, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"HttpWire.read_text", 4, builtin_read_text, AGC_NATIVE_NONE, AGC_COST_SIZE, true},
  {"HttpWire.read_head", 4, builtin_read_head, AGC_NATIVE_NONE, AGC_COST_SIZE, true},
  {"HttpWire.read_response", 4, builtin_read_response, AGC_NATIVE_NONE, AGC_COST_SIZE, true},
  {"HttpWire.clean_eof?", 1, builtin_clean_eof, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"HttpWire.connect_tls", 4, builtin_connect_tls, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"HttpWire.drop_tls", 1, builtin_drop_tls, AGC_NATIVE_NONE, AGC_COST_NONE, true},
};

const size_t agc_tcp_builtin_count = sizeof agc_tcp_builtins / sizeof agc_tcp_builtins[0];
#else
const agc_builtin agc_tcp_builtins[] = {{"", 0, NULL, AGC_NATIVE_NONE, AGC_COST_NONE, false}};

const size_t agc_tcp_builtin_count = 0;
#endif
