/*
 * The pure HttpWire builtins that std/http reads and writes HTTP with: the
 * request head, the chunked framing, body text, response heads and error
 * answers. No I/O and no state: std/http owns the socket, its buffer and the
 * deadlines, and passes the bytes it read as a List[Int]. Each function works
 * with several schedulers. Linux and macOS, like the TCP builtins std/http
 * needs; a stub table elsewhere. Service layer. Design:
 * docs/vm/10-io-http.md §10.7.
 */
#include "http_fields.h"

#if defined(__linux__) || defined(__APPLE__)
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_BODY ((int64_t)64 * 1024 * 1024)

typedef struct {
  int code;
  const char *reason;
} status_text;

static const char *const head_fields[] = {"method",          "target",   "path",   "headers", "length", "chunked",
                                          "expect_continue", "buffered", "status", "reason"};
static const char *const chunk_fields[] = {"done", "next",  "runs", "state",       "remaining", "size", "line",
                                           "block", "count", "name", "name_length", "total",     "limit"};
static const char *const text_fields[] = {"text", "carry", "bytes", "valid"};
static const char *const reply_fields[] = {"head", "closes"};
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

/* Only std/http calls these builtins, with values it made itself, so a bad
   argument means hand-made bytecode: it fails the run instead of being an
   error result. */
_Noreturn static void misuse(agc_vm *vm, const char *what, uint32_t span) {
  agc_fail(vm, "RUNTIME-INTERNAL", what, span);
}

/* The error result std/http turns into an answer: "NNN reason". */
static agc_value status_error(int code, const char *reason) {
  size_t size = strlen(reason) + 8;
  char *text = agc_alloc_atomic(size);
  snprintf(text, size, "%d %s", code, reason);
  return agc_error_value(text);
}

static agc_value parse_error(agc_http_error error) {
  return status_error(agc_http_error_code(error), agc_http_error_text(error));
}

static bool range_ok(int64_t from, int64_t count, size_t len) {
  return from >= 0 && count >= 0 && (uint64_t)from <= len && (uint64_t)count <= len - (size_t)from;
}

/* Copies data[from, from + n) into out; false when an item is not a byte. */
static bool copy_bytes(agc_vm *vm, const agc_list *data, size_t from, size_t n, uint8_t *out) {
  agc_list_cursor cursor;
  agc_value item;
  agc_list_cursor_begin(&cursor, data, from);
  for (size_t k = 0; k < n && agc_list_cursor_next(&cursor, &item); k++) {
    int64_t b = agc_as_int(vm, item);
    if (b < 0 || b > 255) return false;
    out[k] = (uint8_t)b;
  }
  return true;
}

static agc_value byte_list(const uint8_t *data, size_t n) {
  agc_list_builder out;
  agc_list_builder_sized(&out, n);
  for (size_t k = 0; k < n; k++) agc_list_builder_push(&out, agc_int(data[k]));
  return agc_list_value(agc_list_builder_finish(&out));
}

static agc_value empty_list(void) {
  agc_list_builder out;
  agc_list_builder_sized(&out, 0);
  return agc_list_value(agc_list_builder_finish(&out));
}

static agc_value ascii(const uint8_t *data, size_t n) {
  return agc_string_value(agc_make_string((const char *)data, n, n));
}

