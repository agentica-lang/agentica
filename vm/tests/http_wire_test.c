/* HttpWire.chunk checks every field of its record first: one std/http did
   not make (hand-made bytecode) fails with RUNTIME-INTERNAL. Also the input
   buffer's unread (read_head's rest), the answers of HttpWire.chunk on Bytes,
   and a List given to a byte row. */
#include "builtin_test.h"
#include "../http_fields.h"
#include "../services.h"

#include <assert.h>
#include <setjmp.h>
#include <string.h>

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
static agc_vm vm;

static const agc_builtin *find(const char *name) {
  for (size_t k = 0; k < agc_http_wire_builtin_count; k++)
    if (strcmp(agc_http_wire_builtins[k].name, name) == 0) return &agc_http_wire_builtins[k];
  assert(!"no such builtin");
  return NULL;
}

static agc_value as_bytes(const char *data) {
  return agc_bytes_value(agc_make_bytes((const uint8_t *)data, strlen(data)));
}

/* The bytes of text as a List[Int], which no byte row takes. */
static agc_value byte_list(const char *text) {
  size_t n = strlen(text);
  agc_list_builder out;
  agc_list_builder_sized(&out, n);
  for (size_t k = 0; k < n; k++) agc_list_builder_push(&out, agc_int((uint8_t)text[k]));
  return agc_list_value(agc_list_builder_finish(&out));
}

static agc_value text(const char *s) { return agc_string_value(agc_make_string(s, strlen(s), strlen(s))); }

static agc_value fresh(void) {
  agc_value limit = agc_int(1024);
  return find("HttpWire.chunked")->fn(&vm, &limit, 0);
}

/* fresh() with one field replaced. */
static agc_value with(uint32_t field, agc_value v) {
  const agc_struct *c = agc_as_struct(&vm, fresh());
  agc_struct *d = agc_new_struct(c->type, c->n);
  memcpy(d->fields, c->fields, c->n * sizeof c->fields[0]);
  d->fields[field] = v;
  return agc_struct_value(d);
}

static agc_value chunk(agc_value state, const char *data) {
  agc_value args[3] = {state, as_bytes(data), agc_int(0)};
  return find("HttpWire.chunk.bytes")->fn(&vm, args, 0);
}

static void refused(agc_value state) {
  if (setjmp(vm.fail) == 0) {
    (void)chunk(state, "1\r\na\r\n0\r\n\r\n");
    assert(!"a hand-made Chunk reached the decoder");
  }
  assert(strcmp(vm.outcome->code, "RUNTIME-INTERNAL") == 0);
}

static void fill(agc_inbuf *b, const char *text) {
  size_t n = strlen(text);
  uint8_t *room = agc_inbuf_room(b, n);
  assert(room);
  memcpy(room, text, n);
  agc_inbuf_got(b, (int64_t)n, false);
}

static void pending_is(const agc_inbuf *b, const char *text) {
  assert(agc_inbuf_pending(b) == strlen(text) && memcmp(b->data + b->start, text, strlen(text)) == 0);
}

/* agc_inbuf_unread (HttpWire.read_head's rest) puts bytes before the pending
   ones: in the room before start when there is enough, else by moving the
   pending bytes up. */
static void test_unread(void) {
  agc_inbuf b = {0};
  fill(&b, "xxABCD");
  agc_inbuf_take(&b, 2);
  assert(agc_inbuf_unread(&b, (const uint8_t *)"yz", 2));
  pending_is(&b, "yzABCD");
  agc_inbuf_take(&b, 3);
  assert(agc_inbuf_unread(&b, (const uint8_t *)"12345", 5));
  pending_is(&b, "12345BCD");
  assert(agc_inbuf_unread(&b, NULL, 0));
  pending_is(&b, "12345BCD");
  agc_inbuf_take(&b, 8);
  assert(agc_inbuf_unread(&b, (const uint8_t *)"next", 4));
  pending_is(&b, "next");
  agc_inbuf_free(&b);
}

static const agc_builtin *row(const char *name, uint32_t arity) {
  return agc_find_builtin((const uint8_t *)name, strlen(name), arity);
}

static void fails(const char *name, uint32_t arity, agc_value *args) {
  agc_test_fails(&vm, name, row(name, arity), args, "RUNTIME-INTERNAL");
}

static agc_value call(const char *name, uint32_t arity, agc_value *args) { return row(name, arity)->fn(&vm, args, 0); }

/* HttpWire.chunk reads Bytes where they are: two chunks whose body splits a character. A List given to a byte row is a
   wrong tag; the TCP, HttpWire and Process rows check it before the handle. */
