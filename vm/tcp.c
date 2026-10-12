#include "agc.h"

#ifdef __linux__
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

#define LIMIT ((size_t)1048576)
#define BACKLOG 128
#define BIND_TRIES 8
#define PORT_TEXT 8
#define NET(ptr, field) ((net *)(void *)((char *)(ptr) - offsetof(net, field)))
#define LINK(ptr, field) ((link *)(void *)((char *)(ptr) - offsetof(link, field)))

typedef enum { REQ_CONNECT, REQ_LISTEN, REQ_ACCEPT, REQ_LINE, REQ_BYTES, REQ_SEND } req_kind;

typedef struct net net;
typedef struct link link;
typedef struct request request;

struct link {
  uv_tcp_t tcp;
  uv_connect_t connect;
  net *owner;
  link *next;
  bool backlog;
};

struct request {
  req_kind kind;
  net *n;
  agc_io_job *job;
  request *next;
  size_t count;
  int error;
  bool served;
};

struct net {
  agc_trace trace;
  uv_loop_t *loop;
  uv_getaddrinfo_t dns;
  uv_write_t write_req;
  link *link, *chosen;
  struct addrinfo *addrs, *next_addr;
  char *host;
  int64_t port;
  uint64_t id;
  size_t users, callbacks;
  bool listener, resolving, resolved, connected, closed, reading;
  int error, write_status;
  uint8_t *write_data;
  agc_inbuf in;
  request *opener, *reader, *writer, *accepts, *accepts_tail;
};

static const char socket_closed[] = "network: socket is closed";
static const char listener_closed[] = "network: listener is closed";
static const char write_failed[] = "error writing to stream port";

static agc_value ok_value(agc_value v) { return agc_result_value(true, v); }

static void settle(net *n) {
  if (n->users || n->callbacks) return;
  uv_freeaddrinfo(n->addrs);
  agc_inbuf_free(&n->in);
  free(n->write_data);
  free(n->host);
  free(n);
}

static void link_closed(uv_handle_t *h) {
  link *k = LINK(h, tcp);
  net *n = k->owner;
  free(k);
  n->callbacks--;
  settle(n);
}

static void drop_link(link *k) {
  if (!uv_is_closing((uv_handle_t *)&k->tcp)) uv_close((uv_handle_t *)&k->tcp, link_closed);
}

static link *new_link(net *n) {
  link *k = calloc(1, sizeof(link));
  if (!k) agc_out_of_memory();
  k->owner = n;
  uv_tcp_init(n->loop, &k->tcp);
  n->callbacks++;
  return k;
}

static void ready(const request *q) {
  if (q && q->job) agc_io_ready(q->job);
}

static const char *kind_name(const net *n) { return n->listener ? "listener" : "socket"; }

static void drop_links(net *n) {
  for (link *k = n->link, *next; k; k = next) {
    next = k->next;
    drop_link(k);
  }
  n->link = n->chosen = NULL;
}

static void shut(net *n, const char *why) {
  if (n->closed) return;
  n->closed = true;
  AGC_TRACE(&n->trace, AGC_TRACE_IO, "tcp_close %s=%" PRIu64 " why=%s", kind_name(n), n->id, why);
  if (n->resolving) uv_cancel((uv_req_t *)&n->dns);
  drop_links(n);
  n->reading = false;
  agc_inbuf_free(&n->in);
  ready(n->opener);
  ready(n->reader);
  ready(n->writer);
  for (const request *q = n->accepts; q; q = q->next) ready(q);
}

static void release_net(void *native) {
  net *n = native;
  shut(n, "exit");
  n->users--;
  settle(n);
}

static net *new_net(agc_vm *vm, char *host, int64_t port, bool listener) {
  net *n = calloc(1, sizeof(net));
  if (!n) agc_out_of_memory();
  n->trace = vm->rt->trace;
  n->loop = agc_io_uv(vm);
  n->host = host;
  n->port = port;
  n->listener = listener;
  return n;
}

static agc_resource *own(agc_vm *vm, net *n) {
  agc_resource *r = agc_register(vm, n, release_net);
  n->users++;
  n->id = r->id;
  return r;
}

static void disown(agc_vm *vm, agc_resource *r, const char *why) {
  net *n = r->native;
  if (!n) return;
  r->native = NULL;
  agc_unregister(vm, r);
  shut(n, why);
  n->users--;
  settle(n);
}

