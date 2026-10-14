/* The HttpWire server builtins, called only by stdlib/http.agc: reading one
   whole request, writing one whole response, and the HttpServer task group
   (docs/vm/10-io-http.md §10.7.2). */
#include "http_fields.h"
#include "net.h"

#ifdef __linux__
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_BODY ((int64_t)64 * 1024 * 1024)
#define MAX_CONNECTIONS ((int64_t)65536)

typedef enum { R_FIRST, R_HEAD, R_BODY, R_ANSWER, R_DONE } phase;

typedef enum { F_NONE, F_EOF, F_CLOSED, F_TLS, F_READ, F_TRUNCATED, F_ANSWERED } failure;

typedef struct {
  int code;
  const char *reason;
} status_text;

typedef struct {
  agc_conn *conn;
  agc_io_job *job;
  phase at;
  failure failed;
  int code, sys;
  const char *problem;
  int64_t timeout_ms;
  uint64_t limit, heard_at;
  size_t seen, method_len;
  bool expect;
  agc_http_body body;
  agc_http_fields fields;
  agc_http_bytes line;
} reader;

typedef struct {
  agc_conn *conn;
  agc_io_job *job;
  bool close, delivered, done;
} writer;

typedef struct waiter waiter;

typedef struct {
  agc_conn *listener;
  size_t max, open, users;
  bool closed;
  waiter *waiters;
} server;

struct waiter {
  server *s;
  agc_io_job *job;
  waiter *next;
};

