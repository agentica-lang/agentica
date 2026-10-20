/* HttpWire.chunk rebuilds the chunked decoder from a record, so it checks
   every field first: a record std/http did not make (hand-made bytecode) fails
   the run with RUNTIME-INTERNAL instead of reaching the decoder. Also the
   input buffer's unread, which puts HttpWire.read_head's rest back. */
#include "../core.h"
#include "../services.h"

#include <assert.h>
#include <setjmp.h>
#include <string.h>

#if defined(__linux__) || defined(__APPLE__)
static agc_vm vm;

static const agc_builtin *find(const char *name) {
  for (size_t k = 0; k < agc_http_wire_builtin_count; k++)
    if (strcmp(agc_http_wire_builtins[k].name, name) == 0) return &agc_http_wire_builtins[k];
  assert(!"no such builtin");
  return NULL;
}

static agc_value bytes(const char *text) {
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
  agc_value args[3] = {state, bytes(data), agc_int(0)};
  return find("HttpWire.chunk")->fn(&vm, args, 0);
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

/* The one struct the calls need, as a program that uses HttpWire.chunk lists it. */
static const char *const chunk_fields[] = {"done",  "next",  "runs", "state",       "remaining", "size", "line",
                                           "block", "count", "name", "name_length", "total",     "limit"};

int main(void) {
  agc_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  agc_string *names[13];
  for (size_t k = 0; k < 13; k++) {
    size_t n = strlen(chunk_fields[k]);
    names[k] = agc_make_string(chunk_fields[k], n, n);
  }
  agc_struct_def structs[] = {{agc_make_string("HttpWire.Chunk", 14, 14), 13, names, NULL, NULL}};
  agc_program program;
  memset(&program, 0, sizeof program);
  program.struct_count = 1;
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
  return 0;
}
#else
int main(void) { return 0; }
#endif
