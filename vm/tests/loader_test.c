#include "../agc.h"

#include <assert.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  uint8_t data[4096];
  size_t len;
} buffer;

typedef struct {
  const char *magic;
  uint32_t version;
  const char *agentica;
  uint32_t span_line;
  uint32_t registers;
  const agc_instr *code;
  const uint32_t *spans;
  uint32_t count;
} spec;

static void u8(buffer *b, uint8_t v) { b->data[b->len++] = v; }
static void u16(buffer *b, uint16_t v) {
  u8(b, (uint8_t)v);
  u8(b, (uint8_t)(v >> 8));
}
static void u32(buffer *b, uint32_t v) {
  u16(b, (uint16_t)v);
  u16(b, (uint16_t)(v >> 16));
}
static void str(buffer *b, const char *s) {
  u32(b, (uint32_t)strlen(s));
  memcpy(b->data + b->len, s, strlen(s));
  b->len += strlen(s);
}

static const agc_instr puts_code[] = {
  {AGC_OP_STEP, 2, 0, 0},
  {AGC_OP_CONST, 0, 0, 0},
  {AGC_OP_CALL_BUILTIN, 0, 0, 0},
  {AGC_OP_CONST, 0, 1, 0},
  {AGC_OP_RETURN, 0, 0, 0},
};
static const uint32_t puts_spans[] = {1, 2, 1, 0, 0};

static spec base(void) {
  spec s = {"AGCB", AGC_FORMAT_VERSION, AGC_VERSION, 2, 1, puts_code, puts_spans, 5};
  return s;
}

static void build(buffer *b, spec s) {
  b->len = 0;
  memcpy(b->data, s.magic, 4);
  b->len = 4;
  u32(b, s.version);
  str(b, s.agentica);
  u32(b, 1);
  str(b, "t.agc");
  str(b, "def main() -> Void\n  puts(1)\nend\n");
  u32(b, 3);
  uint32_t spans[3][5] = {{0, 1, 1, 4, 1}, {0, s.span_line, 3, 2, 10}, {0, 2, 8, 2, 9}};
  for (int i = 0; i < 3; i++)
    for (int k = 0; k < 5; k++) u32(b, spans[i][k]);
  u32(b, 2);
  u8(b, 4);
  u32(b, 1);
  u32(b, 0);
  u8(b, 0);
  u32(b, 0);
  u32(b, 0);
  u32(b, 0);
  u32(b, 1);
  str(b, "puts");
  u32(b, 1);
  u32(b, 1);
  str(b, "main");
  u32(b, 0);
  u32(b, 0);
  u32(b, s.registers);
  u32(b, 0);
  u32(b, s.count);
  for (uint32_t i = 0; i < s.count; i++) {
    u16(b, s.code[i].op);
    u16(b, s.code[i].a);
    u16(b, s.code[i].b);
    u16(b, s.code[i].c);
  }
  for (uint32_t i = 0; i < s.count; i++) u32(b, s.spans[i]);
  u32(b, 0);
}

static bool loads(spec s) {
  buffer b;
  build(&b, s);
  agc_program *p;
  char error[160];
  return agc_load(b.data, b.len, &p, error, sizeof error);
}

static bool loads_code(const agc_instr *code, const uint32_t *spans, uint32_t count) {
  spec s = base();
  s.code = code;
  s.spans = spans;
  s.count = count;
  return loads(s);
}

int main(void) {
  agc_init();
  buffer b;
  build(&b, base());
  agc_program *p = NULL;
  char error[160];
  assert(agc_load(b.data, b.len, &p, error, sizeof error));

  FILE *out = tmpfile();
  assert(out);
  agc_vm vm;
  agc_vm_init(&vm, p, out, INT64_MAX);
  assert(agc_vm_run(&vm).kind == AGC_DONE);
  char text[8] = {0};
  rewind(out);
  assert(fread(text, 1, sizeof text, out) == 2 && strcmp(text, "1\n") == 0);
  fclose(out);

  agc_vm_init(&vm, p, stdout, 1);
  agc_outcome limited = agc_vm_run(&vm);
  assert(limited.kind == AGC_FAILED && strcmp(limited.code, "RUNTIME-STEP-LIMIT") == 0 && limited.span == 2);

  for (size_t n = 0; n < b.len; n++) {
    agc_program *q;
    assert(!agc_load(b.data, n, &q, error, sizeof error));
  }

  spec s = base();
  s.magic = "AGCX";
  assert(!loads(s));
  s = base();
  s.version = AGC_FORMAT_VERSION + 1;
  assert(!loads(s));
  s = base();
  s.agentica = "0.0.0-other";
  assert(!loads(s));
  s = base();
  s.span_line = 9;
  assert(!loads(s));

  static const agc_instr bad_register[] = {{AGC_OP_CONST, 1, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t two_spans[] = {0, 0};
  assert(!loads_code(bad_register, two_spans, 2));

  static const uint32_t bad_span[] = {0, 3};
  static const agc_instr returns[] = {{AGC_OP_CONST, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(loads_code(returns, two_spans, 2));
  assert(!loads_code(returns, bad_span, 2));

  static const agc_instr bad_jump[] = {{AGC_OP_CONST, 0, 1, 0}, {AGC_OP_JUMP, 0, 9, 0}};
  assert(!loads_code(bad_jump, two_spans, 2));

  static const agc_instr back_to_const[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 1, 0}, {AGC_OP_JUMP, 0, 1, 0}};
  static const agc_instr back_to_step[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 1, 0}, {AGC_OP_JUMP, 0, 0, 0}};
  static const uint32_t three_spans[] = {1, 0, 0};
  assert(!loads_code(back_to_const, three_spans, 3));
  assert(loads_code(back_to_step, three_spans, 3));

  static const agc_instr call_without_step[] = {
    {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_CALL_BUILTIN, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t call_spans[] = {0, 1, 0};
  assert(!loads_code(call_without_step, call_spans, 3));

  static const agc_instr unknown_op[] = {{AGC_OP_COUNT, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(unknown_op, two_spans, 2));

  static const agc_instr no_return[] = {{AGC_OP_CONST, 0, 1, 0}, {AGC_OP_MOVE, 0, 0, 0}};
  assert(!loads_code(no_return, two_spans, 2));

  s = base();
  s.registers = 0;
  assert(!loads(s));

  puts("loader tests passed");
  return 0;
}