static const char socket_closed[] = "network: socket is closed";
static const char server_closed[] = "http: server is closed";
static const char go_on[] = "HTTP/1.1 100 Continue\r\n\r\n";
static const char *const request_fields[] = {"method", "target", "path", "headers", "body"};
static const char *const framing_headers[] = {"content-length", "transfer-encoding"};
static const char *const week_days[] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
static const char *const months[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
static const status_text status_texts[] = {
  {200, "OK"}, {201, "Created"}, {202, "Accepted"}, {204, "No Content"}, {206, "Partial Content"},
  {301, "Moved Permanently"}, {302, "Found"}, {303, "See Other"}, {304, "Not Modified"},
  {307, "Temporary Redirect"}, {308, "Permanent Redirect"}, {400, "Bad Request"}, {401, "Unauthorized"},
  {403, "Forbidden"}, {404, "Not Found"}, {405, "Method Not Allowed"}, {408, "Request Timeout"},
  {409, "Conflict"}, {410, "Gone"}, {413, "Content Too Large"}, {415, "Unsupported Media Type"},
  {417, "Expectation Failed"}, {422, "Unprocessable Content"}, {429, "Too Many Requests"},
  {431, "Request Header Fields Too Large"}, {500, "Internal Server Error"}, {501, "Not Implemented"},
  {502, "Bad Gateway"}, {503, "Service Unavailable"}, {504, "Gateway Timeout"},
  {505, "HTTP Version Not Supported"},
};

static const char *reason_of(int64_t code) {
  for (size_t k = 0; k < sizeof status_texts / sizeof status_texts[0]; k++)
    if (status_texts[k].code == code) return status_texts[k].reason;
  return "";
}

static void consume(agc_inbuf *in, size_t n) {
  in->start += n;
  in->scanned = 0;
}

static void free_reader(reader *r) {
  agc_conn_unobserve(r->conn, r);
  agc_conn_release(r->conn);
  agc_http_body_free(&r->body);
  agc_http_fields_free(&r->fields);
  free(r->line.data);
  free(r);
}

static void finish_read(reader *r, failure why) {
  if (r->at == R_DONE) return;
  r->at = R_DONE;
  r->failed = why;
  agc_conn_unobserve(r->conn, r);
  if (why == F_TLS || why == F_READ || why == F_TRUNCATED || why == F_ANSWERED)
    agc_conn_shut(r->conn, "http");
  else
    agc_conn_pause(r->conn);
  agc_io_ready(r->job);
}

/* A lingering close: once the last bytes are sent, the write side closes
   and input is read and dropped until the peer closes (or the caller's
   deadline), so unread request bytes cannot turn the close into a reset
   that loses the answer. True when it is over. */
static bool linger(agc_conn *c) {
  agc_inbuf *in = agc_conn_input(c);
  consume(in, agc_inbuf_pending(in));
  if (agc_conn_closed(c) || agc_conn_write_status(c) < 0) return true;
  if (!agc_conn_sent(c)) return false;
  agc_conn_half_close(c);
  agc_conn_read(c);
  return in->eof || in->error || agc_conn_failed(c);
}

static void answer_step(reader *r) {
  if (linger(r->conn)) finish_read(r, F_ANSWERED);
}

/* Error answers are security-critical bytes, so C writes them before the
   socket closes; the Agentica side only has to stop. */
static void answer(reader *r, int code, const char *problem) {
  char text[160];
  int len = snprintf(text, sizeof text, "HTTP/1.1 %d %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", code,
                     reason_of(code));
  r->at = R_ANSWER;
  r->code = code;
  r->problem = problem;
  (void)agc_conn_send(r->conn, (const uint8_t *)text, (size_t)len);
  answer_step(r);
}

static void protocol_error(reader *r, agc_http_error error) {
  answer(r, agc_http_error_code(error), agc_http_error_text(error));
}

static size_t count_named(const agc_http_head *head, const char *name, agc_http_slice *last) {
  size_t n = 0;
  for (size_t k = 0; k < head->count; k++) {
    if (!agc_http_named(head->fields[k].name, name)) continue;
    n++;
    *last = head->fields[k].value;
  }
  return n;
}

static void keep_line(reader *r, const agc_http_head *head) {
  agc_http_put(&r->line, head->method.data, head->method.len);
  agc_http_put(&r->line, head->target.data, head->target.len);
  r->method_len = head->method.len;
}

/* The order of docs/vm/10-io-http.md §10.7.3: head checks, then the
   Content-Length limit, then 100 Continue, then the body. */
static bool head_step(reader *r, agc_inbuf *in) {
  size_t pending = agc_inbuf_pending(in);
  if (pending == 0) return false;
  const uint8_t *data = in->data + in->start;
  if (pending <= AGC_HTTP_MAX_HEAD && !memchr(data + r->seen, '\n', pending - r->seen)) {
    r->seen = pending;
    return false;
  }
  agc_http_head head;
  size_t used;
  agc_http_error error;
  agc_http_status status = agc_http_parse_request_head(data, pending, &head, &used, &error);
  r->seen = pending;
  if (status == AGC_HTTP_INCOMPLETE) return false;
  if (status == AGC_HTTP_ERROR) {
    protocol_error(r, error);
    return false;
  }
  agc_http_slice value = {NULL, 0};
  if (count_named(&head, "upgrade", &value)) {
    answer(r, 501, "protocol upgrades are unsupported");
    return false;
  }
  size_t expects = count_named(&head, "expect", &value);
  if (expects > 1 || (expects == 1 && !agc_http_named(value, "100-continue"))) {
    answer(r, 417, "unsupported expectation");
    return false;
  }
  agc_http_body_init(&r->body, head.frame, head.length, r->limit);
  if (r->body.state == AGC_HTTP_BODY_FAILED) {
    protocol_error(r, r->body.error);
    return false;
  }
  agc_http_fields_keep(&r->fields, &head);
  keep_line(r, &head);
  consume(in, used);
  r->seen = 0;
  r->at = R_BODY;
  if (expects && r->body.state != AGC_HTTP_BODY_DONE && agc_inbuf_pending(in) == 0)
    (void)agc_conn_send(r->conn, (const uint8_t *)go_on, sizeof go_on - 1);
  return true;
}

static void body_step(reader *r, agc_inbuf *in) {
  size_t used = 0, pending = agc_inbuf_pending(in);
  agc_http_status status = agc_http_body_feed(&r->body, pending ? in->data + in->start : NULL, pending, &used);
  consume(in, used);
  if (status == AGC_HTTP_ERROR) {
    protocol_error(r, r->body.error);
  } else if (status == AGC_HTTP_OK) {
    size_t chars;
    if (agc_utf8_chars(r->body.data ? r->body.data : (const uint8_t *)"", r->body.len, &chars))
      finish_read(r, F_NONE);
    else
      answer(r, 400, "request body is not valid UTF-8");
  }
}

static void read_step(reader *r) {
  if (r->at == R_DONE) return;
  if (r->at == R_ANSWER) {
    answer_step(r);
    return;
  }
  agc_conn *c = r->conn;
  agc_inbuf *in = agc_conn_input(c);
  if (agc_conn_closed(c)) {
    finish_read(r, F_CLOSED);
    return;
  }
  if (agc_conn_failed(c)) {
    finish_read(r, F_TLS);
    return;
  }
  if (r->at == R_FIRST && agc_inbuf_pending(in) == 0 && agc_conn_heard(c) == r->heard_at) {
    if (in->error) r->sys = in->error;
    if (in->eof || in->error) finish_read(r, in->eof ? F_EOF : F_READ);
    return;
  }
  if (r->at == R_FIRST) {
    r->at = R_HEAD;
    agc_io_extend(r->job, r->timeout_ms);
  }
  while (r->at == R_HEAD && head_step(r, in)) {
  }
  if (r->at == R_BODY) body_step(r, in);
  if (r->at != R_HEAD && r->at != R_BODY) return;
  if (in->error) {
    r->sys = in->error;
    finish_read(r, F_READ);
  } else if (in->eof) {
    finish_read(r, r->at == R_HEAD && agc_inbuf_pending(in) == 0 ? F_EOF : F_TRUNCATED);
  }
}

static void read_watch(void *watcher) { read_step(watcher); }

static agc_value request_value(agc_vm *vm, const reader *r) {
  uint32_t type = agc_builtin_struct(vm, "HttpRequest", request_fields, 5);
  const char *line = (const char *)r->line.data;
  size_t target_len = r->line.len - r->method_len;
  const char *target = line + r->method_len;
  const char *query = memchr(target, '?', target_len);
  size_t path_len = query ? (size_t)(query - target) : target_len;
  agc_value headers = agc_http_header_list(vm, &r->fields);
  size_t chars = 0;
  const uint8_t *body = r->body.data ? r->body.data : (const uint8_t *)"";
  (void)agc_utf8_chars(body, r->body.len, &chars);
  agc_struct *q = agc_new_struct(type, 5);
  q->fields[0] = agc_string_value(agc_make_string(line, r->method_len, r->method_len));
  q->fields[1] = agc_string_value(agc_make_string(target, target_len, target_len));
  q->fields[2] = agc_string_value(agc_make_string(target, path_len, path_len));
  q->fields[3] = headers;
  q->fields[4] = agc_string_value(agc_make_string((const char *)body, r->body.len, chars));
  return agc_result_value(true, agc_struct_value(q));
}

static agc_value read_failure(agc_vm *vm, const reader *r) {
  switch (r->failed) {
    case F_EOF: return agc_error_value("network: end of input");
    case F_CLOSED: return agc_error_value(socket_closed);
    case F_TLS: return agc_conn_error(vm, r->conn);
    case F_READ: return agc_system_error(vm, "error reading from stream port", r->sys);
    case F_TRUNCATED: return agc_error_value("http: connection closed before the request was complete");
    default: return agc_http_error_result("http: ", r->problem);
  }
}

static agc_value read_done(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  reader *r = data;
  agc_value result = r->failed == F_NONE ? request_value(vm, r) : read_failure(vm, r);
  uint64_t cost = r->body.len / AGC_COST_BYTES + r->fields.count + agc_http_fields_bytes(&r->fields) / AGC_COST_BYTES;
  free_reader(r);
  agc_charge(vm, cost);
  return result;
}

static agc_value read_expired(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)context;
  reader *r = data;
  r->at = R_DONE;
  agc_conn_unobserve(r->conn, r);
  agc_conn_shut(r->conn, "timeout");
  return agc_stream_timed_out();
}