static request *new_request(net *n, req_kind kind) {
  request *q = calloc(1, sizeof(request));
  if (!q) agc_out_of_memory();
  q->kind = kind;
  q->n = n;
  n->users++;
  return q;
}

static void unlink_request(request *q) {
  net *n = q->n;
  if (n->opener == q) n->opener = NULL;
  if (n->reader == q) n->reader = NULL;
  if (n->writer == q) n->writer = NULL;
  request *previous = NULL;
  for (request *k = n->accepts; k; previous = k, k = k->next) {
    if (k != q) continue;
    if (previous)
      previous->next = k->next;
    else
      n->accepts = k->next;
    if (n->accepts_tail == k) n->accepts_tail = previous;
    break;
  }
  q->next = NULL;
}

static void drop_request(void *data) {
  request *q = data;
  net *n = q->n;
  unlink_request(q);
  if (q->served) n->chosen = NULL;
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
  if (err > UV_EAI_ADDRFAMILY) return agc_system_error(vm, head, -err);
  const char *reason = uv_strerror(err);
  size_t total = agc_size_add((size_t)len, strlen(reason) + 20);
  char *text = agc_alloc_atomic(total);
  int full = snprintf(text, total, "%s\n  system error: %s", head, reason);
  size_t n_text = full < 0 ? 0 : (size_t)full;
  return agc_result_value(false, agc_string_value(agc_utf8_decode((const uint8_t *)text, n_text, "?", true)));
}

static agc_value open_error(agc_vm *vm, const net *n) {
  bool found = n->resolved;
  if (n->listener) return net_error(vm, n, found ? "tcp-listen: listen failed" : "tcp-listen: host not found", n->error);
  return net_error(vm, n, found ? "tcp-connect: connection failed" : "tcp-connect: host not found", n->error);
}

static void read_port(net *n, const link *k) {
  struct sockaddr_storage address;
  int len = sizeof address;
  if (uv_tcp_getsockname(&k->tcp, (struct sockaddr *)&address, &len)) return;
  if (address.ss_family == AF_INET) n->port = ntohs(((const struct sockaddr_in *)&address)->sin_port);
  if (address.ss_family == AF_INET6) n->port = ntohs(((const struct sockaddr_in6 *)&address)->sin6_port);
}

static request *next_accept(net *n) {
  request *q = n->accepts;
  if (!q) return NULL;
  n->accepts = q->next;
  if (!n->accepts) n->accepts_tail = NULL;
  q->next = NULL;
  return q;
}

static void serve(net *n) {
  if (n->chosen || !n->accepts) return;
  link *k = n->link;
  while (k && !k->backlog) k = k->next;
  if (!k) return;
  request *q = next_accept(n);
  q->served = true;
  n->chosen = k;
  ready(q);
}

static void incoming(uv_stream_t *server, int status) {
  link *k = LINK(server, tcp);
  net *n = k->owner;
  if (status < 0) {
    AGC_TRACE(&n->trace, AGC_TRACE_IO, "tcp_accept_error listener=%" PRIu64 " error=%d", n->id, -status);
    request *q = next_accept(n);
    if (q) q->error = status;
    ready(q);
    return;
  }
  k->backlog = true;
  serve(n);
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
  link *k = new_link(n);
  int rc = uv_tcp_bind(&k->tcp, (const struct sockaddr *)&address, flags);
  if (!rc) rc = uv_listen((uv_stream_t *)&k->tcp, BACKLOG, incoming);
  if (rc) {
    drop_link(k);
    return rc;
  }
  k->next = n->link;
  n->link = k;
  return 0;
}

static int bind_from(net *n, const struct addrinfo *first, bool *bound) {
  *bound = false;
  int rc = listen_on(n, first, -1);
  if (rc) return rc;
  *bound = true;
  read_port(n, n->link);
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
      for (const link *k = n->link; k; k = k->next) count++;
      AGC_TRACE(&n->trace, AGC_TRACE_IO, "tcp_listen listener=%" PRIu64 " host=%s port=%" PRId64 " addresses=%zu", n->id,
                n->host, n->port, count);
      ready(n->opener);
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
  ready(n->opener);
}

static void attempt(net *n, uv_connect_cb done) {
  while (n->next_addr) {
    const struct addrinfo *a = n->next_addr;
    n->next_addr = a->ai_next;
    link *k = new_link(n);
    int rc = uv_tcp_connect(&k->connect, &k->tcp, a->ai_addr, done);
    if (!rc) {
      n->link = k;
      return;
    }
    n->error = rc;
    drop_link(k);
  }
  ready(n->opener);
}

