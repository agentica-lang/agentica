/*
 * One assert per loader rule: each case is a malformed input that must be
 * rejected. type_tables builds the Types section cases, make_updates the Updates
 * section and STRUCT_WITH, and pair_spec the Globals section and GLOBAL.
 * source_root_tests covers agc_program_set_source_root.
 */
#include "../core.h"

#include <assert.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#if defined(__linux__) || defined(__APPLE__)
#include <unistd.h>
#endif

#ifndef AGC_NO_GC
#include <gc.h>
#endif

/* spans_at and count_at, set by build only, are where the span count and the instruction count of the first function
 * are, for the tests that patch them. */
typedef struct {
  uint8_t *data;
  size_t len, spans_at, count_at;
} buffer;

/* One function of a file with two: the entry is picked by spec.entry. */
typedef struct {
  const char *name;
  uint32_t params, registers;
  const agc_instr *code;
  const uint32_t *spans;
  uint32_t count;
  uint32_t prelude;
} fn_spec;

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
  uint32_t captures, helper_captures;
  const char *second_source;
  const buffer *updates;
  uint32_t globals;
  fn_spec funcs[2];
  uint32_t func_count;
  uint32_t main_prelude, helper_prelude;
  uint32_t more_spans;
  /* A second builtin import (index 1) and an Int constant after the others, when set. */
  const char *builtin2;
  uint32_t builtin2_arity;
  int64_t second_int;
} spec;

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

/* Version 6 writes the prelude flag of each function after its span; a version 5 file has none. */
static bool flags_written = true;

/* Returns where the instruction count is. */
static size_t function(buffer *b, const char *name, uint32_t params, uint32_t captures, uint32_t registers,
                       const agc_instr *code, const uint32_t *spans, uint32_t count, uint32_t prelude) {
  str(b, name);
  u32(b, params);
  u32(b, captures);
  u32(b, registers);
  u32(b, 0);
  if (flags_written) u32(b, prelude);
  size_t count_at = b->len;
  u32(b, count);
  for (uint32_t i = 0; i < count; i++) {
    u16(b, code[i].op);
    u16(b, code[i].a);
    u16(b, code[i].b);
    u16(b, code[i].c);
  }
  for (uint32_t i = 0; i < count; i++) u32(b, spans[i]);
  return count_at;
}

static spec base(void) {
  spec s = {"AGCB", AGC_FORMAT_VERSION, AGC_VERSION, "t.agc",
            {{0, 1, 1, 4, 1}, {0, 2, 3, 2, 10}, {0, 2, 8, 2, 9}},
            0, -1, NULL, "puts", 0, 1, puts_code, puts_spans, 5, 0, 0, false, 0, 0, NULL, 1.5, 0, 0, 0, NULL, NULL, 0, {{0}}, 0, 0, 0, 0, NULL, 0, 0};
  return s;
}

static buffer build(spec s) {
  buffer b;
  flags_written = s.version != AGC_FORMAT_PREVIOUS;
  b.data = malloc(4096 + (size_t)s.extra_voids + (s.tables ? s.tables->len : 0) + (s.updates ? s.updates->len : 0));
  assert(b.data);
  b.len = 0;
  memcpy(b.data, s.magic, 4);
  b.len = 4;
  u32(&b, s.version);
  str(&b, s.agentica);
  u32(&b, s.second_source ? 2 : 1);
  str(&b, s.name);
  str(&b, "def main() -> Void\n  puts(1)\nend\n");
  if (s.second_source) {
    str(&b, "lib/m.agc");
    str(&b, s.second_source);
  }
  b.spans_at = b.len;
  u32(&b, 3 + s.more_spans);
  for (int i = 0; i < 3; i++)
    for (int k = 0; k < 5; k++) u32(&b, s.spans[i][k]);
  for (uint32_t i = 0; i < s.more_spans; i++)
    for (int k = 0; k < 5; k++) u32(&b, s.spans[0][k]);
  u32(&b, 2 + s.extra_voids + (s.extra_kind >= 0) + (s.second_float != 0) + (s.second_int != 0));
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
  if (s.second_int != 0) {
    u8(&b, 4);
    u32(&b, (uint32_t)(uint64_t)s.second_int);
    u32(&b, (uint32_t)((uint64_t)s.second_int >> 32));
  }
  if (s.tables) {
    memcpy(b.data + b.len, s.tables->data, s.tables->len);
    b.len += s.tables->len;
  } else {
    u32(&b, 0);
    u32(&b, 0);
    u32(&b, 0);
    u32(&b, 0);
  }
  if (s.updates) {
    memcpy(b.data + b.len, s.updates->data, s.updates->len);
    b.len += s.updates->len;
  } else {
    u32(&b, 0);
  }
  u32(&b, s.globals);
  u32(&b, s.builtin2 ? 2 : 1);
  str(&b, s.builtin);
  u32(&b, s.builtin_arity ? s.builtin_arity : 1);
  if (s.builtin2) {
    str(&b, s.builtin2);
    u32(&b, s.builtin2_arity);
  }
  if (s.func_count) {
    u32(&b, s.func_count);
    for (uint32_t i = 0; i < s.func_count; i++) {
      const fn_spec *f = &s.funcs[i];
      size_t count_at = function(&b, f->name, f->params, 0, f->registers, f->code, f->spans, f->count, f->prelude);
      if (i == 0) b.count_at = count_at;
    }
  } else {
    u32(&b, s.helper_params ? 2 : 1);
    b.count_at =
        function(&b, "main", s.params, s.captures, s.registers, s.code, s.code_spans, s.count, s.main_prelude);
    if (s.helper_params)
      function(&b, "helper", s.helper_params, s.helper_captures, s.helper_params + s.helper_captures, helper_code,
               two_spans, 2, s.helper_prelude);
  }
  u32(&b, s.entry);
  if (s.trailing) u8(&b, 0);
  return b;
}

/* The loader holds the collector off while it loads (agc_gc_pause) and must let it go on every path, a rejection
 * included. The GC-stress build ignores the pause, so only this test catches a path that skips agc_gc_resume. */
static void assert_collector_on(void) {
#ifndef AGC_NO_GC
  assert(!GC_is_disabled());
#endif
}

static bool loads(spec s, const char *reason) {
  buffer b = build(s);
  agc_program *p;
  char error[160] = "";
  bool ok = agc_load(b.data, b.len, &p, error, sizeof error);
  assert_collector_on();
  free(b.data);
  if (!ok && !reason) fprintf(stderr, "unexpected rejection: %s\n", error);
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
  u32(&t, 0);
  u32(&t, 0);
  u32(&t, 1);
  str(&t, "E");
  u32(&t, 2);
  str(&t, "A");
  u32(&t, 0);
  str(&t, "B");
  u32(&t, arity);
  return t;
}

static void patch_u32(buffer *b, size_t at, uint32_t v) {
  for (size_t k = 0; k < 4; k++) b->data[at + k] = (uint8_t)(v >> (8 * k));
}

static void rejects(const buffer *b, const char *reason) {
  agc_program *p;
  char error[160] = "";
  assert(!agc_load(b->data, b->len, &p, error, sizeof error));
  if (!strstr(error, reason)) fprintf(stderr, "expected \"%s\", got \"%s\"\n", reason, error);
  assert(strstr(error, reason));
  assert_collector_on();
}

/* The tables are taken once and decoded without a check for each field, so a count that is too big for the rest of the
 * file must stop at read_count. The file has bytes after the tables, which the old field-by-field reads would have
 * walked into: a count of one more than there is reads the next section as a span, and is stopped by the span rules. */
static void table_count_tests(void) {
  buffer b = build(base());
  patch_u32(&b, b.spans_at, 0xFFFFFFFFu);
  rejects(&b, "span count exceeds the file");
  patch_u32(&b, b.spans_at, 4);
  rejects(&b, "span source out of range");
  patch_u32(&b, b.spans_at, 3);
  patch_u32(&b, b.count_at, 0xFFFFFFFFu);
  rejects(&b, "instruction count exceeds the file");
  patch_u32(&b, b.count_at, 6);
  rejects(&b, "instruction count exceeds the file");
  patch_u32(&b, b.count_at, 0);
  rejects(&b, "empty function");
  patch_u32(&b, b.count_at, 5);
  agc_program *p;
  char error[160] = "";
  assert(agc_load(b.data, b.len, &p, error, sizeof error));
  assert_collector_on();
  free(b.data);
}