static void read_drop(void *data) { free_reader(data); }

static bool read_cancel(agc_vm *vm, void *data, agc_value context, bool deadline) {
  (void)vm;
  (void)context;
  (void)deadline;
  reader *r = data;
  r->at = R_DONE;
  agc_conn_unobserve(r->conn, r);
  agc_conn_pause(r->conn);
  return true;
}

static const agc_io_kind read_io = {NULL, read_done, read_expired, read_drop, true, "http_read", read_cancel};

static agc_conn *live_conn(const agc_socket *sk) {
  agc_conn *c = sk->state->native;
  return c && !agc_conn_closed(c) ? c : NULL;
}

static agc_value builtin_read_request(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_socket *sk = agc_as_socket(vm, args[0]);
  int64_t wait = agc_as_int(vm, args[1]), timeout = agc_as_int(vm, args[2]), limit = agc_as_int(vm, args[3]);
  if (timeout <= 0) return agc_stream_bad_timeout();
  if (limit <= 0 || limit > MAX_BODY) return agc_error_value("http: max_body_bytes must be 1..67108864");
  agc_value result;
  if (!agc_stream_lock(vm, sk->reader, &wait, &result)) return result;
  agc_conn *c = live_conn(sk);
  if (!c) return agc_error_value(socket_closed);
  reader *r = calloc(1, sizeof(reader));
  if (!r) agc_out_of_memory();
  r->conn = c;
  agc_conn_retain(c);
  r->timeout_ms = timeout;
  r->limit = (uint64_t)limit;
  r->heard_at = agc_conn_heard(c);
  r->job = agc_io_start(vm, &read_io, r, agc_handle_value(sk->reader), wait);
  agc_conn_observe(c, read_watch, r);
  agc_conn_read(c);
  read_step(r);
  return agc_void();
}