static void connected(uv_connect_t *req, int status) {
  link *k = LINK(req, connect);
  net *n = k->owner;
  if (n->closed) return;
  if (status == 0) {
    n->connected = true;
    uv_tcp_nodelay(&k->tcp, 1);
    AGC_TRACE(&n->trace, AGC_TRACE_IO, "tcp_connected socket=%" PRIu64, n->id);
    ready(n->opener);
    return;
  }
  AGC_TRACE(&n->trace, AGC_TRACE_IO, "tcp_connect_error socket=%" PRIu64 " error=%d", n->id, -status);
  n->error = status;
  n->link = NULL;
  drop_link(k);
  attempt(n, connected);
}

static void resolved(uv_getaddrinfo_t *req, int status, struct addrinfo *res) {
  net *n = NET(req, dns);
  n->resolving = false;
  n->callbacks--;
  n->addrs = res;
  if (n->closed || !n->opener) {
    settle(n);
    return;
  }
  if (status < 0) {
    n->error = status;
    ready(n->opener);
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

static agc_value take(agc_vm *vm, net *n, req_kind kind, size_t count) {
  if (n->closed) return agc_error_value(socket_closed);
  if (kind == REQ_BYTES) return agc_inbuf_bytes(vm, &n->in, count);
  bool over;
  agc_value line = agc_inbuf_line(vm, &n->in, "network: line exceeds 1048576 bytes", "network: end of input", &over);
  if (over) shut(n, "line");
  return line;
}

static agc_socket *new_socket(agc_vm *vm, net *n) {
  agc_socket *sk = agc_alloc(sizeof(agc_socket));
  sk->state = own(vm, n);
  sk->reader = agc_new_lock(vm);
  sk->writer = agc_new_lock(vm);
  return sk;
}

static agc_value accept_done(agc_vm *vm, request *q, net *l) {
  if (l->closed) return agc_error_value(listener_closed);
  if (q->error) return agc_system_error(vm, "tcp-accept: accept failed", -q->error);
  if (!q->served) return agc_error_value(listener_closed);
  q->served = false;
  link *from = l->chosen;
  l->chosen = NULL;
  from->backlog = false;
  net *c = new_net(vm, NULL, 0, false);
  link *k = new_link(c);
  int rc = uv_accept((uv_stream_t *)&from->tcp, (uv_stream_t *)&k->tcp);
  if (rc) {
    drop_link(k);
    agc_value failed = agc_system_error(vm, "tcp-accept: accept failed", -rc);
    shut(l, "accept");
    return failed;
  }
  serve(l);
  c->link = k;
  c->connected = true;
  uv_tcp_nodelay(&k->tcp, 1);
  agc_socket *sk = new_socket(vm, c);
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "tcp_accept listener=%" PRIu64 " socket=%" PRIu64, l->id, c->id);
  return ok_value(agc_socket_value(sk));
}

static agc_value opened(agc_vm *vm, const request *q, agc_value context) {
  net *n = q->n;
  if (n->link && !n->closed && (n->listener || n->connected)) {
    if (!n->listener) return ok_value(context);
    agc_listener *lv = agc_as_listener(vm, context);
    lv->port = n->port;
    return ok_value(context);
  }
  agc_value result = open_error(vm, n);
  disown(vm, n->listener ? agc_as_listener(vm, context)->state : agc_as_socket(vm, context)->state, "failed");
  return result;
}

static agc_value request_done(agc_vm *vm, void *data, agc_value context) {
  request *q = data;
  net *n = q->n;
  unlink_request(q);
  if (q->kind == REQ_SEND) agc_charge(vm, q->count);
  agc_value result;
  if (q->kind == REQ_CONNECT || q->kind == REQ_LISTEN) {
    result = opened(vm, q, context);
  } else if (q->kind == REQ_ACCEPT) {
    result = accept_done(vm, q, n);
  } else if (q->kind == REQ_LINE || q->kind == REQ_BYTES) {
    result = take(vm, n, q->kind, q->count);
    agc_charge(vm, agc_value_units(result));
  } else if (n->closed) {
    result = agc_error_value(socket_closed);
  } else {
    result = n->write_status < 0 ? agc_system_error(vm, write_failed, -n->write_status) : ok_value(agc_void());
  }
  drop_request(q);
  return result;
}

static agc_value request_expired(agc_vm *vm, void *data, agc_value context) {
  request *q = data;
  unlink_request(q);
  if (q->kind == REQ_CONNECT) disown(vm, agc_as_socket(vm, context)->state, "timeout");
  if (q->kind == REQ_LINE || q->kind == REQ_BYTES || q->kind == REQ_SEND) shut(q->n, "timeout");
  return agc_stream_timed_out();
}

static const agc_io_kind tcp_io = {NULL, request_done, request_expired, drop_request, true, "tcp"};

static request *park(agc_vm *vm, net *n, req_kind kind, agc_value context, int64_t timeout) {
  request *q = new_request(n, kind);
  if (kind == REQ_LINE || kind == REQ_BYTES) {
    n->reader = q;
  } else if (kind == REQ_SEND) {
    n->writer = q;
  } else if (kind != REQ_ACCEPT) {
    n->opener = q;
  } else if (n->accepts_tail) {
    n->accepts_tail->next = q;
    n->accepts_tail = q;
  } else {
    n->accepts = n->accepts_tail = q;
  }
  q->job = agc_io_start(vm, &tcp_io, q, context, timeout);
  return q;
}

static void no_network(agc_vm *vm, uint32_t span) {
  if (vm->rt->no_files) agc_fail(vm, "RUNTIME-INTERNAL", "network access is off in this run", span);
}

static agc_value start_open(agc_vm *vm, net *n, agc_resource *state, agc_value value, int64_t timeout) {
  int rc = resolve(n);
  if (rc) {
    n->error = rc;
    agc_value result = open_error(vm, n);
    disown(vm, state, "failed");
    return result;
  }
  park(vm, n, n->listener ? REQ_LISTEN : REQ_CONNECT, value, timeout);
  return agc_void();
}

static agc_value builtin_connect(agc_vm *vm, agc_value *args, uint32_t span) {
  no_network(vm, span);
  const agc_string *host = agc_as_string(vm, args[0]);
  int64_t port = agc_as_int(vm, args[1]);
  int64_t timeout = agc_as_int(vm, args[2]);
  if (timeout <= 0) return agc_stream_bad_timeout();
  if (port < 1 || port > 65535) return agc_error_value("network: port must be 1..65535");
  char *name = agc_cstr(host);
  if (!name) return agc_error_value("network: host cannot contain NUL");
  net *n = new_net(vm, name, port, false);
  agc_socket *sk = new_socket(vm, n);
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "tcp_connect socket=%" PRIu64 " host=%s port=%" PRId64, n->id, name, port);
  return start_open(vm, n, sk->state, agc_socket_value(sk), timeout);
}

