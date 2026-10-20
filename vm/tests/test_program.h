/* Test support: hand-built programs for the C tests that run the real scheduler (task_cancel, threads). */
#ifndef AGC_TEST_PROGRAM_H
#define AGC_TEST_PROGRAM_H

#include "../core.h"

#include <assert.h>
#include <string.h>

/* One source "t.agc" of one line. */
typedef struct {
  agc_source source;
  uint32_t line_start[1], line_chars[1];
} agc_test_source;

/* Fills the parts of P that every hand-built program shares: the source and spans, the constant, builtin and function
   tables, and the entry. Each function gets one parameter (the entry none), 32 registers and its rows of CODE and
   CODE_SPANS, MAX_CODE long. */
static inline void agc_test_program(agc_program *p, agc_test_source *src, agc_span *spans, uint32_t span_count,
                                    agc_value *constants, const agc_builtin **builtins, uint32_t builtin_count,
                                    agc_function *fns, uint32_t fn_count, agc_instr *code, uint32_t *code_spans,
                                    uint32_t max_code, uint32_t entry) {
  for (uint32_t f = 0; f < fn_count; f++) {
    fns[f].name = agc_make_string("f", 1, 1);
    fns[f].params = f == entry ? 0 : 1;
    fns[f].registers = 32;
    fns[f].code = code + (size_t)f * max_code;
    fns[f].spans = code_spans + (size_t)f * max_code;
  }
  src->source.name = agc_make_string("t.agc", 5, 5);
  src->source.text = agc_make_string("x\n", 2, 2);
  src->source.lines = 1;
  src->line_chars[0] = 1;
  src->source.line_start = src->line_start;
  src->source.line_chars = src->line_chars;
  for (uint32_t k = 0; k < span_count; k++) spans[k] = (agc_span){0, 1, k + 1, 1, k + 2};
  p->sources = &src->source;
  p->source_count = 1;
  p->spans = spans;
  p->span_count = span_count;
  p->constants = constants;
  p->builtins = builtins;
  p->builtin_count = builtin_count;
  p->functions = fns;
  p->function_count = fn_count;
  p->entry = entry;
}

/* Appends one instruction to FN, BX split into the b and c halves, with span SPAN. */
static inline void agc_test_emit(agc_function *fn, uint32_t max_code, agc_opcode op, uint32_t a, uint32_t bx,
                                 uint32_t span) {
  assert(fn->count < max_code);
  fn->code[fn->count] = (agc_instr){(uint16_t)op, (uint16_t)a, (uint16_t)(bx & 0xffff), (uint16_t)(bx >> 16)};
  fn->spans[fn->count++] = span;
}

/* Adds the integer constant V to P and returns its index. */
static inline uint32_t agc_test_constant(agc_program *p, agc_value *constants, int64_t v) {
  uint32_t k = p->constant_count++;
  constants[k] = agc_int(v);
  return k;
}

#endif