static bool has_named(agc_vm *vm, const agc_list *headers, const char *wanted) {
  for (size_t k = 0; k < headers->len; k++) {
    const agc_string *name = agc_as_string(vm, agc_as_struct(vm, headers->items[k])->fields[0]);
    if (agc_http_named((agc_http_slice){(const uint8_t *)name->data, name->bytes}, wanted)) return true;
  }
  return false;
}

static void put_date(agc_http_bytes *b) {
  time_t now = time(NULL);
  struct tm t;
  if (!gmtime_r(&now, &t)) return;
  char text[64];
  int len = snprintf(text, sizeof text, "Date: %s, %02d %s %04d %02d:%02d:%02d GMT\r\n", week_days[t.tm_wday % 7],
                     t.tm_mday, months[t.tm_mon % 12], t.tm_year + 1900, t.tm_hour, t.tm_min, t.tm_sec);
  if (len > 0 && (size_t)len < sizeof text) agc_http_put(b, text, (size_t)len);
}

static const char *build_response(agc_vm *vm, agc_http_bytes *b, const agc_struct *request,
                                  const agc_struct *response, bool *close) {
  if (request->n != 5 || response->n != 3) return "invalid response";
  int64_t status = agc_as_int(vm, response->fields[0]);
  const agc_list *headers = agc_as_list(vm, response->fields[1]);
  const agc_string *body = agc_as_string(vm, response->fields[2]);
  agc_http_slice method = agc_http_text(vm, request->fields[0]);
  bool head_only = method.len == 4 && memcmp(method.data, "HEAD", 4) == 0;
  *close = agc_http_list_closes(vm, agc_as_list(vm, request->fields[3])) || agc_http_list_closes(vm, headers);
  if (status < 200 || status > 599) return "the status must be 200..599";
  bool bodyless = status == 204 || status == 304;
  if (bodyless && body->bytes) return "a 204 or 304 response cannot have a body";
  char line[96];
  int len = snprintf(line, sizeof line, "HTTP/1.1 %" PRId64 " %s\r\n", status, reason_of(status));
  agc_http_put(b, line, (size_t)len);
  size_t count = 0;
  const char *bad = agc_http_put_headers(vm, b, headers, framing_headers, 2,
                                         "Content-Length and Transfer-Encoding are set by the server",
                                         *close ? "connection" : NULL, &count);
  if (bad) return bad;
  if (!has_named(vm, headers, "date")) put_date(b);
  if (!bodyless) {
    len = snprintf(line, sizeof line, "Content-Length: %zu\r\n", body->bytes);
    agc_http_put(b, line, (size_t)len);
  }
  if (*close) agc_http_put_text(b, "Connection: close\r\n");
  agc_http_put_text(b, "\r\n");
  if (!head_only && !bodyless) agc_http_put(b, body->data, body->bytes);
  return NULL;
}

static void free_writer(writer *w) {
  agc_conn_unobserve(w->conn, w);
  agc_conn_release(w->conn);
  free(w);
}

static bool fully_sent(const agc_conn *c) {
  return !agc_conn_closed(c) && agc_conn_write_status(c) >= 0 && agc_conn_sent(c);
}

static void write_watch(void *watcher) {
  writer *w = watcher;
  agc_conn *c = w->conn;
  if (w->done) return;
  if (!w->delivered) w->delivered = fully_sent(c);
  if (w->close ? !linger(c) : !(w->delivered || agc_conn_closed(c) || agc_conn_write_status(c) < 0)) return;
  w->done = true;
  agc_conn_unobserve(c, w);
  if (w->close) agc_conn_shut(c, "http");
  agc_io_ready(w->job);
}

static agc_value written(agc_vm *vm, const agc_conn *c) {
  if (agc_conn_closed(c)) return agc_error_value(socket_closed);
  return agc_system_error(vm, "error writing to stream port", -agc_conn_write_status(c));
}

static agc_value write_done(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  writer *w = data;
  agc_value result = w->delivered ? agc_result_value(true, agc_bool(!w->close)) : written(vm, w->conn);
  free_writer(w);
  return result;
}