static agc_value builtin_listen(agc_vm *vm, agc_value *args, uint32_t span) {
  no_network(vm, span);
  const agc_string *host = agc_as_string(vm, args[0]);
  int64_t port = agc_as_int(vm, args[1]);
  if (port < 0 || port > 65535) return agc_error_value("network: port must be 0..65535");
  char *name = agc_cstr(host);
  if (!name) return agc_error_value("network: host cannot contain NUL");
  net *n = new_net(vm, name, port, true);
  agc_listener *lv = agc_alloc(sizeof(agc_listener));
  lv->state = own(vm, n);
  lv->port = port;
  return start_open(vm, n, lv->state, agc_listener_value(lv), -1);
}

static agc_value builtin_accept(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  net *n = agc_as_listener(vm, args[0])->state->native;
  int64_t timeout = agc_as_int(vm, args[1]);
  if (!n || n->closed) return agc_error_value(listener_closed);
  if (timeout <= 0) return agc_stream_bad_timeout();
  park(vm, n, REQ_ACCEPT, args[0], timeout);
  serve(n);
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

static void stop_reading(net *n) {
  if (!n->reading) return;
  uv_read_stop((uv_stream_t *)&n->link->tcp);
  n->reading = false;
}

static void alloc_in(uv_handle_t *h, size_t suggested, uv_buf_t *buf) {
  (void)suggested;
  net *n = LINK(h, tcp)->owner;
  const request *q = n->reader;
  size_t size = agc_inbuf_want(&n->in, !q || q->kind != REQ_BYTES, q ? q->count : 0);
  uint8_t *room = agc_inbuf_room(&n->in, size);
  *buf = room ? uv_buf_init((char *)room, (unsigned)size) : uv_buf_init(NULL, 0);
}

static bool read_ready(net *n, req_kind kind) {
  return n->closed || agc_inbuf_ready(&n->in, kind == REQ_LINE, 1);
}

static void read_in(uv_stream_t *s, ssize_t got, const uv_buf_t *buf) {
  (void)buf;
  net *n = LINK(s, tcp)->owner;
  agc_inbuf_got(&n->in, got, got == UV_EOF);
  if (got < 0)
    AGC_TRACE(&n->trace, AGC_TRACE_IO, "tcp_eof socket=%" PRIu64 " error=%d", n->id, got == UV_EOF ? 0 : (int)-got);
  const request *q = n->reader;
  bool done = q && read_ready(n, q->kind);
  if (got < 0 || !q || done) stop_reading(n);
  if (done) ready(q);
}

static void start_reading(net *n) {
  if (n->reading || n->in.eof || n->in.error) return;
  int rc = uv_read_start((uv_stream_t *)&n->link->tcp, alloc_in, read_in);
  if (rc)
    n->in.error = -rc;
  else
    n->reading = true;
}

static agc_value read_op(agc_vm *vm, const agc_value *args, req_kind kind) {
  size_t count = 0;
  if (kind == REQ_BYTES) {
    int64_t wanted = agc_as_int(vm, args[1]);
    if (wanted < 1 || (uint64_t)wanted > LIMIT) return agc_error_value("network: read size must be 1..1048576");
    count = (size_t)wanted;
  }
  int64_t timeout = agc_as_int(vm, args[kind == REQ_BYTES ? 2 : 1]);
  agc_socket *sk = agc_as_socket(vm, args[0]);
  agc_value result;
  if (!agc_stream_lock(vm, sk->reader, &timeout, &result)) return result;
  net *n = live(sk);
  if (!n) return agc_error_value(socket_closed);
  if (read_ready(n, kind)) return take(vm, n, kind, count);
  request *q = park(vm, n, kind, agc_handle_value(sk->reader), timeout);
  q->count = count;
  start_reading(n);
  if (read_ready(n, kind)) ready(q);
  return agc_void();
}

static agc_value builtin_read_line(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return read_op(vm, args, REQ_LINE);
}

static agc_value builtin_recv_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return read_op(vm, args, REQ_BYTES);
}

