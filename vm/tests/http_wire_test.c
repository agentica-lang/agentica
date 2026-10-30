/* HttpWire.chunk checks every field of its record first: one std/http did
   not make (hand-made bytecode) fails with RUNTIME-INTERNAL. Also the input
   buffer's unread (read_head's rest), the answers of HttpWire.chunk and
   HttpWire.text on Bytes, and a List given to a byte row. */
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

static void bytes_is(agc_value v, const char *data, size_t n) {
  const agc_bytes *b = agc_as_bytes(&vm, v);
  assert(b->len == n && (n == 0 || memcmp(b->data, data, n) == 0));
}

static const agc_builtin *row(const char *name, uint32_t arity) {
  return agc_find_builtin((const uint8_t *)name, strlen(name), arity);
}

static void fails(const char *name, uint32_t arity, agc_value *args) {
  agc_test_fails(&vm, name, row(name, arity), args, "RUNTIME-INTERNAL");
}

static agc_value call(const char *name, uint32_t arity, agc_value *args) { return row(name, arity)->fn(&vm, args, 0); }

/* The text record: its text, the carry and validity. */
static void text_is(agc_value record, const char *text_, const char *carry, bool valid) {
  const agc_struct *t = agc_as_struct(&vm, record);
  const agc_string *got = agc_as_string(&vm, t->fields[0]);
  assert(got->bytes == strlen(text_) && memcmp(got->data, text_, got->bytes) == 0);
  bytes_is(t->fields[1], carry, strlen(carry));
  assert(agc_as_bool(&vm, t->fields[3]) == valid);
}

/* HttpWire.chunk and HttpWire.text read Bytes where they are: two chunks whose text splits a character, then the
   text with the carry. A List given to a byte row is a wrong tag; the TCP, HttpWire and Process rows check it before
   the handle. */
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
  /* The runs of the first chunk, then of the second one with the end of its first character still unread. */
  agc_value runs[2] = {agc_int(3), agc_int(3)};
  agc_value text_args[3] = {as_bytes(""), as_bytes(framed), agc_list_value(agc_list_from_array(runs, 2))};
  text_is(call("HttpWire.text.bytes", 3, text_args), "ab", "\xC3", true);
  runs[0] = agc_int(11);
  runs[1] = agc_int(2);
  text_args[0] = as_bytes("\xC3");
  text_args[2] = agc_list_value(agc_list_from_array(runs, 2));
  text_is(call("HttpWire.text.bytes", 3, text_args), "\xC3\xB1z", "", true);
  /* Not UTF-8: no text and no carry. */
  text_args[0] = as_bytes("\xFF");
  text_is(call("HttpWire.text.bytes", 3, text_args), "", "", false);
  agc_value list = byte_list("ab");
  agc_value chunk_list[3] = {fresh(), list, agc_int(0)};
  fails("HttpWire.chunk.bytes", 3, chunk_list);
  agc_value text_list[3] = {list, as_bytes(""), agc_list_value(agc_list_from_array(NULL, 0))};
  fails("HttpWire.text.bytes", 3, text_list);
  agc_value sends[3] = {agc_void(), list, agc_int(1000)};
  fails("TCP.send_bytes.bytes", 3, sends);
  fails("Process.send_bytes.bytes", 3, sends);
  agc_value head[4] = {agc_void(), list, agc_int(1024), agc_int(1000)};
  fails("HttpWire.read_head.bytes", 4, head);
  agc_value reads[4] = {agc_void(), agc_int(10), list, agc_int(1000)};
  fails("HttpWire.read_text.bytes", 4, reads);
}

/* The structs the calls need, as a program that uses HttpWire.chunk and HttpWire.text lists them. */
static const char *const chunk_fields[] = {"done",  "next",  "runs", "state",       "remaining", "size", "line",
                                           "block", "count", "name", "name_length", "total",     "limit"};
static const char *const text_fields[] = {"text", "carry", "bytes", "valid", "buffered", "ended"};

static agc_string **field_names(const char *const *fields, size_t n) {
  agc_string **names = agc_alloc(n * sizeof *names);
  for (size_t k = 0; k < n; k++) names[k] = agc_make_string(fields[k], strlen(fields[k]), strlen(fields[k]));
  return names;
}

int main(void) {
  agc_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  agc_struct_def structs[] = {{agc_make_string("HttpWire.Chunk", 14, 14), 13, field_names(chunk_fields, 13), NULL, NULL},
                              {agc_make_string("HttpWire.Text", 13, 13), 6, field_names(text_fields, 6), NULL, NULL}};
  agc_program program;
  memset(&program, 0, sizeof program);
  program.struct_count = 2;
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
  return 0;
}
#else
int main(void) { return 0; }
#endif