/* A rejected load, at the first byte, in the middle and past the size limit, and a load that succeeds, all leave the
 * collector on. */
static void collector_tests(void) {
  buffer b = build(base());
  agc_program *p;
  char error[160] = "";
  assert(agc_load(b.data, b.len, &p, error, sizeof error));
  assert_collector_on();
  b.data[0] = 'X';
  assert(!agc_load(b.data, b.len, &p, error, sizeof error));
  assert_collector_on();
  b.data[0] = 'A';
  assert(!agc_load(b.data, b.len / 2, &p, error, sizeof error));
  assert_collector_on();
  assert(!agc_load(b.data, AGC_MAX_FILE_BYTES + 1, &p, error, sizeof error));
  assert_collector_on();
  free(b.data);
}

/* The line index decides which columns a span may name: a line of N characters takes the columns 1 to N + 1. The
 * texts have lines of every length around the eight-byte words that the indexing reads, and multi-byte characters. */
static void expect_columns(const char *text, const uint32_t *chars, uint32_t lines) {
  for (uint32_t line = 1; line <= lines + 1; line++) {
    for (uint32_t column = 1; column <= 22; column++) {
      spec s = base();
      s.second_source = text;
      s.spans[2][0] = 1;
      s.spans[2][1] = s.spans[2][3] = line;
      s.spans[2][2] = s.spans[2][4] = column;
      if (line > lines)
        assert(!loads(s, "line out of range"));
      else if (column <= chars[line - 1] + 1)
        assert(loads(s, NULL));
      else
        assert(!loads(s, "column out of range"));
    }
  }
}

static void line_index_tests(void) {
  char ascii[512];
  uint32_t ascii_chars[24];
  size_t at = 0;
  uint32_t lines = 0;
  for (uint32_t len = 0; len <= 18; len++) {
    memset(ascii + at, 'x', len);
    at += len;
    ascii[at++] = '\n';
    ascii_chars[lines++] = len;
  }
  memcpy(ascii + at, "tail", 5);
  ascii_chars[lines++] = 4;
  expect_columns(ascii, ascii_chars, lines);

  /* a (1), empty (0), e-acute twice (2), a mix of 1 to 4 byte characters (8), an empty last line (0) */
  static const uint32_t mixed_chars[] = {1, 0, 2, 8, 0};
  expect_columns("a\n\n\xC3\xA9\xC3\xA9\nab\xC3\xA9" "cd\xE2\x82\xAC\xF0\x9F\x98\x80z\n", mixed_chars, 5);
  static const uint32_t wide_chars[] = {9, 3};
  expect_columns("\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\xC3\xA9\n\xF0\x9F\x98\x80\xF0\x9F\x98\x80\xF0\x9F\x98\x80", wide_chars, 2);
  static const uint32_t none_chars[] = {0};
  expect_columns("", none_chars, 1);
}

static bool loads_tables(uint32_t arity, const char *reason) {
  buffer t = make_tables(arity);
  spec s = base();
  s.tables = &t;
  bool ok = loads(s, reason);
  free(t.data);
  return ok;
}

/* The front end that the binary carries may name another Agentica version (the stages of a bootstrap do); only the
 * format version and the rest of the file are checked. A user program never loads this way. */