static agc_value write_expired(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)context;
  writer *w = data;
  w->done = true;
  agc_conn_unobserve(w->conn, w);
  agc_conn_shut(w->conn, "timeout");
  return w->delivered ? agc_result_value(true, agc_bool(false)) : agc_stream_timed_out();
}

static void write_drop(void *data) { free_writer(data); }

static bool write_cancel(agc_vm *vm, void *data, agc_value context, bool deadline) {
  (void)vm;
  (void)context;
  (void)deadline;
  writer *w = data;
  w->done = true;
  agc_conn_unobserve(w->conn, w);
  return true;
}

static const agc_io_kind write_io = {NULL, write_done, write_expired, write_drop, true, "http_write", write_cancel};

static agc_value builtin_write_response(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_socket *sk = agc_as_socket(vm, args[0]);
  const agc_struct *request = agc_as_struct(vm, args[1]);
  const agc_struct *response = agc_as_struct(vm, args[2]);
  int64_t timeout = agc_as_int(vm, args[3]);
  if (timeout <= 0) return agc_stream_bad_timeout();
  agc_http_bytes out = {0};
  bool close = false;
  const char *bad = build_response(vm, &out, request, response, &close);
  if (bad) {
    free(out.data);
    return agc_http_error_result("http: invalid response: ", bad);
  }
  agc_value result;
  if (!agc_stream_lock(vm, sk->writer, &timeout, &result)) {
    free(out.data);
    return result;
  }
  agc_charge(vm, out.len / AGC_COST_BYTES);
  agc_conn *c = live_conn(sk);
  int rc = c ? agc_conn_send(c, out.data, out.len) : 0;
  free(out.data);
  if (!c) return agc_error_value(socket_closed);
  if (rc < 0) return agc_system_error(vm, "error writing to stream port", -rc);
  if (!close && fully_sent(c)) return agc_result_value(true, agc_bool(true));
  writer *w = calloc(1, sizeof(writer));
  if (!w) agc_out_of_memory();
  w->conn = c;
  w->close = close;
  agc_conn_retain(c);
  w->job = agc_io_start(vm, &write_io, w, agc_handle_value(sk->writer), timeout);
  agc_conn_observe(c, write_watch, w);
  write_watch(w);
  return agc_void();
}

static void settle(server *s) {
  if (!s->users) free(s);
}

static void poke(const server *s) {
  for (const waiter *w = s->waiters; w; w = w->next) agc_io_ready(w->job);
}

static void listener_watch(void *watcher) { poke(watcher); }

static void free_waiter(waiter *w) {
  server *s = w->s;
  for (waiter **at = &s->waiters; *at; at = &(*at)->next) {
    if (*at != w) continue;
    *at = w->next;
    break;
  }
  free(w);
  s->users--;
  settle(s);
}

static agc_value waited(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)context;
  free_waiter(data);
  return agc_void();
}

static void waiter_drop(void *data) { free_waiter(data); }

static bool waiter_cancel(agc_vm *vm, void *data, agc_value context, bool deadline) {
  (void)vm;
  (void)data;
  (void)context;
  (void)deadline;
  return true;
}

static const agc_io_kind wait_io = {NULL, waited, waited, waiter_drop, true, "http_server", waiter_cancel};

/* accept and wait are retry builtins: the job only wakes the task, which
   then checks the server again. */
static void park(agc_vm *vm, server *s) {
  waiter *w = calloc(1, sizeof(waiter));
  if (!w) agc_out_of_memory();
  w->s = s;
  w->next = s->waiters;
  s->waiters = w;
  s->users++;
  w->job = agc_io_start(vm, &wait_io, w, agc_void(), -1);
  vm->task->retry = true;
}

static void release_server(void *native) {
  server *s = native;
  s->closed = true;
  if (s->listener) agc_conn_release(s->listener);
  s->listener = NULL;
  s->users--;
  settle(s);
}

static void shut_server(agc_vm *vm, agc_http_server *hs) {
  agc_resource *r = hs->state;
  server *s = r->native;
  if (s) {
    r->native = NULL;
    agc_unregister(vm, r);
    AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "http_close server=%" PRIu64 " open=%zu", r->id, s->open);
    poke(s);
    release_server(s);
  }
  agc_net_close(vm, agc_as_listener(vm, hs->listener)->state, "close");
  agc_task_cancel(vm, hs->group);
}