static void test_byte_keys(void) {
  const char *framed = "3\r\nab\xC3\r\n2\r\n\xB1z\r\n0\r\n\r\n";
  agc_value args[3] = {fresh(), as_bytes(framed), agc_int(0)};
  const agc_result *r = agc_as_result(&vm, call("HttpWire.chunk.bytes", 3, args));
  assert(r->ok);
  const agc_struct *state = agc_as_struct(&vm, r->value);
  assert(agc_as_bool(&vm, state->fields[0]));
  const agc_list *found = agc_as_list(&vm, state->fields[2]);
  assert(agc_list_len(found) == 4 && agc_as_int(&vm, agc_list_get(found, 0)) == 3 &&
         agc_as_int(&vm, agc_list_get(found, 2)) == 11);
  agc_value list = byte_list("ab");
  agc_value chunk_list[3] = {fresh(), list, agc_int(0)};
  fails("HttpWire.chunk.bytes", 3, chunk_list);
  agc_value sends[3] = {agc_void(), list, agc_int(1000)};
  fails("TCP.send_bytes.bytes", 3, sends);
  fails("Process.send_bytes.bytes", 3, sends);
  agc_value head[4] = {agc_void(), list, agc_int(1024), agc_int(1000)};
  fails("HttpWire.read_head.bytes", 4, head);
}

/* The status a request head is refused with, 0 when it is let through (HttpWire.Head.status). Only a GET with one
   Upgrade header whose value is the token "websocket" is let through: std/http hands it to a route that upgrades and
   answers 501 on every other route. */
static int64_t head_status(const char *head) {
  const agc_result *r = agc_as_result(&vm, agc_http_head_value(&vm, (const uint8_t *)head, strlen(head), 1024, 0));
  assert(r->ok);
  return agc_as_int(&vm, agc_as_struct(&vm, r->value)->fields[8]);
}

static void test_upgrade(void) {
  assert(head_status("GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n") == 0);
  assert(head_status("GET / HTTP/1.1\r\nHost: x\r\nUpgrade: WebSocket\r\nConnection: upgrade\r\n\r\n") == 0);
  assert(head_status("GET / HTTP/1.1\r\nHost: x\r\nUpgrade: h2c\r\n\r\n") == 501);
  assert(head_status("GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket, h2c\r\n\r\n") == 501);
  assert(head_status("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nUpgrade: websocket\r\n\r\n") == 501);
  assert(head_status("GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nUpgrade: websocket\r\n\r\n") == 501);
  assert(head_status("GET / HTTP/1.1\r\nHost: x\r\n\r\n") == 0);
}

/* The structs the calls need, as a program that uses HttpWire.chunk lists them. */
static const char *const chunk_fields[] = {"done",  "next",  "runs", "state",       "remaining", "size", "line",
                                           "block", "count", "name", "name_length", "total",     "limit"};

static agc_string **field_names(const char *const *fields, size_t n) {
  agc_string **names = agc_alloc(n * sizeof *names);
  for (size_t k = 0; k < n; k++) names[k] = agc_make_string(fields[k], strlen(fields[k]), strlen(fields[k]));
  return names;
}

static const char *const head_fields[] = {"method",          "target",   "path",   "headers", "length", "chunked",
                                          "expect_continue", "buffered", "status", "reason"};
static const char *const header_fields[] = {"name", "value"};

int main(void) {
  agc_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  agc_struct_def structs[] = {{agc_make_string("HttpWire.Chunk", 14, 14), 13, field_names(chunk_fields, 13), NULL,
                               NULL},
                              {agc_make_string("HttpWire.Head", 13, 13), 10, field_names(head_fields, 10), NULL, NULL},
                              {agc_make_string("Header", 6, 6), 2, field_names(header_fields, 2), NULL, NULL}};
  agc_program program;
  memset(&program, 0, sizeof program);
  program.struct_count = 3;
  program.structs = structs;
  vm.rt->program = &program;
  const agc_result *r = agc_as_result(&vm, chunk(fresh(), "1\r\na\r\n0\r\n\r\n"));
  assert(r->ok && agc_as_bool(&vm, agc_as_struct(&vm, r->value)->fields[0]));
  refused(with(3, agc_int(0)));
  refused(with(9, text("abcdefghijklmnopqrstuvwxyz0123")));
  refused(with(10, agc_int(30)));
  refused(with(11, agc_int(2000)));
  refused(with(12, agc_int(0)));
  test_unread();
  test_byte_keys();
  test_upgrade();
  return 0;
}
#else
int main(void) { return 0; }
#endif