int64_t agc_http_max_body(agc_vm *vm, agc_value v, uint32_t span) {
  int64_t limit = agc_as_int(vm, v);
  if (limit < 1 || limit > MAX_BODY) misuse(vm, "HttpWire: max_body_bytes must be 1..67108864", span);
  return limit;
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

static agc_struct *head_record(agc_vm *vm) {
  return agc_new_struct(agc_builtin_struct(vm, "HttpWire.Head", head_fields, 10), 10);
}

/* A head refused with this answer status and reason; the other fields are
   empty. */
static agc_value refused_head(agc_vm *vm, int code, const char *reason) {
  agc_struct *h = head_record(vm);
  agc_value empty = ascii((const uint8_t *)"", 0);
  h->fields[0] = h->fields[1] = h->fields[2] = empty;
  h->fields[3] = empty_list();
  h->fields[4] = h->fields[7] = agc_int(0);
  h->fields[5] = h->fields[6] = agc_bool(false);
  h->fields[8] = agc_int(code);
  h->fields[9] = ascii((const uint8_t *)reason, strlen(reason));
  return agc_result_value(true, agc_struct_value(h));
}

/* The HttpWire.Head of the request head at the start of buf, with the checks
   of docs/vm/10-io-http.md §10.7.3 in their order: the parse errors, Upgrade,
   Expect, then a Content-Length over the limit; a refused head has the answer's
   status and reason. A head still incomplete means the input ended or failed before its end.
   buffered is the count of input bytes after the head. */
agc_value agc_http_head_value(agc_vm *vm, const uint8_t *buf, size_t len, uint64_t limit, size_t buffered) {
  agc_http_head head;
  size_t used;
  agc_http_error error;
  agc_http_status status = agc_http_parse_request_head(buf, len, &head, &used, &error);
  if (status == AGC_HTTP_INCOMPLETE) return agc_error_value("http: connection closed before the request was complete");
  if (status == AGC_HTTP_ERROR) return refused_head(vm, agc_http_error_code(error), agc_http_error_text(error));
  agc_http_slice value = {NULL, 0};
  if (count_named(&head, "upgrade", &value)) return refused_head(vm, 501, "protocol upgrades are unsupported");
  size_t expects = count_named(&head, "expect", &value);
  if (expects > 1 || (expects == 1 && !agc_http_named(value, "100-continue")))
    return refused_head(vm, 417, "unsupported expectation");
  bool chunked = head.frame == AGC_HTTP_FRAME_CHUNKED;
  if (!chunked && head.length > limit)
    return refused_head(vm, agc_http_error_code(AGC_HTTP_ERR_TOO_LARGE), agc_http_error_text(AGC_HTTP_ERR_TOO_LARGE));
  agc_http_fields fields = {0};
  agc_http_fields_keep(&fields, &head);
  agc_value headers = agc_http_header_list(vm, &fields);
  agc_charge(vm, fields.count + agc_http_fields_bytes(&fields) / AGC_COST_BYTES);
  agc_http_fields_free(&fields);
  const uint8_t *query = memchr(head.target.data, '?', head.target.len);
  size_t path_len = query ? (size_t)(query - head.target.data) : head.target.len;
  agc_struct *h = head_record(vm);
  h->fields[0] = ascii(head.method.data, head.method.len);
  h->fields[1] = ascii(head.target.data, head.target.len);
  h->fields[2] = ascii(head.target.data, path_len);
  h->fields[3] = headers;
  h->fields[4] = agc_int(chunked ? 0 : (int64_t)head.length);
  h->fields[5] = agc_bool(chunked);
  h->fields[6] = agc_bool(expects == 1);
  h->fields[7] = agc_int((int64_t)(len - used + buffered));
  h->fields[8] = agc_int(0);
  h->fields[9] = ascii((const uint8_t *)"", 0);
  return agc_result_value(true, agc_struct_value(h));
}

static agc_struct *chunk_record(agc_vm *vm) {
  return agc_new_struct(agc_builtin_struct(vm, "HttpWire.Chunk", chunk_fields, 13), 13);
}

static void store_body(agc_struct *c, const agc_http_body *b) {
  c->fields[3] = agc_int(b->state);
  c->fields[4] = agc_int((int64_t)b->remaining);
  /* A size past INT64_MAX is over every limit, as UINT64_MAX is. */
  c->fields[5] = agc_int(b->size > INT64_MAX ? INT64_MAX : (int64_t)b->size);
  c->fields[6] = agc_int((int64_t)b->line);
  c->fields[7] = agc_int((int64_t)b->block);
  c->fields[8] = agc_int((int64_t)b->count);
  size_t kept = b->name_len < sizeof b->name ? b->name_len : sizeof b->name;
  c->fields[9] = ascii((const uint8_t *)b->name, kept);
  c->fields[10] = agc_int((int64_t)b->name_len);
  c->fields[11] = agc_int((int64_t)b->len);
  c->fields[12] = agc_int((int64_t)b->limit);
}

/* A state with no runs, between reads of the socket. */
static agc_value between_reads(agc_vm *vm, const agc_http_body *b) {
  agc_struct *c = chunk_record(vm);
  c->fields[0] = agc_bool(false);
  c->fields[1] = agc_int(0);
  c->fields[2] = empty_list();
  store_body(c, b);
  return agc_struct_value(c);
}

static agc_value builtin_chunked(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_http_body b;
  agc_http_body_init(&b, AGC_HTTP_FRAME_CHUNKED, 0, (uint64_t)agc_http_max_body(vm, args[0], span));
  return between_reads(vm, &b);
}

static int64_t field_int(agc_vm *vm, const agc_struct *c, uint32_t k, int64_t low, int64_t high, uint32_t span) {
  int64_t v = agc_as_int(vm, c->fields[k]);
  if (v < low || v > high) misuse(vm, "HttpWire.chunk: invalid state", span);
  return v;
}

/* Rebuilds the decoder from a record that chunked or chunk made. Every field
   is checked, since a hand-made record must not reach the decoder. */
static void load_body(agc_vm *vm, agc_value v, agc_http_body *b, uint32_t span) {
  const agc_struct *c = agc_as_struct(vm, v);
  if (c->type != agc_builtin_struct(vm, "HttpWire.Chunk", chunk_fields, 13) || c->n != 13)
    misuse(vm, "HttpWire.chunk: invalid state", span);
  agc_http_body_init(b, AGC_HTTP_FRAME_CHUNKED, 0, (uint64_t)field_int(vm, c, 12, 1, MAX_BODY, span));
  b->discard = true;
  b->state = (agc_http_body_state)field_int(vm, c, 3, AGC_HTTP_BODY_DATA, AGC_HTTP_BODY_DONE, span);
  b->remaining = (uint64_t)field_int(vm, c, 4, 0, MAX_BODY, span);
  b->size = (uint64_t)field_int(vm, c, 5, 0, INT64_MAX, span);
  b->line = (size_t)field_int(vm, c, 6, 0, (int64_t)AGC_HTTP_MAX_LINE, span);
  b->block = (size_t)field_int(vm, c, 7, 0, (int64_t)AGC_HTTP_MAX_BLOCK, span);
  b->count = (size_t)field_int(vm, c, 8, 0, (int64_t)AGC_HTTP_MAX_HEADERS, span);
  b->len = (size_t)field_int(vm, c, 11, 0, (int64_t)b->limit, span);
  const agc_string *name = agc_as_string(vm, c->fields[9]);
  b->name_len = (size_t)field_int(vm, c, 10, (int64_t)name->bytes, (int64_t)AGC_HTTP_MAX_LINE, span);
  if (name->bytes > sizeof b->name || (b->name_len > name->bytes && name->bytes < sizeof b->name))
    misuse(vm, "HttpWire.chunk: invalid state", span);
  if (name->bytes) memcpy(b->name, name->data, name->bytes);
  if (b->state == AGC_HTTP_BODY_DATA) misuse(vm, "HttpWire.chunk: invalid state", span);
}

/* HttpWire.chunk(state, data, from): decodes data[from..] until the body ends
   or the bytes run out. runs lists each piece of body as start, length. */
static agc_value builtin_chunk(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_http_body b;
  load_body(vm, args[0], &b, span);
  const agc_list *data = agc_as_list(vm, args[1]);
  int64_t from = agc_as_int(vm, args[2]);
  size_t len = agc_list_len(data);
  if (!range_ok(from, 0, len)) misuse(vm, "HttpWire.chunk: from is out of range", span);
  size_t n = len - (size_t)from;
  uint8_t *buf = agc_alloc_atomic(n ? n : 1);
  if (!copy_bytes(vm, data, (size_t)from, n, buf)) misuse(vm, "HttpWire.chunk: data must be bytes", span);
  /* Each run takes at least one byte of chunk data plus its framing, so n
     runs is a bound; the list builder needs its exact size up front. */
  int64_t *runs = agc_alloc_atomic(agc_size_mul(n ? n : 1, 2 * sizeof *runs));
  size_t at = 0, found = 0;
  agc_http_status status = AGC_HTTP_INCOMPLETE;
  while (at < n && status == AGC_HTTP_INCOMPLETE) {
    size_t used, start, count;
    status = agc_http_body_step(&b, buf + at, n - at, &used, &start, &count);
    if (count) {
      runs[found++] = from + (int64_t)(at + start);
      runs[found++] = (int64_t)count;
    }
    at += used;
  }
  agc_charge(vm, n / AGC_COST_BYTES);
  if (status == AGC_HTTP_ERROR) return parse_error(b.error);
  agc_list_builder list;
  agc_list_builder_sized(&list, found);
  for (size_t k = 0; k < found; k++) agc_list_builder_push(&list, agc_int(runs[k]));
  agc_struct *c = chunk_record(vm);
  c->fields[0] = agc_bool(status == AGC_HTTP_OK);
  c->fields[1] = agc_int(from + (int64_t)at);
  c->fields[2] = agc_list_value(agc_list_builder_finish(&list));
  store_body(c, &b);
  return agc_result_value(true, agc_struct_value(c));
}

/* HttpWire.chunk_read(state, bytes): the state after std read bytes of chunk
   data itself, straight from the socket. bytes must be 1..remaining. */
static agc_value builtin_chunk_read(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_http_body b;
  load_body(vm, args[0], &b, span);
  int64_t bytes = agc_as_int(vm, args[1]);
  if (b.state != AGC_HTTP_BODY_CHUNK || bytes < 1 || (uint64_t)bytes > b.remaining)
    misuse(vm, "HttpWire.chunk_read: bytes must be 1 to remaining", span);
  agc_http_body_skip(&b, (size_t)bytes);
  return between_reads(vm, &b);
}

/* The length of the longest prefix of s that does not end inside a UTF-8
   sequence. Bytes that can never be valid stay in it, so the decoding fails. */
static size_t whole_prefix(const uint8_t *s, size_t len) {
  for (size_t back = 1; back <= 3 && back <= len; back++) {
    uint8_t c = s[len - back];
    if ((c & 0xC0) == 0x80) continue;
    /* 0xC0, 0xC1 and 0xF5..0xFF never start a valid sequence: kept in the
       prefix, they fail the decoding at once. */
    return c >= 0xC2 && c <= 0xF4 && agc_utf8_width(c) > back ? len - back : len;
  }
  return len;
}

/* The HttpWire.Text of buf: valid is false, with empty text, when buf is not
   UTF-8 up to an unfinished last character. */
agc_value agc_http_text_value(agc_vm *vm, const uint8_t *buf, size_t len, size_t bytes) {
  size_t whole = whole_prefix(buf, len), chars;
  bool valid = agc_utf8_chars(buf, whole, &chars);
  agc_struct *t = agc_new_struct(agc_builtin_struct(vm, "HttpWire.Text", text_fields, 4), 4);
  t->fields[0] = valid ? agc_string_value(agc_make_string((const char *)buf, whole, chars))
                       : agc_string_value(agc_make_string("", 0, 0));
  t->fields[1] = valid ? byte_list(buf + whole, len - whole) : empty_list();
  t->fields[2] = agc_int((int64_t)bytes);
  t->fields[3] = agc_bool(valid);
  return agc_struct_value(t);
}

/* HttpWire.text(carry, data, runs): the text of carry followed by the runs of
   data (start, length pairs). */
static agc_value builtin_text(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_list *carry = agc_as_list(vm, args[0]);
  const agc_list *data = agc_as_list(vm, args[1]);
  const agc_list *runs = agc_as_list(vm, args[2]);
  size_t pairs = agc_list_len(runs), kept = agc_list_len(carry), len = agc_list_len(data);
  if (pairs % 2 || kept > 3) misuse(vm, "HttpWire.text: invalid runs", span);
  size_t total = kept;
  for (size_t k = 0; k < pairs; k += 2) {
    int64_t from = agc_as_int(vm, agc_list_get(runs, k)), count = agc_as_int(vm, agc_list_get(runs, k + 1));
    if (!range_ok(from, count, len)) misuse(vm, "HttpWire.text: invalid runs", span);
    total = agc_size_add(total, (size_t)count);
  }
  uint8_t *buf = agc_alloc_atomic(total ? total : 1);
  if (!copy_bytes(vm, carry, 0, kept, buf)) misuse(vm, "HttpWire.text: data must be bytes", span);
  size_t at = kept;
  for (size_t k = 0; k < pairs; k += 2) {
    size_t from = (size_t)agc_as_int(vm, agc_list_get(runs, k));
    size_t count = (size_t)agc_as_int(vm, agc_list_get(runs, k + 1));
    if (!copy_bytes(vm, data, from, count, buf + at)) misuse(vm, "HttpWire.text: data must be bytes", span);
    at += count;
  }
  agc_charge(vm, total / AGC_COST_BYTES);
  return agc_http_text_value(vm, buf, total, total - kept);
}

static bool has_named(agc_vm *vm, const agc_list *headers, const char *wanted) {
  agc_list_cursor cursor;
  agc_value item;
  agc_list_cursor_begin(&cursor, headers, 0);
  while (agc_list_cursor_next(&cursor, &item))
    if (agc_http_named(agc_http_text(vm, agc_as_struct(vm, item)->fields[0]), wanted)) return true;
  return false;
}

static void put_date(agc_http_bytes *b, int64_t now_ms) {
  time_t now = (time_t)(now_ms / 1000);
  struct tm t;
  if (!gmtime_r(&now, &t)) return;
  char text[64];
  int len = snprintf(text, sizeof text, "Date: %s, %02d %s %04d %02d:%02d:%02d GMT\r\n", week_days[t.tm_wday % 7],
                     t.tm_mday, months[t.tm_mon % 12], t.tm_year + 1900, t.tm_hour, t.tm_min, t.tm_sec);
  if (len > 0 && (size_t)len < sizeof text) agc_http_put(b, text, (size_t)len);
}

/* The head of the response to request: the body itself is std/http's to send,
   and only when the method is not HEAD (a 204 or 304 body is refused here). */
static const char *response_head(agc_vm *vm, agc_http_bytes *b, const agc_struct *request,
                                 const agc_struct *response, int64_t now_ms, bool *closes) {
  if (request->n != 5 || response->n != 3) return "invalid response";
  int64_t status = agc_as_int(vm, response->fields[0]);
  const agc_list *headers = agc_as_list(vm, response->fields[1]);
  const agc_string *body = agc_as_string(vm, response->fields[2]);
  bool close = agc_http_list_closes(vm, agc_as_list(vm, request->fields[3])) || agc_http_list_closes(vm, headers);
  *closes = close;
  if (status < 200 || status > 599) return "the status must be 200..599";
  bool bodyless = status == 204 || status == 304;
  if (bodyless && body->bytes) return "a 204 or 304 response cannot have a body";
  char line[96];
  int len = snprintf(line, sizeof line, "HTTP/1.1 %" PRId64 " %s\r\n", status, reason_of(status));
  agc_http_put(b, line, (size_t)len);
  size_t count = 0;
  const char *bad = agc_http_put_headers(vm, b, headers, framing_headers, 2,
                                         "Content-Length and Transfer-Encoding are set by the server",
                                         close ? "connection" : NULL, &count);
  if (bad) return bad;
  if (!has_named(vm, headers, "date")) put_date(b, now_ms);
  if (!bodyless) {
    len = snprintf(line, sizeof line, "Content-Length: %zu\r\n", body->bytes);
    agc_http_put(b, line, (size_t)len);
  }
  if (close) agc_http_put_text(b, "Connection: close\r\n");
  agc_http_put_text(b, "\r\n");
  return NULL;
}

/* HttpWire.encode_response: the head bytes, and whether the connection closes
   after this response (either side said Connection: close). */
static agc_value builtin_encode_response(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_http_bytes out = {0};
  bool closes = false;
  const char *bad = response_head(vm, &out, agc_as_struct(vm, args[0]), agc_as_struct(vm, args[1]),
                                  agc_as_int(vm, args[2]), &closes);
  agc_value result = agc_void();
  if (bad) {
    result = agc_error_value(bad);
  } else {
    agc_struct *r = agc_new_struct(agc_builtin_struct(vm, "HttpWire.Reply", reply_fields, 2), 2);
    r->fields[0] = byte_list(out.data, out.len);
    r->fields[1] = agc_bool(closes);
    result = agc_result_value(true, agc_struct_value(r));
  }
  agc_charge(vm, out.len / AGC_COST_BYTES);
  free(out.data);
  return result;
}

static agc_value builtin_error_answer(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t code = agc_as_int(vm, args[0]);
  if (code < 100 || code > 599) misuse(vm, "HttpWire.error_answer: the status must be 100..599", span);
  char text[160];
  int len = snprintf(text, sizeof text, "HTTP/1.1 %" PRId64 " %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                     code, reason_of(code));
  return ascii((const uint8_t *)text, (size_t)len);
}

const agc_builtin agc_http_wire_builtins[] = {
  {"HttpWire.chunked", 1, builtin_chunked, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"HttpWire.chunk", 3, builtin_chunk, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"HttpWire.chunk_read", 2, builtin_chunk_read, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"HttpWire.text", 3, builtin_text, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"HttpWire.encode_response", 3, builtin_encode_response, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"HttpWire.error_answer", 1, builtin_error_answer, AGC_NATIVE_NONE, AGC_COST_NONE, false},
};

const size_t agc_http_wire_builtin_count = sizeof agc_http_wire_builtins / sizeof agc_http_wire_builtins[0];
#else
const agc_builtin agc_http_wire_builtins[] = {{"", 0, NULL, AGC_NATIVE_NONE, AGC_COST_NONE, false}};

const size_t agc_http_wire_builtin_count = 0;
#endif