static void front_end_tests(void) {
  char error[160] = "";
  agc_program *p;
  spec s = base();
  s.agentica = "0.0.0-other";
  buffer b = build(s);
  assert(!agc_load(b.data, b.len, &p, error, sizeof error));
  assert(agc_load_front_end(b.data, b.len, &p, error, sizeof error, NULL));
  free(b.data);
  s.version = AGC_FORMAT_VERSION + 1;
  b = build(s);
  assert(!agc_load_front_end(b.data, b.len, &p, error, sizeof error, NULL) && strstr(error, "format version"));
  free(b.data);
  s = base();
  s.trailing = true;
  b = build(s);
  assert(!agc_load_front_end(b.data, b.len, &p, error, sizeof error, NULL) && strstr(error, "trailing bytes"));
  free(b.data);
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

/* An Updates section: the count, then the words of every entry (struct index,
   field count, the field indexes), written as given so a case can be wrong. */
static buffer make_updates(uint32_t count, const uint32_t *words, size_t n) {
  buffer u;
  u.data = malloc(4 + 4 * n);
  assert(u.data);
  u.len = 0;
  u32(&u, count);
  for (size_t i = 0; i < n; i++) u32(&u, words[i]);
  return u;
}

/* The two updates the cases use, over the structs of make_tables: Q.b, then Q.a and Q.b. */
static const uint32_t good_updates[] = {1, 1, 1, 1, 2, 0, 1};

/* The base file with the tables of make_tables and the given Updates section; code replaces the base code. */
static spec updates_spec(const buffer *tables, const buffer *updates, const agc_instr *code, const uint32_t *spans,
                         uint32_t count, uint32_t registers) {
  spec s = base();
  s.tables = tables;
  s.updates = updates;
  if (code) {
    s.code = code;
    s.code_spans = spans;
    s.count = count;
    s.registers = registers;
  }
  return s;
}

static bool loads_updates(uint32_t count, const uint32_t *words, size_t n, const char *reason) {
  buffer t = make_tables(1);
  buffer u = make_updates(count, words, n);
  bool ok = loads(updates_spec(&t, &u, NULL, NULL, 0, 0), reason);
  free(t.data);
  free(u.data);
  return ok;
}

static bool loads_with_updates(const agc_instr *code, const uint32_t *spans, uint32_t count, uint32_t registers,
                               const char *reason) {
  buffer t = make_tables(1);
  buffer u = make_updates(2, good_updates, sizeof good_updates / sizeof good_updates[0]);
  bool ok = loads(updates_spec(&t, &u, code, spans, count, registers), reason);
  free(t.data);
  free(u.data);
  return ok;
}

static agc_outcome run_with_updates(const agc_instr *code, const uint32_t *spans, uint32_t count, uint32_t registers,
                                    int64_t seven, FILE *out) {
  buffer t = make_tables(1);
  buffer u = make_updates(2, good_updates, sizeof good_updates / sizeof good_updates[0]);
  spec s = updates_spec(&t, &u, code, spans, count, registers);
  s.extra_kind = 4;
  s.extra_int = seven;
  agc_outcome outcome = run_spec(s, out);
  free(t.data);
  free(u.data);
  return outcome;
}

static bool loads_code(const agc_instr *code, const uint32_t *spans, uint32_t count, const char *reason) {
  spec s = base();
  s.code = code;
  s.code_spans = spans;
  s.count = count;
  return loads(s, reason);
}

static buffer type_tables(int which) {
  buffer t;
  t.data = malloc(70000);
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
  if (which == 7) {
    u32(&t, 65536);
    for (uint32_t k = 0; k < 65536; k++) u8(&t, 0);
  } else if (which == 10 || which == 12) {
    uint32_t lists = which == 10 ? 1025 : 1024;
    u32(&t, lists + 1);
    u8(&t, 0);
    for (uint32_t k = 0; k < lists; k++) {
      u8(&t, 4);
      u32(&t, k);
    }
  } else {
    u32(&t, which == 8 ? 0x10000000 : 3);
    u8(&t, 0);
    u8(&t, which == 1 ? 7 : 4);
    u32(&t, which == 2 ? 1 : 0);
    u8(&t, 6);
    u32(&t, which == 3 ? 2 : 0);
  }
  u32(&t, which == 6 ? 1 : 2);
  if (which != 5 && which != 6) {
    u32(&t, which == 9 ? 5 : 0);
    str(&t, "P");
    u32(&t, which == 4 ? 3 : 2);
  }
  u32(&t, 1);
  str(&t, which == 11 ? "P" : "@1::Q");
  u32(&t, 1);
  u32(&t, 0);
  if (which == 5) {
    u32(&t, 0);
    str(&t, "P");
    u32(&t, 2);
  }
  u32(&t, 0);
  return t;
}

static bool loads_types(int which, const char *reason) {
  buffer t = type_tables(which);
  spec s = base();
  s.tables = &t;
  bool ok = loads(s, reason);
  free(t.data);
  return ok;
}

/* Globals (module constants, docs/future/44-module-constants.md §44.8). The two functions of the files below
   take 4 registers each and every instruction uses span 0. */
static const uint32_t zero_spans[16] = {0};

/* A file of two functions with the given number of Globals slots and the entry at index `entry`. Constant 2 is
   the String "ab". */
static spec pair_spec(const agc_instr *first, uint32_t first_count, const agc_instr *second, uint32_t second_count,
                      uint32_t globals, uint32_t entry) {
  spec s = base();
  s.extra_kind = 6;
  s.extra_string = "ab";
  s.globals = globals;
  s.entry = entry;
  s.func_count = 2;
  s.funcs[0] = (fn_spec){"first", 0, 4, first, zero_spans, first_count, 0};
  s.funcs[1] = (fn_spec){"second", 0, 4, second, zero_spans, second_count, 0};
  return s;
}

/* TRY_STEP in the block (function 1) of the builtin that main calls: the block makes error(K[2]) and fails through
   TRY_STEP. Only a Lazy terminal may be the frame below it, so any other builtin is RUNTIME-INTERNAL. */
static agc_outcome try_step_in_block(const char *builtin, uint32_t arity, const agc_instr *main_code, uint32_t count,
                                     uint32_t block_params, const char *text, int64_t number) {
  static const agc_instr block[] = {{AGC_OP_STEP, 1, 0, 0},
                                    {AGC_OP_CONST, 0, 2, 0},
                                    {AGC_OP_CALL_BUILTIN, 0, 1, 0},
                                    {AGC_OP_TRY_STEP, 1, 0, 0},
                                    {AGC_OP_RETURN, 1, 0, 0}};
  spec s = base();
  s.extra_kind = 6;
  s.extra_string = text;
  s.second_int = number;
  s.builtin = builtin;
  s.builtin_arity = arity;
  s.builtin2 = "error";
  s.builtin2_arity = 1;
  s.more_spans = arity; /* CALL_BUILTIN uses the spans after its own, one per argument */
  s.func_count = 2;
  s.funcs[0] = (fn_spec){"main", 0, 4, main_code, zero_spans, count, 0};
  s.funcs[1] = (fn_spec){"block", block_params, 2, block, zero_spans, 5, 0};
  return run_spec(s, stdout);
}

static void try_step_outside_lazy_tests(void) {
  /* List.map is a native loop, not a stepper. */
  static const agc_instr map_main[] = {{AGC_OP_STEP, 1, 0, 0},         {AGC_OP_CONST, 1, 2, 0},
                                       {AGC_OP_LIST, 0, 1, 1},         {AGC_OP_CLOSURE, 1, 1, 0},
                                       {AGC_OP_CALL_BUILTIN, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  agc_outcome map = try_step_in_block("List.map", 2, map_main, 6, 1, "e", 0);
  assert(map.kind == AGC_FAILED && strcmp(map.code, "RUNTIME-INTERNAL") == 0);
#if defined(__linux__) || defined(__APPLE__)
  /* File.each_line is a stepper, but not a Lazy terminal: its block must not escape. */
  const char *tmp = getenv("TMPDIR");
  char path[4096];
  snprintf(path, sizeof path, "%s/agc-try-step-XXXXXX", tmp && *tmp ? tmp : "/tmp");
  int fd = mkstemp(path);
  assert(fd >= 0);
  assert(write(fd, "x\n", 2) == 2);
  close(fd);
  static const agc_instr each_main[] = {{AGC_OP_STEP, 1, 0, 0},     {AGC_OP_CONST, 0, 2, 0},
                                        {AGC_OP_CONST, 1, 3, 0},    {AGC_OP_CONST, 2, 3, 0},
                                        {AGC_OP_CLOSURE, 3, 1, 0},  {AGC_OP_CALL_BUILTIN, 0, 0, 0},
                                        {AGC_OP_RETURN, 0, 0, 0}};
  agc_outcome each = try_step_in_block("File.each_line", 4, each_main, 7, 1, path, 60000);
  remove(path);
  assert(each.kind == AGC_FAILED && strcmp(each.code, "RUNTIME-INTERNAL") == 0);
#endif
}

/* The slot is the only reference to its String once the registers are cleared, so it must stay readable across
   collections: junk of the String's size class (0xAB) takes its place if the collector frees it. Not run under
   AGC_NO_GC, which never frees. */
static void expect_global_alive(agc_vm *vm, const agc_program *p) {
  agc_gc_info info;
  if (!agc_gc_stats(&info)) return;
  if (vm->rt->main->regs) memset(vm->rt->main->regs, 0, vm->rt->main->reg_capacity * sizeof(agc_value));
  uint64_t stop = info.collections + 3;
  for (size_t round = 0; info.collections < stop; round++) {
    assert(round < 4000000);
    memset(agc_alloc_atomic(24), 0xAB, 24);
    agc_gc_stats(&info);
  }
  for (size_t round = 0; round < 20000; round++) memset(agc_alloc_atomic(24), 0xAB, 24);
  const agc_string *text = agc_as_string(vm, p->globals[1]);
  assert(text->bytes == 4 && memcmp(text->data, "abab", 4) == 0);
}

static void globals_tests(void) {
  /* The entry sets slot 0 to the Int 1 and slot 1 to the String "abab", then tail-calls main; main clears the
     registers the entry used and prints both slots. */
  static const agc_instr start_code[] = {
    {AGC_OP_STEP, 1, 0, 0},    {AGC_OP_CONST, 0, 0, 0},      {AGC_OP_GLOBAL_SET, 0, 0, 0}, {AGC_OP_CONST, 1, 2, 0},
    {AGC_OP_CONCAT, 1, 1, 1},  {AGC_OP_GLOBAL_SET, 1, 1, 0}, {AGC_OP_TAIL_CALL, 0, 1, 0},  {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr read_code[] = {
    {AGC_OP_STEP, 3, 0, 0},         {AGC_OP_CONST, 1, 1, 0},  {AGC_OP_GLOBAL, 0, 0, 0},     {AGC_OP_CALL_BUILTIN, 0, 0, 0},
    {AGC_OP_GLOBAL, 0, 1, 0},       {AGC_OP_CALL_BUILTIN, 0, 0, 0}, {AGC_OP_CONST, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  buffer used = build(pair_spec(start_code, 8, read_code, 8, 2, 0));
  char error[160];
  agc_program *p;
  for (size_t n = 0; n < used.len; n++) {
    agc_program *q;
    assert(!agc_load(used.data, n, &q, error, sizeof error));
  }
  assert(agc_load(used.data, used.len, &p, error, sizeof error));
  free(used.data);
  assert(p->global_count == 2 && p->globals[0].tag == AGC_T_VOID && p->globals[1].tag == AGC_T_VOID);
  FILE *out = tmpfile();
  assert(out);
  agc_vm vm;
  agc_vm_init(&vm, p, out, out, INT64_MAX);
  assert(agc_vm_run(&vm).kind == AGC_DONE);
  expect_output(out, "1\nabab\n");
  expect_global_alive(&vm, p);

  /* The count: 65535 slots load, one more does not, and the array is charged to the load budget. */
  spec s = base();
  s.globals = AGC_MAX_GLOBALS;
  assert(loads(s, NULL));
  s.globals = AGC_MAX_GLOBALS + 1;
  assert(!loads(s, "too many globals"));
  s.globals = UINT32_MAX;
  assert(!loads(s, "too many globals"));
  s = base();
  s.extra_voids = 60000;
  s.globals = 1000;
  assert(loads(s, NULL));
  s.globals = AGC_MAX_GLOBALS;
  assert(!loads(s, "too much memory"));

  /* Slot and register operands. A count of zero has no slot, so no GLOBAL and no GLOBAL_SET loads. */
  static const agc_instr read_one[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_GLOBAL, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr write_one[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_GLOBAL_SET, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr read_wide[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_GLOBAL, 0, 0, 1}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr read_last[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_GLOBAL, 0, 65534, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr read_far[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_GLOBAL, 4, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr write_far[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_GLOBAL_SET, 4, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(loads(pair_spec(read_one, 3, helper_code, 2, 2, 0), NULL));
  assert(!loads(pair_spec(read_one, 3, helper_code, 2, 1, 0), "global index out of range"));
  assert(!loads(pair_spec(read_one, 3, helper_code, 2, 0, 0), "global index out of range"));
  assert(loads(pair_spec(write_one, 4, helper_code, 2, 2, 0), NULL));
  assert(!loads(pair_spec(write_one, 4, helper_code, 2, 1, 0), "global index out of range"));
  assert(!loads(pair_spec(write_one, 4, helper_code, 2, 0, 0), "global index out of range"));
  assert(!loads(pair_spec(read_wide, 3, helper_code, 2, AGC_MAX_GLOBALS, 0), "global index out of range"));
  assert(loads(pair_spec(read_last, 3, helper_code, 2, AGC_MAX_GLOBALS, 0), NULL));
  assert(!loads(pair_spec(read_far, 3, helper_code, 2, 1, 0), "register out of range"));
  assert(!loads(pair_spec(write_far, 3, helper_code, 2, 1, 0), "register out of range"));

  /* Only the entry writes, and in straight-line code. */
  static const agc_instr enter_code[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_TAIL_CALL, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr set_code[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_GLOBAL_SET, 0, 0, 0}, {AGC_OP_CONST, 0, 1, 0},
    {AGC_OP_RETURN, 0, 0, 0}};
  assert(loads(pair_spec(set_code, 5, helper_code, 2, 1, 0), NULL));
  assert(loads(pair_spec(helper_code, 2, set_code, 5, 1, 1), NULL));
  assert(!loads(pair_spec(enter_code, 3, set_code, 5, 1, 0), "GLOBAL_SET outside the entry"));
  assert(!loads(pair_spec(set_code, 5, set_code, 5, 1, 0), "GLOBAL_SET outside the entry"));
  static const agc_instr set_loop[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_GLOBAL_SET, 0, 0, 0}, {AGC_OP_JUMP, 0, 0, 0}};
  static const agc_instr loop_then_set[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_JUMP, 0, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_GLOBAL_SET, 0, 0, 0},
    {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr set_then_skip[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_GLOBAL_SET, 0, 0, 0}, {AGC_OP_JUMP, 0, 5, 0},
    {AGC_OP_CONST, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr spin_code[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_JUMP, 0, 0, 0}};
  assert(!loads(pair_spec(set_loop, 4, helper_code, 2, 1, 0), "GLOBAL_SET in a function with a backward jump"));
  assert(!loads(pair_spec(loop_then_set, 5, helper_code, 2, 1, 0), "GLOBAL_SET in a function with a backward jump"));
  assert(loads(pair_spec(set_then_skip, 6, helper_code, 2, 1, 0), NULL));
  assert(loads(pair_spec(enter_code, 3, spin_code, 2, 1, 0), NULL));

  /* With slots, nothing may run the entry again. Without, it is plain main and may be called. */
  static const agc_instr call_entry[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CALL, 0, 0, 0}, {AGC_OP_CONST, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr tail_entry[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_TAIL_CALL, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr closure_entry[] = {{AGC_OP_CLOSURE, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr call_second[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CALL, 0, 1, 0}, {AGC_OP_CONST, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  const char *entry_reason = "entry function of a file with globals";
  assert(!loads(pair_spec(enter_code, 3, call_entry, 4, 1, 0), entry_reason));
  assert(!loads(pair_spec(enter_code, 3, tail_entry, 3, 1, 0), entry_reason));
  assert(!loads(pair_spec(enter_code, 3, closure_entry, 2, 1, 0), entry_reason));
  assert(!loads(pair_spec(call_second, 4, helper_code, 2, 1, 1), entry_reason));
  assert(loads(pair_spec(call_second, 4, helper_code, 2, 1, 0), NULL));
  assert(loads(pair_spec(enter_code, 3, call_entry, 4, 0, 0), NULL));
  assert(loads(pair_spec(enter_code, 3, tail_entry, 3, 0, 0), NULL));
  assert(loads(pair_spec(enter_code, 3, closure_entry, 2, 0, 0), NULL));
  assert(loads(pair_spec(call_second, 4, helper_code, 2, 0, 1), NULL));

  /* main() inside main with no constants loads and runs: it recurses until the step limit. */
  static const agc_instr recurse[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CALL, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  s = base();
  s.code = recurse;
  s.code_spans = zero_spans;
  s.count = 3;
  buffer recursive = build(s);
  assert(agc_load(recursive.data, recursive.len, &p, error, sizeof error));
  free(recursive.data);
  agc_vm_init(&vm, p, stdout, stdout, 50);
  agc_outcome spun = agc_vm_run(&vm);
  assert(spun.kind == AGC_FAILED && strcmp(spun.code, "RUNTIME-STEP-LIMIT") == 0);
  s.globals = 1;
  assert(!loads(s, entry_reason));

  /* A slot that was never set is RUNTIME-INTERNAL, whichever slot a hand-made file reads. */
  static const agc_instr read_unset[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_GLOBAL_SET, 0, 0, 0}, {AGC_OP_GLOBAL, 0, 1, 0},
    {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr read_set[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_GLOBAL_SET, 0, 0, 0}, {AGC_OP_GLOBAL, 1, 0, 0},
    {AGC_OP_RETURN, 0, 0, 0}};
  agc_outcome unset = run_spec(pair_spec(read_unset, 5, helper_code, 2, 2, 0), stdout);
  assert(unset.kind == AGC_FAILED && strcmp(unset.code, "RUNTIME-INTERNAL") == 0);
  assert(strstr(unset.message, "before it was set"));
  assert(run_spec(pair_spec(read_set, 5, helper_code, 2, 2, 0), stdout).kind == AGC_DONE);
}

/* Runs agc_program_set_source_root over a program that stores `names`; the joined names go to `joined`. */
static bool join_names(agc_string *const *names, size_t count, const char *root, agc_string **joined) {
  agc_program p;
  memset(&p, 0, sizeof p);
  agc_source sources[8];
  assert(count <= sizeof sources / sizeof sources[0]);
  memset(sources, 0, sizeof sources);
  for (size_t k = 0; k < count; k++) sources[k].name = names[k];
  p.sources = sources;
  p.source_count = (uint32_t)count;
  size_t root_chars;
  assert(agc_utf8_chars((const uint8_t *)root, strlen(root), &root_chars));
  bool ok = agc_program_set_source_root(&p, root, root_chars);
  for (size_t k = 0; k < count; k++) joined[k] = sources[k].name;
  return ok;
}

static bool is_name(const agc_string *name, const char *expected) {
  size_t chars;
  return name->bytes == strlen(expected) && memcmp(name->data, expected, name->bytes) == 0 &&
         agc_utf8_chars((const uint8_t *)name->data, name->bytes, &chars) && name->chars == chars;
}

/* "rrr...r" of `bytes` bytes, with a "/" as its last byte when `slash` is set. */
static char *long_root(size_t bytes, bool slash) {
  char *root = malloc(bytes + 1);
  assert(root);
  memset(root, 'r', bytes);
  if (slash) root[bytes - 1] = '/';
  root[bytes] = '\0';
  return root;
}

/* The bytes that the root adds, root + "/" per joined name, may be SOURCE_ROOT_BUDGET (64 MiB) and not more. Two
 * names of `half` bytes each reach the cap exactly, so a root of half - 1 bytes plus its "/" is on it. */
static void source_root_budget_tests(void) {
  size_t half = (size_t)1 << 25;
  agc_string *two[] = {agc_make_string("m.agc", 5, 5), agc_make_string("n.agc", 5, 5)};
  agc_string *joined[2];
  static const struct {
    int delta; /* root bytes = half + delta */
    bool slash;
    bool passes;
  } cases[] = {
    {-1, false, true},  /* half - 1 bytes + "/" per name: exactly the cap */
    {0, false, false},  /* one byte over: the "/" is counted */
    {0, true, true},    /* half bytes ending in "/": no extra "/", exactly the cap */
    {1, true, false},   /* one byte over, ending in "/" */
  };
  for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
    size_t bytes = half + (size_t)(cases[c].delta);
    char *root = long_root(bytes, cases[c].slash);
    bool ok = join_names(two, 2, root, joined);
    assert(ok == cases[c].passes);
    if (ok) {
      /* One "/" between the root and the name, whether the root ended in one or not. */
      size_t expected = bytes + (cases[c].slash ? 0 : 1) + 5;
      assert(joined[0]->bytes == expected && joined[1]->bytes == expected);
      assert(memcmp(joined[0]->data, root, bytes) == 0 && joined[0]->data[expected - 6] == '/');
      assert(memcmp(joined[0]->data + expected - 5, "m.agc", 5) == 0);
    } else {
      assert(joined[0] == two[0] && joined[1] == two[1]);
    }
    free(root);
  }
  /* std/ and absolute names add nothing, so they are not in the count: one joined name on the cap passes. */
  agc_string *mixed[] = {agc_make_string("std/a.agc", 9, 9), agc_make_string("m.agc", 5, 5),
                               agc_make_string("std/b.agc", 9, 9), agc_make_string("/abs.agc", 8, 8)};
  agc_string *mixed_joined[4];
  char *root = long_root((size_t)1 << 26, true);
  assert(join_names(mixed, 4, root, mixed_joined));
  assert(mixed_joined[0] == mixed[0] && mixed_joined[2] == mixed[2] && mixed_joined[3] == mixed[3]);
  assert(mixed_joined[1]->bytes == ((size_t)1 << 26) + 5);
  free(root);
}

/* --source-root: relative names that are not under std/ go under the root; std/, absolute and empty-root cases stay.
 * The last three names are the edges of the "./" rule: a lone ".", "./" and the empty name. */
static void source_root_tests(void) {
  enum { NAMES = 8 };
  static const char *const names[NAMES] = {"main.agc", "std/queue.agc", "stdx.agc", "/abs/x.agc", "./std/helper.agc",
                                           ".", "./", ""};
  static const struct {
    const char *root;
    const char *expected[NAMES];
  } cases[] = {
    {"", {"main.agc", "std/queue.agc", "stdx.agc", "/abs/x.agc", "./std/helper.agc", ".", "./", ""}},
    {"a", {"a/main.agc", "std/queue.agc", "a/stdx.agc", "/abs/x.agc", "a/std/helper.agc", "a/.", "a/", "a/"}},
    {"a/", {"a/main.agc", "std/queue.agc", "a/stdx.agc", "/abs/x.agc", "a/std/helper.agc", "a/.", "a/", "a/"}},
    {"/", {"/main.agc", "std/queue.agc", "/stdx.agc", "/abs/x.agc", "/std/helper.agc", "/.", "/", "/"}},
    {"\xC3\xA9", {"\xC3\xA9/main.agc", "std/queue.agc", "\xC3\xA9/stdx.agc", "/abs/x.agc",
                  "\xC3\xA9/std/helper.agc", "\xC3\xA9/.", "\xC3\xA9/", "\xC3\xA9/"}},
  };
  for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
    agc_string *stored[NAMES];
    agc_string *joined[NAMES];
    for (size_t k = 0; k < NAMES; k++) stored[k] = agc_make_string(names[k], strlen(names[k]), strlen(names[k]));
    assert(join_names(stored, NAMES, cases[c].root, joined));
    for (size_t k = 0; k < NAMES; k++) assert(is_name(joined[k], cases[c].expected[k]));
  }
  /* The "./" test reads the length, not the memory behind it: a one-byte "." whose next byte is "/" stays ".". */
  agc_string *dot = agc_new_string(2, 2);
  memcpy(dot->data, "./", 2);
  dot->bytes = 1;
  dot->chars = 1;
  agc_string *lone[] = {dot};
  agc_string *lone_joined[1];
  assert(join_names(lone, 1, "a", lone_joined));
  assert(is_name(lone_joined[0], "a/."));
  source_root_budget_tests();
}


/* The prelude flag of version 6 (docs/future/25-ruby-typed-idioms.md §25.6): what the loader checks, and the span a
 * runtime error of a prelude function is reported at. Constant 0 is the Int 1 and constant 2 the String below, which
 * is both the code and the message of every __fail_arg call. */
static const char fail_code[] = "RUNTIME-INVALID-COUNT";

/* A prelude function of two parameters that calls __fail_arg(code, 1, message): its registers 2 to 4 are the window. */
static const agc_instr fail_arg_code[] = {
  {AGC_OP_STEP, 1, 0, 0},    {AGC_OP_CONST, 2, 2, 0},        {AGC_OP_CONST, 3, 0, 0},
  {AGC_OP_CONST, 4, 2, 0},   {AGC_OP_CALL_BUILTIN, 2, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
static const uint32_t fail_arg_spans[] = {0, 0, 0, 0, 0, 0};

/* main: STEP, two arguments, CALL of function 1 (the call's span is span 0, so its arguments are spans 1 and 2),
 * RETURN. */
static const agc_instr call_two[] = {
  {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_CONST, 1, 0, 0}, {AGC_OP_CALL, 0, 1, 0},
  {AGC_OP_RETURN, 0, 0, 0}};
static const uint32_t call_two_spans[] = {1, 1, 1, 0, 1};

static spec prelude_spec(const agc_instr *callee, const uint32_t *callee_spans, uint32_t callee_count,
                         uint32_t callee_registers) {
  spec s = base();
  s.more_spans = 2;
  s.extra_kind = 6;
  s.extra_string = fail_code;
  s.builtin = "__fail_arg";
  s.builtin_arity = 3;
  s.func_count = 2;
  s.funcs[0] = (fn_spec){"main", 0, 3, call_two, call_two_spans, 5, 0};
  s.funcs[1] = (fn_spec){"find", 2, callee_registers, callee, callee_spans, callee_count, 1};
  return s;
}

static agc_outcome run_quiet(spec s) {
  FILE *out = tmpfile();
  assert(out);
  agc_outcome outcome = run_spec(s, out);
  fclose(out);
  return outcome;
}

static void prelude_tests(void) {
  char error[160] = "";
  agc_program *p;

  /* The flag is 0 or 1, and a file of version 5 has none: both loaders read it, with no prelude function. */
  spec s = prelude_spec(fail_arg_code, fail_arg_spans, 6, 5);
  assert(loads(s, NULL));
  s.funcs[1].prelude = 2;
  assert(!loads(s, "bad prelude flag"));
  s = base();
  s.version = AGC_FORMAT_PREVIOUS;
  buffer old = build(s);
  assert(agc_load(old.data, old.len, &p, error, sizeof error));
  assert(!p->functions[0].prelude);
  assert(agc_load_front_end(old.data, old.len, &p, error, sizeof error, NULL));
  free(old.data);
  s.version = AGC_FORMAT_PREVIOUS - 1;
  old = build(s);
  assert(!agc_load(old.data, old.len, &p, error, sizeof error) && strstr(error, "format version"));
  free(old.data);
  flags_written = true;

  /* __fail_arg belongs to prelude functions only. */
  s = prelude_spec(fail_arg_code, fail_arg_spans, 6, 5);
  s.funcs[1].prelude = 0;
  assert(!loads(s, "prelude-only builtin outside the prelude"));

  /* A CALL of a prelude function carries the spans of its arguments after its own: they must exist. */
  static const uint32_t last_span[] = {1, 1, 1, 4, 1};
  s = prelude_spec(fail_arg_code, fail_arg_spans, 6, 5);
  s.funcs[0].spans = last_span;
  assert(!loads(s, "span index out of range"));
  s.funcs[1].prelude = 0;
  s.builtin = "puts";
  s.builtin_arity = 1;
  static const agc_instr puts_helper[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  s.funcs[1].code = puts_helper;
  s.funcs[1].count = 2;
  s.funcs[1].spans = two_spans;
  assert(loads(s, NULL));

  /* The error is reported at the argument of the call the user wrote: argument 1 is span 2, since the call is span 0.
   The stack shows main and no frame of the prelude. */
  s = prelude_spec(fail_arg_code, fail_arg_spans, 6, 5);
  agc_outcome failed = run_quiet(s);
  assert(failed.kind == AGC_FAILED && strcmp(failed.code, fail_code) == 0 && failed.span == 2);
  assert(!failed.stack.shown || (failed.stack.count == 1 && failed.stack.lines[0].function == 0));

  /* An argument the call does not have (6 of a call of 2 arguments) falls back to the call span. */
  static const agc_instr far_index[] = {
    {AGC_OP_STEP, 1, 0, 0},    {AGC_OP_CONST, 2, 2, 0},   {AGC_OP_ADD_I, 3, 1, 1}, {AGC_OP_ADD_I, 3, 3, 1},
    {AGC_OP_ADD_I, 3, 3, 1},   {AGC_OP_ADD_I, 3, 3, 1},   {AGC_OP_ADD_I, 3, 3, 1}, {AGC_OP_CONST, 4, 2, 0},
    {AGC_OP_CALL_BUILTIN, 2, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t far_spans[] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
  s = prelude_spec(far_index, far_spans, 10, 5);
  agc_outcome past = run_quiet(s);
  assert(past.kind == AGC_FAILED && strcmp(past.code, fail_code) == 0 && past.span == 0);

  /* A tail call into the prelude, or a call through a function value, has no argument spans: the call's span. */
  static const agc_instr via_value[] = {
    {AGC_OP_STEP, 1, 0, 0},  {AGC_OP_CLOSURE, 0, 1, 0}, {AGC_OP_CONST, 1, 0, 0},
    {AGC_OP_CONST, 2, 0, 0}, {AGC_OP_CALL_VALUE, 0, 2, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t via_value_spans[] = {1, 1, 1, 1, 1, 1};
  s = prelude_spec(fail_arg_code, fail_arg_spans, 6, 5);
  s.funcs[0] = (fn_spec){"main", 0, 4, via_value, via_value_spans, 6, 0};
  agc_outcome by_value = run_quiet(s);
  assert(by_value.kind == AGC_FAILED && strcmp(by_value.code, fail_code) == 0 && by_value.span == 1);
  static const agc_instr tail[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_CONST, 1, 0, 0}, {AGC_OP_TAIL_CALL, 0, 1, 0},
    {AGC_OP_RETURN, 0, 0, 0}};
  s = prelude_spec(fail_arg_code, fail_arg_spans, 6, 5);
  s.funcs[0] = (fn_spec){"main", 0, 3, tail, call_two_spans, 5, 0};
  agc_outcome by_tail = run_quiet(s);
  assert(by_tail.kind == AGC_FAILED && by_tail.span == 0);

  /* No frame of the user below the run (a crafted file that flags main): the span stays the instruction's own. */
  s = prelude_spec(fail_arg_code, fail_arg_spans, 6, 5);
  static const agc_instr main_fails[] = {
    {AGC_OP_STEP, 1, 0, 0},  {AGC_OP_CONST, 0, 2, 0},        {AGC_OP_CONST, 1, 0, 0},
    {AGC_OP_CONST, 2, 2, 0}, {AGC_OP_CALL_BUILTIN, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t main_fails_spans[] = {1, 1, 1, 1, 1, 1};
  s.funcs[0] = (fn_spec){"main", 0, 3, main_fails, main_fails_spans, 6, 1};
  agc_outcome crafted = run_quiet(s);
  assert(crafted.kind == AGC_FAILED && strcmp(crafted.code, fail_code) == 0 && crafted.span == 1);
  assert(!crafted.stack.shown);

  /* The code must start with RUNTIME-: anything else is RUNTIME-INTERNAL, whatever the file asks for. */
  static const char other_code[] = "CHECK-TYPE-MISMATCH";
  s = prelude_spec(fail_arg_code, fail_arg_spans, 6, 5);
  s.extra_string = other_code;
  agc_outcome wrong = run_quiet(s);
  assert(wrong.kind == AGC_FAILED && strcmp(wrong.code, "RUNTIME-INTERNAL") == 0);
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
  front_end_tests();
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
  s.spans[2][0] = 1;
  assert(!loads(s, "span source out of range"));
  s.second_source = "abc";
  assert(!loads(s, "line out of range"));
  s.spans[2][1] = 1;
  s.spans[2][2] = 2;
  s.spans[2][3] = 1;
  s.spans[2][4] = 4;
  assert(loads(s, NULL));
  s.spans[2][4] = 5;
  assert(!loads(s, "column out of range"));
  s.spans[2][4] = 4;
  s.spans[2][0] = 2;
  assert(!loads(s, "span source out of range"));

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
  assert(spun.kind == AGC_FAILED && strcmp(spun.code, "RUNTIME-STEP-LIMIT") == 0 && spun.span == 1 && vm.task->depth == 1);
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

  /* The fused STEP forms are the loader's own: a file that holds one is rejected, and a checked STEP before a CONST
     becomes one while the CONST stays in place; a STEP before an opcode with no fused form stays a STEP. */
  for (uint32_t op = AGC_OP_COUNT; op < AGC_FUSED_END; op++) {
    const agc_instr fused[] = {{(uint16_t)op, 1, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
    assert(!loads_code(fused, two_spans, 2, "unknown opcode"));
  }
  s = base();
  s.code = back_to_step;
  s.code_spans = three_spans;
  s.count = 3;
  buffer fusable = build(s);
  assert(agc_load(fusable.data, fusable.len, &p, error, sizeof error));
  free(fusable.data);
  assert(p->functions[p->entry].code[0].op == AGC_FUSED_STEP_CONST);
  assert(p->functions[p->entry].code[1].op == AGC_OP_CONST && p->functions[p->entry].code[2].op == AGC_OP_JUMP);
  s = base();
  s.code = builtin_window;
  s.code_spans = builtin_spans;
  s.count = 4;
  s.registers = 2;
  buffer unfused = build(s);
  assert(agc_load(unfused.data, unfused.len, &p, error, sizeof error));
  free(unfused.data);
  assert(p->functions[p->entry].code[0].op == AGC_OP_STEP);
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
    u32(&wide, 0);
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
  u32(&many, 0);
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
  static const agc_instr bad_try_step[] = {{AGC_OP_TRY_STEP, 4, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_try_step, two_spans, 2, 4, "register out of range"));
  static const agc_instr bad_try_step_source[] = {{AGC_OP_TRY_STEP, 0, 4, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_try_step_source, two_spans, 2, 4, "register out of range"));
  static const agc_instr wide_try_step[] = {{AGC_OP_TRY_STEP, 0, 65535, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(wide_try_step, two_spans, 2, 4, "register out of range"));
  static const agc_instr try_step_int[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_TRY_STEP, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  agc_outcome step_not_result = run_with_tables(try_step_int, confused_spans, 4, stdout);
  assert(step_not_result.kind == AGC_FAILED && strcmp(step_not_result.code, "RUNTIME-INTERNAL") == 0);
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
  agc_outcome emptied = run_spec(s, stdout);
  assert(emptied.kind == AGC_FAILED && strcmp(emptied.code, "RUNTIME-INTERNAL") == 0);
  /* A failed TRY_STEP must return to a Lazy terminal; in main no stepper is below it. */
  static const agc_instr try_step_in_main[] = {
    {AGC_OP_STEP, 1, 0, 0},     {AGC_OP_CONST, 0, 2, 0}, {AGC_OP_CALL_BUILTIN, 0, 0, 0},
    {AGC_OP_TRY_STEP, 1, 0, 0}, {AGC_OP_NOT, 0, 0, 0},   {AGC_OP_RETURN, 0, 0, 0}};
  s.code = try_step_in_main;
  agc_outcome outside = run_spec(s, stdout);
  assert(outside.kind == AGC_FAILED && strcmp(outside.code, "RUNTIME-INTERNAL") == 0);
  try_step_outside_lazy_tests();

  static const agc_instr bad_map_target[] = {{AGC_OP_MAP, 4, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_map_target, two_spans, 2, 4, "register out of range"));
  static const agc_instr bad_map_start[] = {{AGC_OP_MAP, 0, 4, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_map_start, two_spans, 2, 4, "register out of range"));
  static const agc_instr bad_map_window[] = {{AGC_OP_MAP, 0, 1, 2}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_map_window, two_spans, 2, 4, "register range out of range"));
  static const agc_instr huge_map_window[] = {{AGC_OP_MAP, 0, 0, 65535}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(huge_map_window, two_spans, 2, 65535, "map literal chunk too large"));
  static const agc_instr big_map_chunk[] = {{AGC_OP_MAP, 0, 0, 256}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(big_map_chunk, two_spans, 2, 1024, "map literal chunk too large"));
  static const agc_instr max_map_chunk[] = {{AGC_OP_MAP, 0, 0, 255}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(loads_with_tables(max_map_chunk, two_spans, 2, 510, NULL));
  static const agc_instr exact_map_window[] = {{AGC_OP_MAP, 0, 0, 2}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(loads_with_tables(exact_map_window, two_spans, 2, 4, NULL));
  static const agc_instr bad_map_get[] = {{AGC_OP_MAP_GET, 0, 0, 4}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_map_get, two_spans, 2, 4, "register out of range"));
  static const agc_instr bad_map_get_target[] = {{AGC_OP_MAP_GET, 4, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_tables(bad_map_get_target, two_spans, 2, 4, "register out of range"));

  static const agc_instr map_get_of_list[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_LIST, 0, 0, 0}, {AGC_OP_MAP_GET, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr map_void_key[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_MAP, 0, 0, 1}, {AGC_OP_NOT, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const agc_instr map_get_void_key[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_MAP, 1, 1, 0}, {AGC_OP_MAP_GET, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  const agc_instr *bad_maps[] = {map_get_of_list, map_void_key, map_get_void_key};
  for (int k = 0; k < 3; k++) {
    agc_outcome bad = run_with_tables(bad_maps[k], confused_spans, 4, stdout);
    assert(bad.kind == AGC_FAILED && strcmp(bad.code, "RUNTIME-INTERNAL") == 0);
  }
  static const agc_instr map_get_missing[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_MAP, 1, 1, 0}, {AGC_OP_MAP_GET, 0, 1, 0},
    {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t missing_spans[] = {1, 0, 0, 2, 0};
  agc_outcome missing = run_with_tables(map_get_missing, missing_spans, 5, stdout);
  assert(missing.kind == AGC_FAILED && strcmp(missing.code, "RUNTIME-KEY-NOT-FOUND") == 0 && missing.span == 2);
  assert(strcmp(missing.message, "key 1 is not in the map") == 0);
  static const agc_instr map_puts[] = {
    {AGC_OP_STEP, 1, 0, 0},    {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_CONST, 1, 0, 0}, {AGC_OP_MAP, 3, 0, 1},
    {AGC_OP_MAP_GET, 2, 3, 0}, {AGC_OP_MAP, 0, 2, 1},   {AGC_OP_CALL_BUILTIN, 0, 0, 0},
    {AGC_OP_CONST, 0, 1, 0},   {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t map_puts_spans[] = {1, 0, 0, 0, 0, 0, 1, 0, 0};
  out = tmpfile();
  assert(out);
  assert(run_with_tables(map_puts, map_puts_spans, 9, out).kind == AGC_DONE);
  expect_output(out, "{1: {1: 1}}\n");

  s = base();
  s.builtin = "Map.put";
  s.builtin_arity = 2;
  assert(!loads(s, "unknown builtin"));

  static const agc_instr value_call[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 1, 0, 0}, {AGC_OP_CLOSURE, 0, 1, 0}, {AGC_OP_CALL_VALUE, 0, 1, 0},
    {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t value_spans[] = {1, 0, 0, 1, 0};
  s = base();
  s.code = value_call;
  s.code_spans = value_spans;
  s.count = 5;
  s.registers = 2;
  s.helper_params = 1;
  assert(loads(s, NULL));
  out = tmpfile();
  assert(out);
  assert(run_spec(s, out).kind == AGC_DONE);
  expect_output(out, "");
  s.registers = 1;
  assert(!loads(s, "register"));
  s.registers = 2;
  s.helper_captures = 3;
  assert(!loads(s, "register range"));
  s.registers = 3;
  assert(loads(s, NULL));
  s.helper_captures = 0;
  s.helper_params = 2;
  s.registers = 3;
  agc_outcome arity = run_spec(s, stdout);
  assert(arity.kind == AGC_FAILED && strcmp(arity.code, "RUNTIME-INTERNAL") == 0);
  s = base();
  s.code = call_window;
  s.code_spans = four_spans;
  s.count = 4;
  s.registers = 3;
  s.helper_params = 1;
  s.helper_captures = 1;
  assert(!loads(s, "direct call to a function with captures"));
  s.code = tail_window;
  assert(!loads(s, "direct call to a function with captures"));
  static const agc_instr call_int[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_CALL_VALUE, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  s = base();
  s.code = call_int;
  s.code_spans = four_spans;
  s.count = 4;
  agc_outcome not_fn = run_spec(s, stdout);
  assert(not_fn.kind == AGC_FAILED && strcmp(not_fn.code, "RUNTIME-INTERNAL") == 0);
  static const agc_instr value_without_step[] = {{AGC_OP_CALL_VALUE, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(value_without_step, two_spans, 2, "does not start with STEP"));
  static const agc_instr value_window[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CALL_VALUE, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(value_window, three_spans, 3, "register range"));
  static const agc_instr closure_far[] = {{AGC_OP_CLOSURE, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(closure_far, two_spans, 2, "function index out of range"));
  static const agc_instr closure_target[] = {{AGC_OP_CLOSURE, 1, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(closure_target, two_spans, 2, "register out of range"));
  s = base();
  s.captures = 2;
  assert(!loads(s, "bad register count"));
  s.registers = 2;
  assert(!loads(s, "entry has captures"));

  static const agc_instr map_callback[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 1, 0, 0}, {AGC_OP_LIST, 0, 1, 1}, {AGC_OP_CLOSURE, 1, 1, 0},
    {AGC_OP_CALL_BUILTIN, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t map_callback_spans[] = {1, 0, 0, 0, 0, 0};
  s = base();
  s.builtin = "List.map";
  s.builtin_arity = 2;
  s.code = map_callback;
  s.code_spans = map_callback_spans;
  s.count = 6;
  s.registers = 2;
  s.helper_params = 1;
  assert(run_spec(s, stdout).kind == AGC_DONE);
  s.helper_params = 2;
  s.registers = 2;
  agc_outcome callback_arity = run_spec(s, stdout);
  assert(callback_arity.kind == AGC_FAILED && strcmp(callback_arity.code, "RUNTIME-INTERNAL") == 0);
  s.builtin_arity = 3;
  assert(!loads(s, "unknown builtin"));

  static const agc_instr range_code[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_CONST, 1, 0, 0}, {AGC_OP_RANGE, 0, 0, 1}, {AGC_OP_RANGE_BOUNDS, 0, 0, 0},
    {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t range_spans[] = {1, 0, 0, 0, 0, 0};
  s = base();
  s.code = range_code;
  s.code_spans = range_spans;
  s.count = 6;
  s.registers = 3;
  assert(loads(s, NULL));
  agc_outcome bounds = run_spec(s, stdout);
  assert(bounds.kind == AGC_DONE);
  s.registers = 2;
  assert(!loads(s, "register range out of range"));
  static const agc_instr range_kind[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_CONST, 1, 0, 0}, {AGC_OP_RANGE, 0, 0, 2}, {AGC_OP_RETURN, 0, 0, 0}};
  s.code = range_kind;
  s.count = 5;
  assert(!loads(s, "bad range kind"));
  static const agc_instr range_window[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_CONST, 1, 0, 0}, {AGC_OP_RANGE, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  s.code = range_window;
  assert(!loads(s, "register range out of range"));
  static const agc_instr bounds_of_int[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_RANGE_BOUNDS, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  s.code = bounds_of_int;
  s.count = 4;
  s.registers = 3;
  agc_outcome range_wrong = run_spec(s, stdout);
  assert(range_wrong.kind == AGC_FAILED && strcmp(range_wrong.code, "RUNTIME-INTERNAL") == 0);

  assert(loads_types(0, NULL));
  assert(!loads_types(1, "unknown type kind 7"));
  assert(!loads_types(2, "element type is not an earlier type"));
  assert(!loads_types(3, "struct index out of range"));
  assert(!loads_types(4, "type index out of range"));
  assert(!loads_types(5, "decodable structs out of order"));
  assert(!loads_types(6, "type names a struct without field types"));
  assert(!loads_types(7, "too many types"));
  assert(!loads_types(8, "type count exceeds the file"));
  assert(!loads_types(9, "struct index out of range"));
  assert(!loads_types(10, "type nesting too deep"));
  assert(!loads_types(11, "duplicate JSON type name"));
  assert(loads_types(12, NULL));
  buffer typed = type_tables(0);
  s = base();
  s.tables = &typed;
  buffer typed_file = build(s);
  for (size_t n = 0; n < typed_file.len; n++) {
    agc_program *q;
    assert(!agc_load(typed_file.data, n, &q, error, sizeof error));
  }
  free(typed_file.data);
  free(typed.data);

  /* STRUCT_WITH: the copy gets the new values and the receiver is untouched. Constant 2 is the Int 7. */
  static const agc_instr update_one[] = {
    {AGC_OP_STEP, 1, 0, 0},         {AGC_OP_CONST, 0, 0, 0},   {AGC_OP_CONST, 1, 0, 0}, {AGC_OP_STRUCT, 2, 0, 1},
    {AGC_OP_MOVE, 3, 2, 0},         {AGC_OP_CONST, 4, 2, 0},   {AGC_OP_STRUCT_WITH, 5, 3, 0},
    {AGC_OP_MOVE, 6, 5, 0},         {AGC_OP_CALL_BUILTIN, 6, 0, 0}, {AGC_OP_MOVE, 6, 2, 0},
    {AGC_OP_CALL_BUILTIN, 6, 0, 0}, {AGC_OP_CONST, 0, 1, 0},   {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t update_one_spans[] = {1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0};
  out = tmpfile();
  assert(out);
  assert(run_with_updates(update_one, update_one_spans, 13, 7, 7, out).kind == AGC_DONE);
  expect_output(out, "Q(a: 1, b: 7)\nQ(a: 1, b: 1)\n");
  static const agc_instr update_both[] = {
    {AGC_OP_STEP, 1, 0, 0},         {AGC_OP_CONST, 0, 0, 0},   {AGC_OP_CONST, 1, 0, 0}, {AGC_OP_STRUCT, 2, 0, 1},
    {AGC_OP_MOVE, 3, 2, 0},         {AGC_OP_CONST, 4, 2, 0},   {AGC_OP_CONST, 5, 2, 0}, {AGC_OP_STRUCT_WITH, 6, 3, 1},
    {AGC_OP_MOVE, 7, 6, 0},         {AGC_OP_CALL_BUILTIN, 7, 0, 0}, {AGC_OP_CONST, 0, 1, 0},
    {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t update_both_spans[] = {1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0};
  out = tmpfile();
  assert(out);
  assert(run_with_updates(update_both, update_both_spans, 12, 8, 7, out).kind == AGC_DONE);
  expect_output(out, "Q(a: 7, b: 7)\n");

  /* A hand-made file may put another struct, or no struct, where the update expects its receiver. */
  static const agc_instr update_wrong_struct[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_STRUCT, 1, 0, 0}, {AGC_OP_MOVE, 2, 1, 0},
    {AGC_OP_CONST, 3, 2, 0}, {AGC_OP_STRUCT_WITH, 4, 2, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t update_wrong_spans[] = {1, 0, 0, 0, 0, 0, 0};
  agc_outcome wrong_struct = run_with_updates(update_wrong_struct, update_wrong_spans, 7, 6, 7, stdout);
  assert(wrong_struct.kind == AGC_FAILED && strcmp(wrong_struct.code, "RUNTIME-INTERNAL") == 0);
  assert(strstr(wrong_struct.message, "struct update of another struct"));
  static const agc_instr update_of_int[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 0, 0, 0}, {AGC_OP_CONST, 1, 0, 0}, {AGC_OP_STRUCT_WITH, 2, 0, 0},
    {AGC_OP_RETURN, 0, 0, 0}};
  static const uint32_t update_of_int_spans[] = {1, 0, 0, 0, 0};
  agc_outcome int_receiver = run_with_updates(update_of_int, update_of_int_spans, 5, 4, 7, stdout);
  assert(int_receiver.kind == AGC_FAILED && strcmp(int_receiver.code, "RUNTIME-INTERNAL") == 0);

  /* Operands of the instruction: the entry, the window of the receiver and the values, the target. */
  static const agc_instr bad_update_index[] = {{AGC_OP_STRUCT_WITH, 0, 0, 2}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_updates(bad_update_index, two_spans, 2, 4, "struct update index out of range"));
  static const agc_instr bad_update_window[] = {{AGC_OP_STRUCT_WITH, 0, 3, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_updates(bad_update_window, two_spans, 2, 4, "register range out of range"));
  static const agc_instr bad_update_wide_window[] = {{AGC_OP_STRUCT_WITH, 0, 2, 1}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_updates(bad_update_wide_window, two_spans, 2, 4, "register range out of range"));
  static const agc_instr bad_update_target[] = {{AGC_OP_STRUCT_WITH, 4, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_with_updates(bad_update_target, two_spans, 2, 4, "register out of range"));
  static const agc_instr exact_update[] = {{AGC_OP_STRUCT_WITH, 3, 1, 1}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(loads_with_updates(exact_update, two_spans, 2, 4, NULL));
  static const agc_instr update_without_table[] = {{AGC_OP_STRUCT_WITH, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  assert(!loads_code(update_without_table, two_spans, 2, "struct update index out of range"));

  /* The section: each entry names a struct and strictly increasing fields below that struct's field count. */
  assert(loads_updates(2, good_updates, 7, NULL));
  assert(loads_updates(0, NULL, 0, NULL));
  static const uint32_t update_bad_struct[] = {2, 1, 0};
  assert(!loads_updates(1, update_bad_struct, 3, "struct index out of range"));
  static const uint32_t update_no_fields[] = {1, 0};
  assert(!loads_updates(1, update_no_fields, 2, "bad updated field count"));
  static const uint32_t update_too_many[] = {0, 2, 0, 1};
  assert(!loads_updates(1, update_too_many, 4, "bad updated field count"));
  static const uint32_t update_field_past[] = {1, 1, 2};
  assert(!loads_updates(1, update_field_past, 3, "updated field out of range"));
  static const uint32_t update_repeated[] = {1, 2, 1, 1};
  assert(!loads_updates(1, update_repeated, 4, "updated fields out of order"));
  static const uint32_t update_descending[] = {1, 2, 1, 0};
  assert(!loads_updates(1, update_descending, 4, "updated fields out of order"));
  assert(!loads_updates(1000000, good_updates, 3, "struct update count exceeds the file"));
  static const uint32_t update_field_count_huge[] = {1, 4000000000u, 0};
  assert(!loads_updates(1, update_field_count_huge, 3, "updated field count exceeds the file"));
  buffer table = make_tables(1);
  buffer updates = make_updates(2, good_updates, 7);
  s = base();
  s.tables = &table;
  s.updates = &updates;
  buffer updated_file = build(s);
  for (size_t n = 0; n < updated_file.len; n++) {
    agc_program *q;
    assert(!agc_load(updated_file.data, n, &q, error, sizeof error));
  }
  free(updated_file.data);
  free(table.data);
  free(updates.data);

  globals_tests();
  prelude_tests();
  source_root_tests();
  line_index_tests();
  table_count_tests();
  collector_tests();

  puts("loader tests passed");
  return 0;
}