static void wrote(uv_write_t *w, int status) {
  net *n = NET(w, write_req);
  free(n->write_data);
  n->write_data = NULL;
  n->write_status = status;
  ready(n->writer);
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
    len = values->len;
    if (!data) return agc_error_value("network: bytes must be 0..255 and at most 1048576 per call");
  }
  int64_t timeout = agc_as_int(vm, args[2]);
  agc_socket *sk = agc_as_socket(vm, args[0]);
  agc_value result;
  if (!agc_stream_lock(vm, sk->writer, &timeout, &result)) return result;
  net *n = live(sk);
  if (!n) return agc_error_value(socket_closed);
  n->write_status = 0;
  int rc = agc_stream_write((uv_stream_t *)&n->link->tcp, &n->write_req, &n->write_data, data, len, wrote);
  if (rc < 0) return agc_system_error(vm, write_failed, -rc);
  if (rc == 0) return ok_value(agc_void());
  park(vm, n, REQ_SEND, agc_handle_value(sk->writer), timeout)->count = (size_t)agc_value_units(args[1]);
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

const agc_builtin agc_tcp_builtins[] = {
  {"TCP.connect", 3, builtin_connect, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"TCP.listen", 2, builtin_listen, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"TCP.accept", 2, builtin_accept, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"TCP.local_port", 1, builtin_local_port, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"TCP.close_listener", 1, builtin_close_listener, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"TCP.close", 1, builtin_close, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"TCP.send", 3, builtin_send, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"TCP.send_bytes", 3, builtin_send_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"TCP.recv_bytes", 3, builtin_recv_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"TCP.read_line", 2, builtin_read_line, AGC_NATIVE_NONE, AGC_COST_SIZE},
};

const size_t agc_tcp_builtin_count = sizeof agc_tcp_builtins / sizeof agc_tcp_builtins[0];
#else
const agc_builtin agc_tcp_builtins[] = {{"", 0, NULL, AGC_NATIVE_NONE, AGC_COST_NONE}};

const size_t agc_tcp_builtin_count = 0;
#endif
