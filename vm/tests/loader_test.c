#include "../agc.h"

#include <assert.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  uint8_t *data;
  size_t len;
} buffer;

typedef struct {
  const char *magic;
  uint32_t version;
  const char *agentica;
  const char *name;
  uint32_t spans[3][5];
  uint32_t extra_voids;
  int extra_kind;
  const char *extra_string;
  const char *builtin;
  uint32_t params, registers;
  const agc_instr *code;
  const uint32_t *code_spans;
  uint32_t count;
  uint32_t helper_params;
  uint32_t entry;
  bool trailing;
  uint32_t builtin_arity;
  int64_t extra_int;
  const buffer *tables;
  double extra_float, second_float;
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
static void float_bits(buffer *b, double f) {
  uint64_t bits;
  memcpy(&bits, &f, sizeof bits);
  u32(b, (uint32_t)bits);
  u32(b, (uint32_t)(bits >> 32));
}

static void function(buffer *b, const char *name, uint32_t params, uint32_t registers, const agc_instr *code,
                     const uint32_t *spans, uint32_t count) {
  str(b, name);
  u32(b, params);
  u32(b, 0);
  u32(b, registers);
  u32(b, 0);
  u32(b, count);
  for (uint32_t i = 0; i < count; i++) {
    u16(b, code[i].op);
    u16(b, code[i].a);
    u16(b, code[i].b);
    u16(b, code[i].c);
  }
  for (uint32_t i = 0; i < count; i++) u32(b, spans[i]);
}

static const agc_instr puts_code[] = {
  {AGC_OP_STEP, 2, 0, 0},
  {AGC_OP_CONST, 0, 0, 0},
  {AGC_OP_CALL_BUILTIN, 0, 0, 0},
  {AGC_OP_CONST, 0, 1, 0},
  {AGC_OP_RETURN, 0, 0, 0},
};
static const uint32_t puts_spans[] = {1, 2, 1, 0, 0};
static const agc_instr helper_code[] = {{AGC_OP_CONST, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
static const uint32_t two_spans[] = {0, 0};

static spec base(void) {
  spec s = {"AGCB", AGC_FORMAT_VERSION, AGC_VERSION, "t.agc",
            {{0, 1, 1, 4, 1}, {0, 2, 3, 2, 10}, {0, 2, 8, 2, 9}},
            0, -1, NULL, "puts", 0, 1, puts_code, puts_spans, 5, 0, 0, false, 0, 0, NULL, 1.5, 0};
  return s;
}

static buffer build(spec s) {
  buffer b;
  b.data = malloc(4096 + (size_t)s.extra_voids + (s.tables ? s.tables->len : 0));
  assert(b.data);
  b.len = 0;
  memcpy(b.data, s.magic, 4);
  b.len = 4;
  u32(&b, s.version);
  str(&b, s.agentica);
  u32(&b, 1);
  str(&b, s.name);
  str(&b, "def main() -> Void\n  puts(1)\nend\n");
  u32(&b, 3);
  for (int i = 0; i < 3; i++)
    for (int k = 0; k < 5; k++) u32(&b, s.spans[i][k]);
  u32(&b, 2 + s.extra_voids + (s.extra_kind >= 0) + (s.second_float != 0));
  u8(&b, 4);
  u32(&b, 1);
  u32(&b, 0);
  u8(&b, 0);
  for (uint32_t i = 0; i < s.extra_voids; i++) u8(&b, 0);
  if (s.extra_kind >= 0) u8(&b, (uint8_t)s.extra_kind);
  if (s.extra_kind == 5) float_bits(&b, s.extra_float);
  if (s.extra_kind == 6) str(&b, s.extra_string);
  if (s.second_float != 0) {
    u8(&b, 5);
    float_bits(&b, s.second_float);
  }
  if (s.extra_kind == 4) {
    u32(&b, (uint32_t)(uint64_t)s.extra_int);
    u32(&b, (uint32_t)((uint64_t)s.extra_int >> 32));
  }
  if (s.tables) {
    memcpy(b.data + b.len, s.tables->data, s.tables->len);
    b.len += s.tables->len;
  } else {
    u32(&b, 0);
    u32(&b, 0);
  }
  u32(&b, 1);
  str(&b, s.builtin);
  u32(&b, s.builtin_arity ? s.builtin_arity : 1);
  u32(&b, s.helper_params ? 2 : 1);
  function(&b, "main", s.params, s.registers, s.code, s.code_spans, s.count);
  if (s.helper_params) function(&b, "helper", s.helper_params, s.helper_params, helper_code, two_spans, 2);
  u32(&b, s.entry);
  if (s.trailing) u8(&b, 0);
  return b;
}

static bool loads(spec s, const char *reason) {
  buffer b = build(s);
  agc_program *p;
  char error[160] = "";
  bool ok = agc_load(b.data, b.len, &p, error, sizeof error);
  free(b.data);
  if (reason && !strstr(error, reason)) {
    fprintf(stderr, "expected \"%s\", got \"%s\"\n", reason, error);
    return true;
  }
  return ok;
}

static buffer make_tables(uint32_t arity) {
  buffer t;
  t.data = malloc(4096);
  assert(t.data);
  t.len = 0;
  u32(&t, 2);
  str(&t, "P");
  u32(&t, 1);
  str(&t, "x");
  str(&t, "Q");
  u32(&t, 2);
  str(&t, "a");
  str(&t, "b");
  u32(&t, 1);
  str(&t, "E");
  u32(&t, 2);
  str(&t, "A");
  u32(&t, 0);
  str(&t, "B");
  u32(&t, arity);
  return t;
}

static bool loads_tables(uint32_t arity, const char *reason) {
  buffer t = make_tables(arity);
  spec s = base();
  s.tables = &t;
  bool ok = loads(s, reason);
  free(t.data);
  return ok;
}

static agc_outcome run_spec(spec s, FILE *out) {
  buffer b = build(s);
  agc_program *p;
  char error[160];
  assert(agc_load(b.data, b.len, &p, error, sizeof error));
  free(b.data);
  agc_vm vm;
  agc_vm_init(&vm, p, out, out, INT64_MAX);
  return agc_vm_run(&vm);
}

static void expect_output(FILE *out, const char *expected) {
  char text[64] = {0};
  rewind(out);
  assert(fread(text, 1, sizeof text, out) == strlen(expected) && strcmp(text, expected) == 0);
  fclose(out);
}

static bool loads_with_tables(const agc_instr *code, const uint32_t *spans, uint32_t count, uint32_t registers,
                              const char *reason) {
  buffer t = make_tables(1);
  spec s = base();
  s.tables = &t;
  s.code = code;
  s.code_spans = spans;
  s.count = count;
  s.registers = registers;
  bool ok = loads(s, reason);
  free(t.data);
  return ok;
}

static agc_outcome run_with_tables(const agc_instr *code, const uint32_t *spans, uint32_t count, FILE *out) {
  buffer t = make_tables(1);
  spec s = base();
  s.tables = &t;
  s.code = code;
  s.code_spans = spans;
  s.count = count;
  s.registers = 4;
  agc_outcome outcome = run_spec(s, out);
  free(t.data);
  return outcome;
}

static bool loads_code(const agc_instr *code, const uint32_t *spans, uint32_t count, const char *reason) {
  spec s = base();
  s.code = code;
  s.code_spans = spans;
  s.count = count;
  return loads(s, reason);
}

int main(void) {
  agc_init();
  buffer b = build(base());
  agc_program *p = NULL;
  char error[160];
  assert(agc_load(b.data, b.len, &p, error, sizeof error));

  FILE *out = tmpfile();
  assert(out);
  agc_vm vm;
  agc_vm_init(&vm, p, out, out, INT64_MAX);
  assert(agc_vm_run(&vm).kind == AGC_DONE);
  char text[8] = {0};
  rewind(out);
  assert(fread(text, 1, sizeof text, out) == 2 && strcmp(text, "1\n") == 0);
  fclose(out);

  agc_vm_init(&vm, p, stdout, stdout, 1);
  agc_outcome limited = agc_vm_run(&vm);
  assert(limited.kind == AGC_FAILED && strcmp(limited.code, "RUNTIME-STEP-LIMIT") == 0 && limited.span == 2);

  for (size_t n = 0; n < b.len; n++) {
    agc_program *q;
    assert(!agc_load(b.data, n, &q, error, sizeof error));
  }
  free(b.data);

  spec s = base();
  s.magic = "AGCX";
  assert(!loads(s, "bad magic"));
  s = base();
  s.version = AGC_FORMAT_VERSION + 1;
  assert(!loads(s, "format version"));
  s = base();
  s.agentica = "0.0.0-other";
  assert(!loads(s, "Agentica version"));
  s = base();
  s.trailing = true;
  assert(!loads(s, "trailing bytes"));
  s = base();
  s.entry = 1;
  assert(!loads(s, "entry out of range"));
  s = base();
  s.code = helper_code;
  s.code_spans = two_spans;
  s.count = 2;
  s.params = 1;
  assert(!loads(s, "entry takes parameters"));
  s = base();
  s.builtin = "putz";
  assert(!loads(s, "unknown builtin"));

  s = base();
  s.name = "\xC0\xAF";
  assert(!loads(s, "invalid UTF-8"));
  s.name = "\xED\xA0\x80";
  assert(!loads(s, "invalid UTF-8"));
  s.name = "\xF4\x90\x80\x80";
  assert(!loads(s, "invalid UTF-8"));

  s = base();
  s.spans[1][1] = 9;
  assert(!loads(s, "line out of range"));
  s = base();
  s.spans[2][2] = 0;
  assert(!loads(s, "column out of range"));
  s = base();
  s.spans[1][4] = 11;
  assert(!loads(s, "column out of range"));
  s = base();
  s.spans[2][4] = 3;
  assert(!loads(s, "starts after it ends"));

  s = base();
  s.params = 2;
  assert(!loads(s, "bad register count"));
  s = base();
  s.registers = 65536;
  assert(!loads(s, "bad register count"));
  static const agc_instr spin[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_JUMP, 0, 0, 0}};
  static const uint32_t spin_spans[] = {1, 0};
  s = base();
  s.code = spin;
  s.code_spans = spin_spans;
  s.count = 2;
  assert(loads(s, NULL));
  s.registers = 0;
  assert(!loads(s, "bad register count"));

  s = base();
  s.extra_voids = 400000;
  assert(!loads(s, "too much memory"));

  static const agc_instr bad_register[] = {{AGC_OP_CONST, 1, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(bad_register, two_spans, 2, "register out of range"));
  static const agc_instr bad_constant[] = {{AGC_OP_CONST, 0, 2, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(bad_constant, two_spans, 2, "constant index"));
  static const uint32_t bad_span[] = {0, 3};
  assert(loads_code(helper_code, two_spans, 2, NULL));
  assert(!loads_code(helper_code, bad_span, 2, "span index"));
  static const agc_instr bad_jump[] = {{AGC_OP_CONST, 0, 1, 0}, {AGC_OP_JUMP, 0, 9, 0}};
  assert(!loads_code(bad_jump, two_spans, 2, "jump target"));

  static const agc_instr step_zero[] = {{AGC_OP_STEP, 0, 0, 0}, {AGC_OP_CONST, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t three_spans[] = {1, 0, 0};
  assert(!loads_code(step_zero, three_spans, 3, "STEP count"));
  static const agc_instr step_wide[] = {{AGC_OP_STEP, 3, 0, 0}, {AGC_OP_CONST, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(step_wide, three_spans, 3, "span index"));
  static const uint32_t builtin_wide[] = {1, 2, 2, 0, 0};
  assert(!loads_code(puts_code, builtin_wide, 5, "span index"));

  static const agc_instr call_window[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CALL, 1, 1, 0}, {AGC_OP_CONST, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t four_spans[] = {1, 1, 0, 0};
  s = base();
  s.code = call_window;
  s.code_spans = four_spans;
  s.count = 4;
  s.registers = 2;
  s.helper_params = 2;
  assert(!loads(s, "register range"));
  s.registers = 3;
  assert(loads(s, NULL));
  static const agc_instr tail_window[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_TAIL_CALL, 1, 1, 0}, {AGC_OP_CONST, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  s = base();
  s.code = tail_window;
  s.code_spans = four_spans;
  s.count = 4;
  s.registers = 2;
  s.helper_params = 2;
  assert(!loads(s, "register range"));
  s.registers = 3;
  assert(loads(s, NULL));
  out = tmpfile();
  assert(out);
  assert(run_spec(s, out).kind == AGC_DONE);
  expect_output(out, "");
  static const agc_instr tail_far[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_TAIL_CALL, 0, 2, 0}, {AGC_OP_CONST, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(tail_far, four_spans, 4, "function index out of range"));
  static const agc_instr tail_without_step[] = {{AGC_OP_TAIL_CALL, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(tail_without_step, two_spans, 2, "does not start with STEP"));
  static const agc_instr tail_spin[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_TAIL_CALL, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t tail_spin_spans[] = {1, 1, 0};
  s = base();
  s.code = tail_spin;
  s.code_spans = tail_spin_spans;
  s.count = 3;
  buffer spin_file = build(s);
  assert(agc_load(spin_file.data, spin_file.len, &p, error, sizeof error));
  free(spin_file.data);
  agc_vm_init(&vm, p, stdout, stdout, 100000);
  agc_outcome spun = agc_vm_run(&vm);
  assert(spun.kind == AGC_FAILED && strcmp(spun.code, "RUNTIME-STEP-LIMIT") == 0 && spun.span == 1 && vm.depth == 1);
  static const agc_instr builtin_window[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CALL_BUILTIN, 1, 0, 0}, {AGC_OP_CONST, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t builtin_spans[] = {1, 1, 0, 0};
  assert(!loads_code(builtin_window, builtin_spans, 4, "register out of range"));

  static const agc_instr back_to_const[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 1, 0}, {AGC_OP_JUMP, 0, 1, 0}};
  static const agc_instr back_to_step[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 1, 0}, {AGC_OP_JUMP, 0, 0, 0}};
  assert(!loads_code(back_to_const, three_spans, 3, "backward jump"));
  assert(loads_code(back_to_step, three_spans, 3, NULL));

  static const agc_instr call_without_step[] = {
    {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_CALL_BUILTIN, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t call_spans[] = {0, 1, 0};
  assert(!loads_code(call_without_step, call_spans, 3, "does not start with STEP"));
  static const agc_instr long_without_step[] = {
    {AGC_OP_CONST, 0, 1, 0}, {AGC_OP_MOVE, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(long_without_step, three_spans, 3, "does not start with STEP"));

  static const agc_instr unknown_op[] = {{AGC_OP_COUNT, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(unknown_op, two_spans, 2, "unknown opcode"));
  static const agc_instr no_return[] = {{AGC_OP_CONST, 0, 1, 0}, {AGC_OP_MOVE, 0, 0, 0}};
  assert(!loads_code(no_return, two_spans, 2, "does not end with RETURN"));

  static const agc_instr puts_extra[] = {
    {AGC_OP_STEP, 2, 0, 0}, {AGC_OP_CONST, 0, 2, 0}, {AGC_OP_CALL_BUILTIN, 0, 0, 0},
    {AGC_OP_CONST, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  const char *printed[] = {"nil\n", "1.5\n"};
  for (int k = 0; k < 2; k++) {
    s = base();
    s.extra_kind = k == 0 ? 1 : 5;
    s.code = puts_extra;
    buffer extra = build(s);
    for (size_t n = 0; n < extra.len; n++) {
      agc_program *q;
      assert(!agc_load(extra.data, n, &q, error, sizeof error));
    }
    assert(agc_load(extra.data, extra.len, &p, error, sizeof error));
    free(extra.data);
    out = tmpfile();
    assert(out);
    agc_vm_init(&vm, p, out, out, INT64_MAX);
    assert(agc_vm_run(&vm).kind == AGC_DONE);
    memset(text, 0, sizeof text);
    rewind(out);
    assert(fread(text, 1, sizeof text, out) == strlen(printed[k]) && strcmp(text, printed[k]) == 0);
    fclose(out);
  }
  static const agc_instr int_as_float[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_ADD_F, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t confused_spans[] = {1, 2, 2, 0};
  s = base();
  s.code = int_as_float;
  s.code_spans = confused_spans;
  s.count = 4;
  buffer confused = build(s);
  assert(agc_load(confused.data, confused.len, &p, error, sizeof error));
  free(confused.data);
  agc_vm_init(&vm, p, stdout, stdout, INT64_MAX);
  agc_outcome wrong = agc_vm_run(&vm);
  assert(wrong.kind == AGC_FAILED && strcmp(wrong.code, "RUNTIME-INTERNAL") == 0);
  s = base();
  s.extra_kind = 7;
  assert(!loads(s, "unsupported constant kind"));

  static const agc_instr bad_float_op[] = {{AGC_OP_ADD_F, 0, 0, 1}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(bad_float_op, two_spans, 2, "register out of range"));
  static const agc_instr bad_float_neg[] = {{AGC_OP_NEG_F, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(bad_float_neg, two_spans, 2, "register out of range"));

  static const agc_instr bad_concat[] = {{AGC_OP_CONCAT, 0, 0, 1}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(bad_concat, two_spans, 2, "register out of range"));
  static const agc_instr bad_to_text[] = {{AGC_OP_TO_TEXT, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(bad_to_text, two_spans, 2, "register out of range"));
  static const agc_instr bad_inspect[] = {{AGC_OP_INSPECT, 1, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(bad_inspect, two_spans, 2, "register out of range"));
  static const agc_instr int_concat[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_CONCAT, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  s = base();
  s.code = int_concat;
  s.code_spans = confused_spans;
  s.count = 4;
  confused = build(s);
  assert(agc_load(confused.data, confused.len, &p, error, sizeof error));
  free(confused.data);
  agc_vm_init(&vm, p, stdout, stdout, INT64_MAX);
  wrong = agc_vm_run(&vm);
  assert(wrong.kind == AGC_FAILED && strcmp(wrong.code, "RUNTIME-INTERNAL") == 0);
  static const agc_instr void_text[] = {{AGC_OP_TO_TEXT, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr void_inspect[] = {{AGC_OP_INSPECT, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  const agc_instr *void_codes[] = {void_text, void_inspect};
  for (int k = 0; k < 2; k++) {
    s = base();
    s.code = void_codes[k];
    s.code_spans = two_spans;
    s.count = 2;
    confused = build(s);
    assert(agc_load(confused.data, confused.len, &p, error, sizeof error));
    free(confused.data);
    agc_vm_init(&vm, p, stdout, stdout, INT64_MAX);
    wrong = agc_vm_run(&vm);
    assert(wrong.kind == AGC_FAILED && strcmp(wrong.code, "RUNTIME-INTERNAL") == 0);
  }
  s = base();
  s.extra_kind = 6;
  s.extra_string = "\xE2\x82";
  assert(!loads(s, "invalid UTF-8"));

  static const agc_instr bad_list_target[] = {{AGC_OP_LIST, 1, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(bad_list_target, two_spans, 2, "register out of range"));
  static const agc_instr bad_list_start[] = {{AGC_OP_LIST, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(bad_list_start, two_spans, 2, "register out of range"));
  static const agc_instr bad_list_window[] = {{AGC_OP_LIST, 0, 0, 2}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(bad_list_window, two_spans, 2, "register range out of range"));
  static const agc_instr bad_list_len[] = {{AGC_OP_LIST_LEN, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(bad_list_len, two_spans, 2, "register out of range"));
  static const agc_instr bad_list_get[] = {{AGC_OP_LIST_GET, 0, 0, 1}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(bad_list_get, two_spans, 2, "register out of range"));

  static const agc_instr exact_window[] = {{AGC_OP_LIST, 0, 0, 2}, {AGC_OP_RETURN, 0, 0, 0}};
  s = base();
  s.code = exact_window;
  s.code_spans = two_spans;
  s.count = 2;
  s.registers = 2;
  assert(loads(s, NULL));

  static const agc_instr nested_list[] = {
    {AGC_OP_STEP, 2, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_LIST, 0, 0, 1}, {AGC_OP_LIST, 0, 0, 1},
    {AGC_OP_LIST, 1, 0, 0}, {AGC_OP_CALL_BUILTIN, 0, 0, 0}, {AGC_OP_CONST, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t nested_spans[] = {1, 2, 2, 2, 2, 1, 0, 0};
  s = base();
  s.code = nested_list;
  s.code_spans = nested_spans;
  s.count = 8;
  s.registers = 2;
  confused = build(s);
  assert(agc_load(confused.data, confused.len, &p, error, sizeof error));
  free(confused.data);
  out = tmpfile();
  assert(out);
  agc_vm_init(&vm, p, out, out, INT64_MAX);
  assert(agc_vm_run(&vm).kind == AGC_DONE);
  memset(text, 0, sizeof text);
  rewind(out);
  assert(fread(text, 1, sizeof text, out) == 6 && strcmp(text, "[[1]]\n") == 0);
  fclose(out);

  static const agc_instr int_list_len[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_LIST_LEN, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr int_list_get[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_LIST_GET, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  const agc_instr *not_lists[] = {int_list_len, int_list_get};
  for (int k = 0; k < 2; k++) {
    s = base();
    s.code = not_lists[k];
    s.code_spans = confused_spans;
    s.count = 4;
    confused = build(s);
    assert(agc_load(confused.data, confused.len, &p, error, sizeof error));
    free(confused.data);
    agc_vm_init(&vm, p, stdout, stdout, INT64_MAX);
    wrong = agc_vm_run(&vm);
    assert(wrong.kind == AGC_FAILED && strcmp(wrong.code, "RUNTIME-INTERNAL") == 0);
  }
  static const agc_instr void_item_puts[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_LIST, 0, 0, 1}, {AGC_OP_CALL_BUILTIN, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr void_item_inspect[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_LIST, 0, 0, 1}, {AGC_OP_INSPECT, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t void_item_spans[] = {1, 2, 1, 0};
  const agc_instr *void_items[] = {void_item_puts, void_item_inspect};
  for (int k = 0; k < 2; k++) {
    s = base();
    s.code = void_items[k];
    s.code_spans = void_item_spans;
    s.count = 4;
    confused = build(s);
    assert(agc_load(confused.data, confused.len, &p, error, sizeof error));
    free(confused.data);
    agc_vm_init(&vm, p, stdout, stdout, INT64_MAX);
    wrong = agc_vm_run(&vm);
    assert(wrong.kind == AGC_FAILED && strcmp(wrong.code, "RUNTIME-INTERNAL") == 0);
  }

  static const agc_instr concat_ints[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_CONST, 1, 0, 0}, {AGC_OP_CALL_BUILTIN, 0, 0, 0},
    {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t concat_spans[] = {1, 2, 2, 0, 0};
  s = base();
  s.builtin = "List.concat";
  s.builtin_arity = 2;
  s.code = concat_ints;
  s.code_spans = concat_spans;
  s.count = 5;
  s.registers = 2;
  confused = build(s);
  assert(agc_load(confused.data, confused.len, &p, error, sizeof error));
  free(confused.data);
  agc_vm_init(&vm, p, stdout, stdout, INT64_MAX);
  wrong = agc_vm_run(&vm);
  assert(wrong.kind == AGC_FAILED && strcmp(wrong.code, "RUNTIME-INTERNAL") == 0);
  s.builtin_arity = 3;
  s.registers = 3;
  assert(!loads(s, "unknown builtin"));

  static const agc_instr list_get_outside[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_LIST, 1, 0, 1}, {AGC_OP_LIST_GET, 0, 1, 0},
    {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t outside_spans[] = {1, 2, 2, 2, 0};
  s = base();
  s.code = list_get_outside;
  s.code_spans = outside_spans;
  s.count = 5;
  s.registers = 2;
  confused = build(s);
  assert(agc_load(confused.data, confused.len, &p, error, sizeof error));
  free(confused.data);
  agc_vm_init(&vm, p, stdout, stdout, INT64_MAX);
  wrong = agc_vm_run(&vm);
  assert(wrong.kind == AGC_FAILED && strcmp(wrong.code, "RUNTIME-INDEX-OUT-OF-RANGE") == 0 && wrong.span == 2);
  assert(strcmp(wrong.message, "index 1 is outside a list of length 1") == 0);
  static const agc_instr list_get_negative[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_LIST, 1, 0, 1}, {AGC_OP_CONST, 0, 2, 0},
    {AGC_OP_LIST_GET, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t negative_spans[] = {1, 2, 2, 2, 2, 0};
  const int64_t negatives[] = {-1, INT64_MIN};
  const char *negative_messages[] = {"index -1 is outside a list of length 1",
                                     "index -9223372036854775808 is outside a list of length 1"};
  for (int k = 0; k < 2; k++) {
    s = base();
    s.extra_kind = 4;
    s.extra_int = negatives[k];
    s.code = list_get_negative;
    s.code_spans = negative_spans;
    s.count = 6;
    s.registers = 2;
    confused = build(s);
    assert(agc_load(confused.data, confused.len, &p, error, sizeof error));
    free(confused.data);
    agc_vm_init(&vm, p, stdout, stdout, INT64_MAX);
    wrong = agc_vm_run(&vm);
    assert(wrong.kind == AGC_FAILED && strcmp(wrong.code, "RUNTIME-INDEX-OUT-OF-RANGE") == 0 && wrong.span == 2);
    assert(strcmp(wrong.message, negative_messages[k]) == 0);
  }

  static const agc_instr data_code[] = {
    {AGC_OP_STEP, 1, 0, 0},        {AGC_OP_CONST, 0, 0, 0},       {AGC_OP_STRUCT, 1, 0, 0},
    {AGC_OP_ENUM, 2, 1, 1},        {AGC_OP_MOVE, 3, 2, 0},        {AGC_OP_CALL_BUILTIN, 3, 0, 0},
    {AGC_OP_PAYLOAD, 3, 2, 0},     {AGC_OP_FIELD, 3, 3, 0},       {AGC_OP_SAME, 3, 3, 0},
    {AGC_OP_CALL_BUILTIN, 3, 0, 0}, {AGC_OP_IS_VARIANT, 3, 2, 0}, {AGC_OP_CALL_BUILTIN, 3, 0, 0},
    {AGC_OP_ENUM, 3, 3, 0},        {AGC_OP_CALL_BUILTIN, 3, 0, 0}, {AGC_OP_CONST, 0, 1, 0},
    {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t data_spans[] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 1, 0, 0};
  out = tmpfile();
  assert(out);
  assert(run_with_tables(data_code, data_spans, 16, out).kind == AGC_DONE);
  expect_output(out, "E.B(P(x: 1))\ntrue\nfalse\nE.A\n");
  buffer t = make_tables(1);
  s = base();
  s.tables = &t;
  s.code = data_code;
  s.code_spans = data_spans;
  s.count = 16;
  s.registers = 4;
  buffer with_tables = build(s);
  for (size_t n = 0; n < with_tables.len; n++) {
    agc_program *q;
    assert(!agc_load(with_tables.data, n, &q, error, sizeof error));
  }
  free(with_tables.data);
  free(t.data);

  assert(!loads_tables(65536, "variant arity too large"));
  assert(loads_tables(65535, NULL));

  for (uint32_t fields = 65535; fields <= 65536; fields++) {
    buffer wide;
    wide.data = malloc((size_t)fields * 5 + 64);
    assert(wide.data);
    wide.len = 0;
    u32(&wide, 1);
    str(&wide, "W");
    u32(&wide, fields);
    for (uint32_t k = 0; k < fields; k++) str(&wide, "f");
    u32(&wide, 0);
    s = base();
    s.tables = &wide;
    assert(fields == 65535 ? loads(s, NULL) : !loads(s, "too many fields"));
    free(wide.data);
  }

  buffer many;
  many.data = malloc(65535 * 9 + 64);
  assert(many.data);
  many.len = 0;
  u32(&many, 0);
  u32(&many, 1);
  str(&many, "E");
  u32(&many, 65535);
  for (uint32_t k = 0; k < 65535; k++) {
    str(&many, "V");
    u32(&many, 0);
  }
  static const agc_instr last_variant[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_ENUM, 0, 0, 65534}, {AGC_OP_CALL_BUILTIN, 0, 0, 0}, {AGC_OP_CONST, 0, 1, 0},
    {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t last_spans[] = {1, 0, 1, 0, 0};
  s = base();
  s.tables = &many;
  s.code = last_variant;
  s.code_spans = last_spans;
  s.count = 5;
  out = tmpfile();
  assert(out);
  assert(run_spec(s, out).kind == AGC_DONE);
  expect_output(out, "E.V\n");
  free(many.data);

  static const agc_instr same_floats[] = {
    {AGC_OP_STEP, 1, 0, 0},       {AGC_OP_CONST, 0, 2, 0},       {AGC_OP_SAME, 1, 0, 0},
    {AGC_OP_CALL_BUILTIN, 1, 0, 0}, {AGC_OP_CONST, 0, 3, 0},     {AGC_OP_SUB_F, 0, 0, 0},
    {AGC_OP_NEG_F, 1, 0, 0},      {AGC_OP_SAME, 1, 0, 1},        {AGC_OP_CALL_BUILTIN, 1, 0, 0},
    {AGC_OP_MOVE, 1, 0, 0},       {AGC_OP_SAME, 1, 0, 1},        {AGC_OP_CALL_BUILTIN, 1, 0, 0},
    {AGC_OP_CONST, 0, 1, 0},      {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t same_spans[] = {1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0};
  s = base();
  s.extra_kind = 5;
  s.extra_float = NAN;
  s.second_float = 1.5;
  s.code = same_floats;
  s.code_spans = same_spans;
  s.count = 14;
  s.registers = 2;
  out = tmpfile();
  assert(out);
  assert(run_spec(s, out).kind == AGC_DONE);
  expect_output(out, "true\nfalse\ntrue\n");

  static const agc_instr bad_struct_type[] = {{AGC_OP_STRUCT, 0, 0, 2}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_struct_type, two_spans, 2, 4, "struct index out of range"));
  static const agc_instr bad_struct_window[] = {{AGC_OP_STRUCT, 0, 3, 1}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_struct_window, two_spans, 2, 4, "register range out of range"));
  static const agc_instr bad_struct_target[] = {{AGC_OP_STRUCT, 4, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_struct_target, two_spans, 2, 4, "register out of range"));
  static const agc_instr bad_enum_variant[] = {{AGC_OP_ENUM, 0, 0, 2}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_enum_variant, two_spans, 2, 4, "variant index out of range"));
  static const agc_instr bad_enum_window[] = {{AGC_OP_ENUM, 0, 4, 1}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_enum_window, two_spans, 2, 4, "register out of range"));
  buffer pair_tables = make_tables(2);
  static const agc_instr bad_pair_window[] = {{AGC_OP_ENUM, 0, 3, 1}, {AGC_OP_RETURN, 0, 0, 0}};
  s = base();
  s.tables = &pair_tables;
  s.code = bad_pair_window;
  s.code_spans = two_spans;
  s.count = 2;
  s.registers = 4;
  assert(!loads(s, "register range out of range"));
  free(pair_tables.data);
  static const agc_instr bad_nullary_start[] = {{AGC_OP_ENUM, 0, 4, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_nullary_start, two_spans, 2, 4, "register out of range"));
  static const agc_instr bad_is_variant[] = {{AGC_OP_IS_VARIANT, 0, 0, 2}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_is_variant, two_spans, 2, 4, "variant index out of range"));
  static const agc_instr bad_is_variant_reg[] = {{AGC_OP_IS_VARIANT, 0, 4, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_is_variant_reg, two_spans, 2, 4, "register out of range"));
  static const agc_instr bad_field[] = {{AGC_OP_FIELD, 0, 0, 2}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_field, two_spans, 2, 4, "field index out of range"));
  static const agc_instr bad_field_reg[] = {{AGC_OP_FIELD, 4, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_field_reg, two_spans, 2, 4, "register out of range"));
  static const agc_instr bad_payload[] = {{AGC_OP_PAYLOAD, 0, 0, 1}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_payload, two_spans, 2, 4, "payload index out of range"));
  static const agc_instr bad_payload_reg[] = {{AGC_OP_PAYLOAD, 0, 4, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_payload_reg, two_spans, 2, 4, "register out of range"));
  static const agc_instr bad_same[] = {{AGC_OP_SAME, 0, 0, 4}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_same, two_spans, 2, 4, "register out of range"));
  assert(!loads_code(bad_field, two_spans, 2, "field index out of range"));
  static const agc_instr exact_struct[] = {{AGC_OP_STRUCT, 0, 2, 1}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(loads_with_tables(exact_struct, two_spans, 2, 4, NULL));

  static const agc_instr field_past_own[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_STRUCT, 0, 0, 0}, {AGC_OP_FIELD, 0, 0, 1}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr payload_of_nullary[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_ENUM, 0, 0, 0}, {AGC_OP_PAYLOAD, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr field_of_int[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_FIELD, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr variant_of_struct[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_STRUCT, 0, 0, 0}, {AGC_OP_IS_VARIANT, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr same_lists[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_LIST, 0, 0, 0}, {AGC_OP_SAME, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr same_structs[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_STRUCT, 0, 0, 0}, {AGC_OP_SAME, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr same_enums[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_ENUM, 0, 0, 0}, {AGC_OP_SAME, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  const agc_instr *broken[] = {field_past_own,    payload_of_nullary, field_of_int, variant_of_struct,
                               same_lists,        same_structs,       same_enums};
  for (int k = 0; k < 7; k++) {
    agc_outcome bad = run_with_tables(broken[k], confused_spans, 4, stdout);
    assert(bad.kind == AGC_FAILED && strcmp(bad.code, "RUNTIME-INTERNAL") == 0);
  }

  static const agc_instr bad_try[] = {{AGC_OP_TRY, 0, 4, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_try, two_spans, 2, 4, "register out of range"));
  static const agc_instr bad_is_ok[] = {{AGC_OP_IS_OK, 4, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_is_ok, two_spans, 2, 4, "register out of range"));
  static const agc_instr bad_result_value[] = {{AGC_OP_RESULT_VALUE, 0, 4, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_result_value, two_spans, 2, 4, "register out of range"));
  static const agc_instr try_int[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_TRY, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr is_ok_int[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_IS_OK, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr value_of_int[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_RESULT_VALUE, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  const agc_instr *not_results[] = {try_int, is_ok_int, value_of_int};
  for (int k = 0; k < 3; k++) {
    agc_outcome bad = run_with_tables(not_results[k], confused_spans, 4, stdout);
    assert(bad.kind == AGC_FAILED && strcmp(bad.code, "RUNTIME-INTERNAL") == 0);
  }
  static const agc_instr try_error_in_main[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 2, 0}, {AGC_OP_CALL_BUILTIN, 0, 0, 0},
    {AGC_OP_TRY, 1, 0, 0},  {AGC_OP_NOT, 0, 0, 0},   {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t try_error_spans[] = {1, 0, 1, 0, 0, 0};
  s = base();
  s.builtin = "error";
  s.extra_kind = 6;
  s.extra_string = "e";
  s.code = try_error_in_main;
  s.code_spans = try_error_spans;
  s.count = 6;
  s.registers = 2;
  assert(run_spec(s, stdout).kind == AGC_DONE);

  puts("loader tests passed");
  return 0;
}