static void close_owned(agc_vm *vm, agc_resource *r, agc_task *ender) {
  (void)ender;
  shut_server(vm, agc_as_http_server(vm, r->context));
}

static server *open_server(const agc_http_server *hs) {
  server *s = hs->state->native;
  if (!s || s->closed || !s->listener || agc_conn_closed(s->listener) || hs->group->state == AGC_TASK_DONE) return NULL;
  return s;
}

static agc_value builtin_server(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_listener *lv = agc_as_listener(vm, args[0]);
  int64_t max = agc_as_int(vm, args[1]);
  server *s = calloc(1, sizeof(server));
  if (!s) agc_out_of_memory();
  s->max = (size_t)(max < 1 ? 1 : max > MAX_CONNECTIONS ? MAX_CONNECTIONS : max);
  s->users = 1;
  agc_conn *l = lv->state->native;
  if (l && !agc_conn_closed(l)) {
    s->listener = l;
    agc_conn_retain(l);
    agc_conn_observe(l, listener_watch, s);
  }
  agc_http_server *hs = agc_alloc(sizeof(agc_http_server));
  hs->listener = args[0];
  hs->group = agc_task_group(vm);
  hs->state = agc_register(vm, s, release_server);
  hs->state->context = agc_http_server_value(hs);
  agc_own(vm, hs->state, close_owned);
  agc_disown(lv->state);
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "http_server server=%" PRIu64 " listener=%" PRIu64 " max=%zu", hs->state->id,
            lv->state->id, s->max);
  agc_value value = agc_http_server_value(hs);
  (void)agc_task_spawn_seeded(vm, hs->group, args[2], &value, 1, span);
  return value;
}

static agc_value builtin_accept(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_http_server *hs = agc_as_http_server(vm, args[0]);
  server *s = open_server(hs);
  if (!s) return agc_error_value(server_closed);
  if (s->open < s->max) {
    agc_conn *c = agc_conn_accept(s->listener);
    if (c) {
      s->open++;
      return agc_result_value(true, agc_conn_socket(vm, c));
    }
  }
  park(vm, s);
  return agc_void();
}

static void give_back(const agc_http_server *hs) {
  server *s = hs->state->native;
  if (!s) return;
  if (s->open) s->open--;
  poke(s);
}

static void connection_ended(agc_vm *vm, agc_task *t) {
  (void)vm;
  const agc_http_server *hs = t->end_data;
  t->end_data = NULL;
  give_back(hs);
}

static agc_value builtin_spawn(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_http_server *hs = agc_as_http_server(vm, args[0]);
  agc_socket *sk = agc_as_socket(vm, args[1]);
  server *s = open_server(hs);
  if (!s) {
    agc_net_close(vm, sk->state, "close");
    s = hs->state->native;
    if (s && s->open) s->open--;
    return agc_void();
  }
  if (!agc_task_owns(vm, args[1])) give_back(hs);
  agc_task *child = agc_task_spawn_owning(vm, hs->group, args[2], args[1], span);
  child->hidden = true;
  child->end_data = hs;
  child->end = connection_ended;
  return agc_void();
}

static agc_value builtin_close_server(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  shut_server(vm, agc_as_http_server(vm, args[0]));
  return agc_void();
}

static agc_value builtin_wait(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  server *s = agc_as_http_server(vm, args[0])->state->native;
  if (!s || s->closed) return agc_result_value(true, agc_void());
  park(vm, s);
  return agc_void();
}

static agc_value builtin_local_port(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int(agc_as_listener(vm, agc_as_http_server(vm, args[0])->listener)->port);
}

const agc_builtin agc_http_server_builtins[] = {
  {"HttpWire.read_request", 4, builtin_read_request, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"HttpWire.write_response", 4, builtin_write_response, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"HttpWire.server", 3, builtin_server, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"HttpWire.accept", 1, builtin_accept, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"HttpWire.spawn", 3, builtin_spawn, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"HttpWire.close_server", 1, builtin_close_server, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"HttpWire.wait", 1, builtin_wait, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"HttpWire.local_port", 1, builtin_local_port, AGC_NATIVE_NONE, AGC_COST_NONE},
};

const size_t agc_http_server_builtin_count = sizeof agc_http_server_builtins / sizeof agc_http_server_builtins[0];
#else
const agc_builtin agc_http_server_builtins[] = {{"", 0, NULL, AGC_NATIVE_NONE, AGC_COST_NONE}};

const size_t agc_http_server_builtin_count = 0;
#endif
