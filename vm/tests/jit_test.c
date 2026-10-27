/*
 * The JIT (vm/jit/): the x86-64 bytes of known instructions, compiled functions run directly (results, steps, exits,
 * failures that leave the result register alone, native calls, direct builtins, map reads, list literals, closures),
 * the code memory sealed read-execute and never writable then, functions packed in it up to its cap, one copy made
 * when several threads compile a function at once, and the `on` decision settled in time that follows program size.
 */
#include "../jit/jit.h"
#include "test_support.h"

#include <assert.h>
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <uv.h>

#define MAX_CODE 32

typedef struct {
  agc_program program;
  agc_function fn;
  agc_instr code[MAX_CODE];
  uint32_t spans[MAX_CODE];
  agc_value constants[4];
} one_function;

/* Four functions, each returning its index, in PROGRAM, compiled with `always`. */
enum { FOUR = 4 };
typedef struct {
  agc_program program;
  agc_function fns[FOUR];
  agc_instr code[FOUR][2];
  uint32_t spans[2];
  agc_value constants[FOUR];
} four_functions;

static agc_vm vm;

#if AGC_JIT_HOST
/* The tag and the 8-byte payload: bytes 4 to 7 are padding that the constructors leave unset. */
static bool same_bits(agc_value x, agc_value y) { return x.tag == y.tag && agc_value_word(x) == agc_value_word(y); }

static void emit(one_function *f, uint32_t op, uint32_t a, uint32_t b, uint32_t c) {
  assert(f->fn.count < MAX_CODE);
  f->code[f->fn.count++] = (agc_instr){(uint16_t)op, (uint16_t)a, (uint16_t)b, (uint16_t)c};
}

static void program_of(one_function *f) {
  f->fn.name = agc_make_string("f", 1, 1);
  f->fn.registers = 8;
  f->fn.code = f->code;
  f->fn.spans = f->spans;
  f->constants[0] = agc_int(0);
  f->constants[1] = agc_int(1);
  f->program.functions = &f->fn;
  f->program.function_count = 1;
  f->program.constants = f->constants;
  f->program.constant_count = 2;
}

static agc_jit_code compile(one_function *f) {
  static const agc_trace quiet = {0};
  program_of(f);
  agc_jit *jit = agc_jit_new(&f->program, AGC_JIT_ALWAYS, &quiet);
  assert(jit);
  return agc_jit_code_of(jit, 0, 0);
}

static void expect_exit(agc_jit_exit got, uint32_t status, uint32_t pc) {
  if (got.status != status || got.pc != pc)
    fprintf(stderr, "jit-test: exit got status=%" PRIu32 " pc=%" PRIu32 ", want status=%" PRIu32 " pc=%" PRIu32 "\n",
            got.status, got.pc, status, pc);
  assert(got.status == status && got.pc == pc);
}

/* The encodings, checked against an assembler (objdump -D -b binary -mi386:x86-64). */
static void bytes(void) {
  agc_emitter e;
  agc_emit_begin(&e, 1);
  size_t start = e.len;
  agc_emit_move(&e, 1, 2);
  static const uint8_t move[] = {
    0x49, 0x8b, 0x84, 0x24, 0x20, 0, 0, 0, /* mov rax, [r12 + 32] */
    0x49, 0x8b, 0x94, 0x24, 0x28, 0, 0, 0, /* mov rdx, [r12 + 40] */
    0x49, 0x89, 0x84, 0x24, 0x10, 0, 0, 0, /* mov [r12 + 16], rax */
    0x49, 0x89, 0x94, 0x24, 0x18, 0, 0, 0, /* mov [r12 + 24], rdx */
  };
  assert(e.len - start == sizeof move && memcmp(e.code + start, move, sizeof move) == 0);
  start = e.len;
  agc_emit_const(&e, 3, 1);
  static const uint8_t constant[] = {
    0x49, 0x8b, 0x85, 0x10, 0, 0, 0,       /* mov rax, [r13 + 16] */
    0x49, 0x8b, 0x95, 0x18, 0, 0, 0,       /* mov rdx, [r13 + 24] */
    0x49, 0x89, 0x84, 0x24, 0x30, 0, 0, 0, /* mov [r12 + 48], rax */
    0x49, 0x89, 0x94, 0x24, 0x38, 0, 0, 0, /* mov [r12 + 56], rdx */
  };
  assert(e.len - start == sizeof constant && memcmp(e.code + start, constant, sizeof constant) == 0);
  start = e.len;
  agc_emit_step(&e, 3, 0);
  uint8_t at = (uint8_t)offsetof(agc_vm, next_stop);
  const uint8_t step[] = {
    0x48, 0x8b, 0x83, at, 0, 0, 0, /* mov rax, [rbx + next_stop] */
    0x48, 0x3d, 3, 0, 0, 0,        /* cmp rax, 3 */
    0x0f, 0x8e, 0, 0, 0, 0,        /* jle exit (written by agc_emit_end) */
    0x48, 0x2d, 3, 0, 0, 0,        /* sub rax, 3 */
    0x48, 0x89, 0x83, at, 0, 0, 0, /* mov [rbx + next_stop], rax */
  };
  assert(e.len - start == sizeof step && memcmp(e.code + start, step, sizeof step) == 0);
  /* A constant whose offset does not fit 32 bits keeps the function interpreted. */
  agc_emit_const(&e, 0, UINT32_MAX);
  assert(agc_emit_end(&e) == 0);
}

/* total = 0 + 1 + ... + (n - 1) for n in R0, with the STEP of the loop at pc 2. */
static void sum_loop(one_function *f) {
  memset(f, 0, sizeof *f);
  emit(f, AGC_OP_CONST, 1, 0, 0);
  emit(f, AGC_OP_CONST, 2, 0, 0);
  emit(f, AGC_OP_STEP, 1, 0, 0);
  emit(f, AGC_OP_LT_I, 3, 1, 0);
  emit(f, AGC_OP_JUMP_IF_FALSE, 3, 9, 0);
  emit(f, AGC_OP_ADD_I, 2, 2, 1);
  emit(f, AGC_FUSED_CONST_ARITH_I, 4, 1, 0);
  emit(f, AGC_OP_ADD_I, 1, 1, 4);
  emit(f, AGC_OP_JUMP, 0, 2, 0);
  emit(f, AGC_OP_RETURN, 2, 0, 0);
}

static AGC_JIT_CALLER void call_return_exits(void) {
  one_function f;
  memset(&f, 0, sizeof f);
  emit(&f, AGC_OP_CALL, 0, 0, 0);
  emit(&f, AGC_OP_RETURN, 0, 0, 0);
  agc_jit_code code = compile(&f);
  assert(code);
  agc_value R[8] = {agc_int(42)};
  expect_exit(code(&vm, R, f.constants, 0), AGC_JIT_EXIT_CALL, 0);
  expect_exit(code(&vm, R, f.constants, 1), AGC_JIT_EXIT_RETURN, 1);
}

/* Function 0 calls function 1, which adds 1 to its argument, natively: the frame is pushed and popped in compiled code
   and the result lands in the caller's window. A STEP exit inside the callee comes out of the caller with the callee's
   frame on top, and a task without room for the frame takes the CALL exit with nothing pushed. */
static AGC_JIT_CALLER void native_calls(void) {
  static const agc_trace quiet = {0};
  static agc_instr caller[] = {{AGC_OP_CALL, 2, 1, 0}, {AGC_OP_RETURN, 2, 0, 0}};
  static agc_instr callee[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CONST, 1, 1, 0}, {AGC_OP_ADD_I, 0, 0, 1}, {AGC_OP_RETURN, 0, 0, 0}};
  static uint32_t spans[4] = {0};
  agc_value constants[2] = {agc_int(0), agc_int(1)};
  agc_function fns[2] = {
    {.name = agc_make_string("caller", 6, 6), .registers = 4, .code = caller, .spans = spans, .count = 2},
    {.name = agc_make_string("callee", 6, 6), .registers = 2, .code = callee, .spans = spans, .count = 4},
  };
  agc_program program = {.functions = fns, .function_count = 2, .constants = constants, .constant_count = 2};
  agc_jit *jit = agc_jit_new(&program, AGC_JIT_ALWAYS, &quiet);
  assert(jit && agc_jit_code_of(jit, 1, 0));
  agc_jit_code code = agc_jit_code_of(jit, 0, 0);
  assert(code);
  agc_task *t = vm.task, saved = *vm.task;
  agc_frame frames[2] = {{.function = 0}};
  agc_value regs[8] = {0};
  t->frames = frames;
  t->frame_capacity = 2;
  t->frame_count = t->depth = 1;
  t->regs = regs;
  t->reg_capacity = 8;
  regs[2] = agc_int(41);
  vm.next_stop = 1000;
  expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_RETURN, 1);
  assert(same_bits(regs[2], agc_int(42)) && t->frame_count == 1 && t->depth == 1 && frames[0].pc == 1);
  assert(vm.next_stop == 999);
  vm.next_stop = 1;
  expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_STEP, 0);
  assert(t->frame_count == 2 && t->depth == 2 && frames[0].pc == 1);
  assert(frames[1].function == 1 && frames[1].pc == 0 && frames[1].base == 2 && frames[1].ret == 2 &&
         !frames[1].tail && !frames[1].native);
  t->frame_count = t->depth = 1;
  t->frame_capacity = 1;
  vm.next_stop = 1000;
  expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_CALL, 0);
  assert(t->frame_count == 1 && t->depth == 1);
  t->frame_capacity = 2;
  t->reg_capacity = 3;
  expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_CALL, 0);
  assert(t->frame_count == 1);
  /* The callee's window ends exactly at the end of the register file. */
  t->reg_capacity = 4;
  expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_RETURN, 1);
  assert(same_bits(regs[2], agc_int(43)) && t->frame_count == 1);
  *t = saved;
  vm.next_stop = 1000;
}

static agc_value adds(agc_vm *v, agc_value *args, uint32_t span) {
  (void)span;
  agc_charge(v, 5);
  return agc_int(agc_as_int(v, args[0]) + agc_as_int(v, args[1]));
}

static agc_value refuses(agc_vm *v, agc_value *args, uint32_t span) {
  (void)args;
  agc_fail(v, "RUNTIME-TEST", "refused", span + 1);
}

/* A CALL_BUILTIN of a direct row runs in compiled code (agc_jit_call_builtin): the result in the window, the top
   frame's pc after the call, the turn cost applied; a cost that ends the turn leaves with YIELD after the result is
   written; a failure is caught and leaves with RAISE, the failure recorded at the builtin's span and the window left
   alone. A row that is not direct takes the INTERPRET exit. */
static AGC_JIT_CALLER void direct_calls(void) {
  static const agc_builtin add_row = {"Test.adds", 2, adds, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true};
  static const agc_builtin fail_row = {"Test.refuses", 0, refuses, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true};
  static const agc_builtin tail_row = {"Test.adds", 2, adds, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false};
  static one_function fs[3];
  const agc_builtin *rows[3] = {&add_row, &fail_row, &tail_row};
  agc_task *t = vm.task, saved = *vm.task;
  agc_outcome outcome = *vm.outcome;
  agc_frame frames[1] = {{.function = 0}};
  t->frames = frames;
  t->frame_capacity = t->frame_count = t->depth = 1;
  agc_jit_code code[3];
  for (uint16_t k = 0; k < 3; k++) {
    memset(&fs[k], 0, sizeof fs[k]);
    emit(&fs[k], AGC_OP_CALL_BUILTIN, 1, k, 0);
    emit(&fs[k], AGC_OP_RETURN, 1, 0, 0);
    fs[k].spans[0] = 7;
    fs[k].program.builtins = rows;
    fs[k].program.builtin_count = 3;
    code[k] = compile(&fs[k]);
    assert(code[k]);
  }
  agc_value R[4] = {agc_nil(), agc_int(2), agc_int(40), agc_nil()};
  vm.turn_left = vm.batch = vm.next_stop = vm.stop_set = 1000;
  expect_exit(code[0](&vm, R, NULL, 0), AGC_JIT_EXIT_RETURN, 1);
  assert(same_bits(R[1], agc_int(42)) && frames[0].pc == 1 && t->turn_cost == 0 && vm.turn_left == 995 && !vm.yield);
  R[1] = agc_int(2);
  vm.turn_left = 3;
  expect_exit(code[0](&vm, R, NULL, 0), AGC_JIT_EXIT_YIELD, 0);
  assert(same_bits(R[1], agc_int(42)) && vm.yield && t->turn_cost == 0);
  vm.yield = false;
  R[1] = agc_int(2);
  frames[0].pc = 0;
  /* agc_fail reads the program of the run for the span. */
  vm.rt->program = &fs[1].program;
  expect_exit(code[1](&vm, R, NULL, 0), AGC_JIT_EXIT_RAISE, 0);
  vm.rt->program = NULL;
  assert(vm.outcome->kind == AGC_FAILED && strcmp(vm.outcome->code, "RUNTIME-TEST") == 0 && vm.outcome->span == 8);
  assert(same_bits(R[1], agc_int(2)) && frames[0].pc == 1 && !vm.jit_catch);
  expect_exit(code[2](&vm, R, NULL, 0), AGC_JIT_EXIT_INTERPRET, 0);
  *vm.outcome = outcome;
  *t = saved;
  vm.next_stop = 1000;
}

static AGC_JIT_CALLER void loops_and_steps(void) {
  one_function f;
  sum_loop(&f);
  agc_jit_code code = compile(&f);
  assert(code);
  agc_value R[8] = {agc_int(10)};
  vm.next_stop = 1000;
  expect_exit(code(&vm, R, f.constants, 0), AGC_JIT_EXIT_RETURN, 9);
  assert(same_bits(R[2], agc_int(45)) && vm.next_stop == 1000 - 11);
  /* The STEP takes its fast path while next_stop is above its count, as the interpreter's: from 3, two passes, then
     the exit for the slow path at the STEP, and the code goes on from the next instruction. */
  R[0] = agc_int(10);
  vm.next_stop = 3;
  expect_exit(code(&vm, R, f.constants, 0), AGC_JIT_EXIT_STEP, 2);
  assert(vm.next_stop == 1 && same_bits(R[1], agc_int(2)));
  vm.next_stop = 1000;
  expect_exit(code(&vm, R, f.constants, 3), AGC_JIT_EXIT_RETURN, 9);
  assert(same_bits(R[2], agc_int(45)));
  /* A wrong tag on the compare leaves at its pc. */
  R[0] = agc_nil();
  expect_exit(code(&vm, R, f.constants, 0), AGC_STATUS_WRONG_TAG, 3);
}

/* R3 = R1 op R2, then RETURN R3: runs the two compiled instructions on X and Y, and answers the exit. */
static AGC_JIT_CALLER agc_jit_exit run_two(agc_opcode op, agc_value x, agc_value y, agc_value *R) {
  one_function f;
  memset(&f, 0, sizeof f);
  emit(&f, op, 3, 1, 2);
  emit(&f, AGC_OP_RETURN, 3, 0, 0);
  agc_jit_code code = compile(&f);
  assert(code);
  memset(R, 0, 8 * sizeof *R);
  R[1] = x;
  R[2] = y;
  R[3] = agc_nil();
  return code(&vm, R, f.constants, 0);
}

/* R3 = R1 op R2, then RETURN R3: the exit for each case, and R3 left alone on a failure. */
static AGC_JIT_CALLER void binary(agc_opcode op, agc_value x, agc_value y, uint32_t status, agc_value want) {
  agc_value R[8];
  agc_value mark = agc_nil();
  agc_jit_exit out = run_two(op, x, y, R);
  if (status == AGC_STATUS_OK) {
    expect_exit(out, AGC_JIT_EXIT_RETURN, 1);
    assert(same_bits(R[3], want));
  } else {
    expect_exit(out, status, 0);
    assert(same_bits(R[3], mark));
  }
}

/* R3 = the String OP made of R1 (and R2): string results compare by bytes, not by word, and the turn cost stays
   empty for these short forms, so the code goes on to the RETURN. */
static AGC_JIT_CALLER void text_binary(agc_opcode op, agc_value x, agc_value y, const char *want) {
  agc_value R[8];
  vm.task->turn_cost = 0;
  expect_exit(run_two(op, x, y, R), AGC_JIT_EXIT_RETURN, 1);
  assert(agc_is(R[3], AGC_T_STRING) && vm.task->turn_cost == 0);
  const agc_string *s = agc_as_string(&vm, R[3]);
  size_t n = strlen(want);
  assert(s->bytes == n && memcmp(s->data, want, n) == 0);
}

/* R3 = the String OP printed for the value R1 holds, with the TO_TEXT-only function: the code leaves for the
   interpreter to apply the charge, which is the text's own bytes. */
static AGC_JIT_CALLER void text_cost(agc_jit_code code, one_function *f, agc_value *R, agc_value v) {
  R[1] = v;
  R[3] = agc_nil();
  vm.task->turn_cost = 0;
  expect_exit(code(&vm, R, f->constants, 0), AGC_JIT_EXIT_COST, 0);
  assert(agc_is(R[3], AGC_T_STRING));
  assert(vm.task->turn_cost == (int64_t)(agc_as_string(&vm, R[3])->bytes / AGC_COST_BYTES));
}

static AGC_JIT_CALLER void int_rules(void) {
  agc_value max = agc_int(INT64_MAX), min = agc_int(INT64_MIN), one = agc_int(1), zero = agc_int(0);
  agc_value minus = agc_int(-1), any = agc_nil();
  binary(AGC_OP_ADD_I, agc_int(40), agc_int(2), AGC_STATUS_OK, agc_int(42));
  binary(AGC_OP_ADD_I, max, one, AGC_STATUS_OVERFLOW, any);
  binary(AGC_OP_SUB_I, min, one, AGC_STATUS_OVERFLOW, any);
  binary(AGC_OP_SUB_I, agc_int(2), agc_int(5), AGC_STATUS_OK, agc_int(-3));
  binary(AGC_OP_MUL_I, max, agc_int(2), AGC_STATUS_OVERFLOW, any);
  binary(AGC_OP_MUL_I, agc_int(-6), agc_int(7), AGC_STATUS_OK, agc_int(-42));
  binary(AGC_OP_DIV_I, agc_int(7), agc_int(-2), AGC_STATUS_OK, agc_int(-3));
  binary(AGC_OP_DIV_I, one, zero, AGC_STATUS_DIVISION_BY_ZERO, any);
  binary(AGC_OP_DIV_I, min, minus, AGC_STATUS_OVERFLOW, any);
  binary(AGC_OP_DIV_I, agc_int(9), minus, AGC_STATUS_OK, agc_int(-9));
  binary(AGC_OP_MOD_I, agc_int(-7), agc_int(2), AGC_STATUS_OK, agc_int(-1));
  binary(AGC_OP_MOD_I, min, minus, AGC_STATUS_OK, zero);
  binary(AGC_OP_MOD_I, one, zero, AGC_STATUS_DIVISION_BY_ZERO, any);
  binary(AGC_OP_LT_I, min, max, AGC_STATUS_OK, agc_bool(true));
  binary(AGC_OP_LE_I, one, one, AGC_STATUS_OK, agc_bool(true));
  binary(AGC_OP_LT_I, one, one, AGC_STATUS_OK, agc_bool(false));
  binary(AGC_OP_ADD_I, one, agc_float(1.0), AGC_STATUS_WRONG_TAG, any);
  binary(AGC_OP_EQ, one, one, AGC_STATUS_OK, agc_bool(true));
  binary(AGC_OP_NE, one, zero, AGC_STATUS_OK, agc_bool(true));
  /* Pairs other than two Ints go through agc_op_eq and agc_op_ne. */
  binary(AGC_OP_EQ, agc_bool(true), agc_bool(true), AGC_STATUS_OK, agc_bool(true));
  binary(AGC_OP_NE, agc_nil(), agc_nil(), AGC_STATUS_OK, agc_bool(false));
  binary(AGC_OP_EQ, one, agc_float(1.0), AGC_STATUS_WRONG_TAG, any);
  one_function f;
  memset(&f, 0, sizeof f);
  emit(&f, AGC_OP_NEG_I, 3, 1, 0);
  emit(&f, AGC_OP_RETURN, 3, 0, 0);
  agc_jit_code code = compile(&f);
  agc_value R[8] = {agc_nil(), min, agc_nil(), agc_nil()};
  expect_exit(code(&vm, R, f.constants, 0), AGC_STATUS_OVERFLOW, 0);
  R[1] = agc_int(5);
  expect_exit(code(&vm, R, f.constants, 0), AGC_JIT_EXIT_RETURN, 1);
  assert(same_bits(R[3], agc_int(-5)));
}

/* The instructions that call their opcode helper: the C code's results (NaN compares false, -0.0 keeps its sign) and
   statuses (a Float division by zero, a list index outside the list, a wrong tag). */
static AGC_JIT_CALLER void helpers(void) {
  agc_value nan = agc_float(NAN), two = agc_float(2.0), any = agc_nil();
  agc_value items[3] = {agc_int(7), agc_int(8), agc_int(9)};
  agc_value list = agc_list_value(agc_list_from_array(items, 3));
  agc_value hello = agc_string_value(agc_make_string("hello, ", 7, 7));
  agc_value world = agc_string_value(agc_make_string("world", 5, 5));
  agc_value pair[2] = {agc_int(7), agc_int(8)};
  agc_value list_of_two = agc_list_value(agc_list_from_array(pair, 2));
  binary(AGC_OP_ADD_F, agc_float(0.5), two, AGC_STATUS_OK, agc_float(2.5));
  binary(AGC_OP_SUB_F, agc_float(0.0), agc_float(0.0), AGC_STATUS_OK, agc_float(0.0));
  binary(AGC_OP_MUL_F, agc_float(-0.0), two, AGC_STATUS_OK, agc_float(-0.0));
  binary(AGC_OP_DIV_F, agc_float(1.0), agc_float(-0.0), AGC_STATUS_DIVISION_BY_ZERO, any);
  binary(AGC_OP_DIV_F, agc_float(1.0), agc_float(1e-310), AGC_STATUS_OK, agc_float(1.0 / 1e-310));
  binary(AGC_OP_NEG_F, two, any, AGC_STATUS_OK, agc_float(-2.0));
  binary(AGC_OP_LT_F, nan, two, AGC_STATUS_OK, agc_bool(false));
  binary(AGC_OP_LE_F, two, nan, AGC_STATUS_OK, agc_bool(false));
  binary(AGC_OP_LE_F, two, two, AGC_STATUS_OK, agc_bool(true));
  binary(AGC_OP_ADD_F, two, agc_int(1), AGC_STATUS_WRONG_TAG, any);
  binary(AGC_OP_SAME, agc_int(1), agc_int(1), AGC_STATUS_OK, agc_bool(true));
  /* CONCAT joins, TO_TEXT prints: results, a wrong tag and Void leaving R3 alone. */
  text_binary(AGC_OP_CONCAT, hello, world, "hello, world");
  binary(AGC_OP_CONCAT, hello, agc_int(1), AGC_STATUS_WRONG_TAG, any);
  binary(AGC_OP_CONCAT, agc_int(1), world, AGC_STATUS_WRONG_TAG, any);
  text_binary(AGC_OP_TO_TEXT, agc_int(-42), any, "-42");
  text_binary(AGC_OP_TO_TEXT, agc_float(1.5), any, "1.5");
  text_binary(AGC_OP_TO_TEXT, hello, any, "hello, ");
  text_binary(AGC_OP_TO_TEXT, list_of_two, any, "[7, 8]");
  binary(AGC_OP_TO_TEXT, agc_void(), any, AGC_STATUS_WRONG_TAG, any);
  /* A Void nested in a list or a map value fails compiled TO_TEXT at its pc, leaving R3 alone, as without the JIT. */
  agc_value hole_items[2] = {agc_int(1), agc_void()};
  binary(AGC_OP_TO_TEXT, agc_list_value(agc_list_from_array(hole_items, 2)), any, AGC_STATUS_WRONG_TAG, any);
  agc_map *hole_map =
      agc_map_put(&vm, agc_new_map(), agc_string_value(agc_make_string("a", 1, 1)), agc_void());
  binary(AGC_OP_TO_TEXT, agc_map_value(hole_map), any, AGC_STATUS_WRONG_TAG, any);
  /* Valid compounds print through compiled TO_TEXT; short ones charge nothing. */
  agc_map *ok_map = agc_map_put(&vm, agc_new_map(), agc_string_value(agc_make_string("a", 1, 1)), agc_int(1));
  text_binary(AGC_OP_TO_TEXT, agc_map_value(ok_map), any, "{\"a\": 1}");
  text_binary(AGC_OP_TO_TEXT, agc_result_value(true, agc_int(1)), any, "ok(1)");
  agc_map *two_set = agc_map_put(&vm, agc_new_map(), agc_int(1), agc_nil());
  two_set = agc_map_put(&vm, two_set, agc_int(2), agc_nil());
  text_binary(AGC_OP_TO_TEXT, agc_set_value(two_set), any, "Set[1, 2]");
  /* Record and enum shapes walk their defs from the runtime's program before the check reports a nested Void. */
  agc_test_shapes shapes;
  agc_test_shapes_init(&shapes);
  const agc_program *saved = vm.rt->program;
  vm.rt->program = &shapes.program;
  agc_struct *hole_struct = agc_new_struct(0, 1);
  hole_struct->fields[0] = agc_void();
  binary(AGC_OP_TO_TEXT, agc_struct_value(hole_struct), any, AGC_STATUS_WRONG_TAG, any);
  agc_struct *ok_struct = agc_new_struct(0, 1);
  ok_struct->fields[0] = agc_int(1);
  text_binary(AGC_OP_TO_TEXT, agc_struct_value(ok_struct), any, "S(x: 1)");
  agc_enum *hole_enum = agc_new_enum(1, 2);
  hole_enum->payload[0] = agc_int(1);
  hole_enum->payload[1] = agc_void();
  binary(AGC_OP_TO_TEXT, agc_enum_value(hole_enum), any, AGC_STATUS_WRONG_TAG, any);
  agc_enum *ok_enum = agc_new_enum(0, 1);
  ok_enum->payload[0] = agc_int(7);
  text_binary(AGC_OP_TO_TEXT, agc_enum_value(ok_enum), any, "E.v(7)");
  agc_enum *unit_enum = agc_new_enum(0, 1);
  unit_enum->payload[0] = agc_void();
  text_binary(AGC_OP_TO_TEXT, agc_enum_value(unit_enum), any, "E.v()");
  vm.rt->program = saved;
  binary(AGC_OP_LIST_LEN, list, any, AGC_STATUS_OK, agc_int(3));
  binary(AGC_OP_LIST_LEN, agc_int(3), any, AGC_STATUS_WRONG_TAG, any);
  binary(AGC_OP_LIST_GET, list, agc_int(2), AGC_STATUS_OK, agc_int(9));
  binary(AGC_OP_LIST_GET, list, agc_int(3), AGC_STATUS_INDEX_OUT_OF_RANGE, any);
  binary(AGC_OP_LIST_GET, list, agc_int(-1), AGC_STATUS_INDEX_OUT_OF_RANGE, any);
  binary(AGC_OP_LIST_GET, list, two, AGC_STATUS_WRONG_TAG, any);
}

/* The reads without a helper (R3 = R1 read at index or variant 2): a wrong tag or an index past the count leaves for
   the interpreter at the instruction, R3 untouched, and the interpreter fails as it does without the JIT. */
static AGC_JIT_CALLER void reads(void) {
  agc_value any = agc_nil(), x = agc_int(5), y = agc_float(1.5);
  agc_struct *wide = agc_new_struct(0, 3), *narrow = agc_new_struct(0, 2);
  wide->fields[0] = wide->fields[1] = narrow->fields[0] = narrow->fields[1] = any;
  wide->fields[2] = x;
  agc_enum *v2 = agc_new_enum(2, 3), *v1 = agc_new_enum(1, 1);
  v2->payload[0] = v2->payload[1] = v1->payload[0] = any;
  v2->payload[2] = y;
  uint32_t out = AGC_JIT_EXIT_INTERPRET;
  binary(AGC_OP_NOT, agc_bool(true), any, AGC_STATUS_OK, agc_bool(false));
  binary(AGC_OP_NOT, agc_bool(false), any, AGC_STATUS_OK, agc_bool(true));
  binary(AGC_OP_NOT, agc_word_value(AGC_T_BOOL, 2), any, AGC_STATUS_OK, agc_bool(false));
  binary(AGC_OP_NOT, x, any, out, any);
  binary(AGC_OP_FIELD, agc_struct_value(wide), any, AGC_STATUS_OK, x);
  binary(AGC_OP_FIELD, agc_struct_value(narrow), any, out, any);
  binary(AGC_OP_FIELD, agc_enum_value(v2), any, out, any);
  binary(AGC_OP_PAYLOAD, agc_enum_value(v2), any, AGC_STATUS_OK, y);
  binary(AGC_OP_PAYLOAD, agc_enum_value(v1), any, out, any);
  binary(AGC_OP_IS_VARIANT, agc_enum_value(v2), any, AGC_STATUS_OK, agc_bool(true));
  binary(AGC_OP_IS_VARIANT, agc_enum_value(v1), any, AGC_STATUS_OK, agc_bool(false));
  binary(AGC_OP_IS_VARIANT, agc_struct_value(wide), any, out, any);
  binary(AGC_OP_IS_OK, agc_result_value(true, x), any, AGC_STATUS_OK, agc_bool(true));
  binary(AGC_OP_IS_OK, agc_result_value(false, x), any, AGC_STATUS_OK, agc_bool(false));
  binary(AGC_OP_RESULT_VALUE, agc_result_value(false, y), any, AGC_STATUS_OK, y);
  binary(AGC_OP_RESULT_VALUE, y, any, out, any);
}

/* A String compare charges its bytes to the task's turn cost, and the code leaves for the interpreter to apply it. */
static AGC_JIT_CALLER void string_cost(void) {
  char text[200];
  memset(text, 'a', sizeof text);
  agc_value x = agc_string_value(agc_make_string(text, sizeof text, sizeof text));
  agc_value y = agc_string_value(agc_make_string(text, sizeof text, sizeof text));
  one_function f;
  memset(&f, 0, sizeof f);
  emit(&f, AGC_OP_EQ, 3, 1, 2);
  emit(&f, AGC_OP_RETURN, 3, 0, 0);
  agc_jit_code code = compile(&f);
  agc_value R[8] = {agc_nil(), x, y, agc_nil()};
  vm.task->turn_cost = 0;
  expect_exit(code(&vm, R, f.constants, 0), AGC_JIT_EXIT_COST, 0);
  assert(same_bits(R[3], agc_bool(true)) && vm.task->turn_cost == sizeof text / AGC_COST_BYTES);
  vm.task->turn_cost = 0;
}

/* A join and a print charge their bytes to the task's turn cost, and the code leaves for the interpreter to apply
   it, as it does after a String compare. */
static AGC_JIT_CALLER void string_build_cost(void) {
  char text[200];
  memset(text, 'a', sizeof text);
  agc_value big = agc_string_value(agc_make_string(text, sizeof text, sizeof text));
  one_function f;
  memset(&f, 0, sizeof f);
  emit(&f, AGC_OP_CONCAT, 3, 1, 2);
  emit(&f, AGC_OP_RETURN, 3, 0, 0);
  agc_jit_code code = compile(&f);
  agc_value R[8] = {agc_nil(), big, big, agc_nil()};
  vm.task->turn_cost = 0;
  expect_exit(code(&vm, R, f.constants, 0), AGC_JIT_EXIT_COST, 0);
  assert(agc_as_string(&vm, R[3])->bytes == 2 * sizeof text);
  assert(vm.task->turn_cost == (int64_t)(2 * sizeof text / AGC_COST_BYTES));
  memset(&f, 0, sizeof f);
  emit(&f, AGC_OP_TO_TEXT, 3, 1, 0);
  emit(&f, AGC_OP_RETURN, 3, 0, 0);
  code = compile(&f);
  /* A print of a String charges nothing (it comes back as it was); a compound form charges its bytes. */
  R[1] = big;
  R[3] = agc_nil();
  vm.task->turn_cost = 0;
  expect_exit(code(&vm, R, f.constants, 0), AGC_JIT_EXIT_RETURN, 1);
  assert(same_bits(R[3], big) && vm.task->turn_cost == 0);
  agc_value many[100];
  for (size_t k = 0; k < 100; k++) many[k] = agc_int((int64_t)k);
  text_cost(code, &f, R, agc_list_value(agc_list_from_array(many, 100)));
  /* An int-keyed map prints through compiled TO_TEXT the same way: a COST exit with the text's own charge. */
  agc_map *big_map = agc_new_map();
  for (size_t k = 0; k < 100; k++)
    big_map = agc_map_put(&vm, big_map, agc_int((int64_t)k), agc_int((int64_t)k));
  text_cost(code, &f, R, agc_map_value(big_map));
  vm.task->turn_cost = 0;
}

/* MAP_GET reads a key in compiled code; a missing key or a wrong tag leaves for the interpreter at the instruction,
   R3 and the turn cost untouched, so the interpreter fails as it does. A String key charges its bytes, and the code
   leaves for the interpreter to apply them. LIST builds the window's values, or gives the run's empty List. */
static AGC_JIT_CALLER void maps_and_lists(void) {
  char text[200];
  memset(text, 'k', sizeof text);
  agc_value one = agc_int(1), ten = agc_int(10), any = agc_nil();
  agc_value key = agc_string_value(agc_make_string(text, sizeof text, sizeof text));
  agc_value same_key = agc_string_value(agc_make_string(text, sizeof text, sizeof text));
  agc_value other_key = agc_string_value(agc_make_string(text, sizeof text - 1, sizeof text - 1));
  agc_map *m = agc_map_put(&vm, agc_new_map(), one, ten);
  m = agc_map_put(&vm, m, key, agc_int(20));
  agc_value map = agc_map_value(m);
  uint32_t out = AGC_JIT_EXIT_INTERPRET;
  vm.task->turn_cost = 0;
  binary(AGC_OP_MAP_GET, map, one, AGC_STATUS_OK, ten);
  binary(AGC_OP_MAP_GET, map, agc_int(2), out, any);
  binary(AGC_OP_MAP_GET, agc_int(3), one, out, any);
  binary(AGC_OP_MAP_GET, map, agc_float(1.0), out, any);
  binary(AGC_OP_MAP_GET, agc_set_value(m), one, out, any);
  assert(vm.task->turn_cost == 0);
  agc_value R[8];
  expect_exit(run_two(AGC_OP_MAP_GET, map, same_key, R), AGC_JIT_EXIT_COST, 0);
  assert(same_bits(R[3], agc_int(20)) && vm.task->turn_cost >= (int64_t)(sizeof text / AGC_COST_BYTES));
  vm.task->turn_cost = 0;
  expect_exit(run_two(AGC_OP_MAP_GET, map, other_key, R), out, 0);
  assert(same_bits(R[3], any) && vm.task->turn_cost == 0);
  expect_exit(run_two(AGC_OP_LIST, one, ten, R), AGC_JIT_EXIT_RETURN, 1);
  const agc_list *l = agc_as_list(&vm, R[3]);
  assert(agc_list_len(l) == 2 && same_bits(agc_list_get(l, 0), one) && same_bits(agc_list_get(l, 1), ten));
  one_function f;
  memset(&f, 0, sizeof f);
  emit(&f, AGC_OP_LIST, 3, 1, 0);
  emit(&f, AGC_OP_RETURN, 3, 0, 0);
  agc_jit_code code = compile(&f);
  R[3] = any;
  expect_exit(code(&vm, R, f.constants, 0), AGC_JIT_EXIT_RETURN, 1);
  assert(same_bits(R[3], vm.rt->empty_list));
}

/* CLOSURE makes, in compiled code, a function value of bx that holds the CAPTURES registers from R[a] on. */
static AGC_JIT_CALLER void closures(void) {
  one_function f;
  memset(&f, 0, sizeof f);
  emit(&f, AGC_OP_CLOSURE, 3, 0, 0);
  emit(&f, AGC_OP_RETURN, 3, 0, 0);
  f.fn.captures = 2;
  agc_jit_code code = compile(&f);
  agc_value R[8];
  memset(R, 0, sizeof R);
  R[3] = agc_int(7);
  R[4] = agc_string_value(agc_make_string("held", 4, 4));
  agc_value held = R[4];
  expect_exit(code(&vm, R, f.constants, 0), AGC_JIT_EXIT_RETURN, 1);
  const agc_fn *fn = agc_as_fn(&vm, R[3]);
  assert(fn->function == 0 && fn->n == 2);
  assert(same_bits(fn->captured[0], agc_int(7)) && same_bits(fn->captured[1], held) && same_bits(R[4], held));
}

/* Several schedulers ask for the code of one function at once (`make vm-tsan` runs this): one claims it and compiles
   it, and the others get NULL (they interpret it meanwhile) or the one copy that was published; no second copy takes
   code memory. The barrier lets them start together, so the losing side of the claim runs. */
#define RACERS 4
static agc_jit *race_jit;
static agc_jit_code race_code[RACERS];
static uv_barrier_t race_start;

static void race_one(void *arg) {
  assert(agc_gc_thread_enter());
  uv_barrier_wait(&race_start);
  race_code[(uintptr_t)arg] = agc_jit_code_of(race_jit, 0, 0);
  agc_gc_thread_leave();
}

static void compile_race(void) {
  static const agc_trace quiet = {0};
  one_function f;
  sum_loop(&f);
  program_of(&f);
  race_jit = agc_jit_new(&f.program, AGC_JIT_ALWAYS, &quiet);
  assert(uv_barrier_init(&race_start, RACERS) == 0);
  uv_thread_t threads[RACERS];
  for (uintptr_t k = 0; k < RACERS; k++) assert(uv_thread_create(&threads[k], race_one, (void *)k) == 0);
  for (size_t k = 0; k < RACERS; k++) assert(uv_thread_join(&threads[k]) == 0);
  agc_jit_code code = agc_jit_code_of(race_jit, 0, 0);
  assert(code);
  for (size_t k = 0; k < RACERS; k++) assert(!race_code[k] || race_code[k] == code);
  assert(atomic_load(&race_jit->used) == agc_jit_mem_page());
  uv_barrier_destroy(&race_start);
}

/* A function whose code crosses AGC_JIT_CODE_CAP inside the 32-bit offset of a jump fails, and nothing is written
   past the buffer: not the offset's patch, not the exit stubs, not the entry table (an overflow fails under
   SANITIZE=1). MOVE is 32 bytes and the jump 5, so the moves leave the jump's opcode at CAP - 3. */
static void cap_inside_an_offset(void) {
  agc_emitter e;
  agc_emit_begin(&e, 2);
  agc_emit_label(&e, 0);
  agc_emit_step(&e, 1, 0);
  agc_emit_label(&e, 1);
  size_t opcode_at = AGC_JIT_CODE_CAP - 3;
  while ((opcode_at - e.len) % 5) agc_emit_move(&e, 1, 2);
  while (opcode_at - e.len >= (size_t)5 * 32)
    for (int k = 0; k < 5; k++) agc_emit_move(&e, 1, 2);
  while (e.len < opcode_at) agc_emit_exit(&e, AGC_JIT_EXIT_INTERPRET, 1);
  assert(e.len == opcode_at && !e.failed && e.cap == AGC_JIT_CODE_CAP);
  agc_emit_jump(&e, 0);
  assert(e.failed && e.len <= e.cap);
  agc_emit_exit(&e, AGC_JIT_EXIT_INTERPRET, 1);
  assert(agc_emit_end(&e) == 0 && e.len <= e.cap);
}

/* Every opcode compiles with `always`: one without code of its own, such as CALL_BUILTIN or RETURN, leaves for the
   interpreter at its pc. */
static AGC_JIT_CALLER void every_opcode_compiles(void) {
  static const agc_trace quiet = {0};
  for (uint32_t op = 0; op < AGC_OP_COUNT; op++) {
    one_function f;
    memset(&f, 0, sizeof f);
    emit(&f, (agc_opcode)op, 1, 1, 0);
    emit(&f, AGC_OP_RETURN, 0, 0, 0);
    program_of(&f);
    agc_jit *jit = agc_jit_new(&f.program, AGC_JIT_ALWAYS, &quiet);
    if (!jit || !agc_jit_code_of(jit, 0, 0)) {
      fprintf(stderr, "jit-test: %s does not compile\n", agc_opcode_name(op));
      assert(0);
    }
  }
  one_function f;
  memset(&f, 0, sizeof f);
  emit(&f, AGC_OP_CALL_BUILTIN, 0, 0, 0);
  emit(&f, AGC_OP_RETURN, 0, 0, 0);
  agc_value R[8] = {agc_nil()};
  expect_exit(compile(&f)(&vm, R, f.constants, 0), AGC_JIT_EXIT_INTERPRET, 0);
  memset(&f, 0, sizeof f);
  emit(&f, AGC_OP_RETURN, 0, 0, 0);
  expect_exit(compile(&f)(&vm, R, f.constants, 0), AGC_JIT_EXIT_RETURN, 0);
}

/* `on` keeps out a function without a loop, and one whose loop goes back to the interpreter (a builtin that is neither
   a leaf nor direct nor a block call) more than once in AGC_JIT_SPACING instructions; a leaf builtin does not count,
   as run_compiled calls it, nor a block call, which run_compiled starts, nor a direct one, which compiled code calls.
   A program where no function is compiled has no JIT at all. */
static void ineligible(void) {
  static const agc_trace quiet = {0};
  one_function f;
  memset(&f, 0, sizeof f);
  emit(&f, AGC_OP_ADD_I, 0, 1, 2);
  emit(&f, AGC_OP_RETURN, 0, 0, 0);
  program_of(&f);
  assert(!agc_jit_new(&f.program, AGC_JIT_ON, &quiet));
  assert(agc_jit_new(&f.program, AGC_JIT_ALWAYS, &quiet));
  f.code[1] = (agc_instr){AGC_OP_JUMP, 0, 0, 0};
  assert(agc_jit_new(&f.program, AGC_JIT_ON, &quiet));
  agc_builtin leaf = {.leaf = true}, other = {.leaf = false}, direct = {.direct = true};
  agc_builtin block = {.native = AGC_NATIVE_FILTER};
  const agc_builtin *builtins[4] = {&leaf, &other, &direct, &block};
  for (uint32_t which = 0; which < 4; which++) {
    memset(&f, 0, sizeof f);
    emit(&f, AGC_OP_STEP, 1, 0, 0);
    emit(&f, AGC_OP_CALL_BUILTIN, 0, (uint16_t)which, 0);
    while (f.fn.count < AGC_JIT_SPACING - 2) emit(&f, AGC_OP_MOVE, 1, 2, 0);
    emit(&f, AGC_OP_JUMP, 0, 0, 0);
    program_of(&f);
    f.program.builtins = builtins;
    assert(!agc_jit_new(&f.program, AGC_JIT_ON, &quiet) == (which == 1));
    f.code[f.fn.count - 1] = (agc_instr){AGC_OP_MOVE, 1, 2, 0};
    emit(&f, AGC_OP_JUMP, 0, 0, 0);
    assert(agc_jit_new(&f.program, AGC_JIT_ON, &quiet));
  }
}

/* mov eax, 42; ret */
static const uint8_t forty_two[] = {0xB8, 42, 0, 0, 0, 0xC3};

#ifdef __linux__
/* The range and the permissions ("rw-p", "r-xp") of the mapping of /proc/self/maps that holds P; false if none does. */
static bool mapping_of(const void *p, unsigned long *lo, unsigned long *hi, char perms[8]) {
  FILE *maps = fopen("/proc/self/maps", "r");
  assert(maps);
  char line[512];
  bool found = false;
  while (!found && fgets(line, sizeof line, maps))
    found = sscanf(line, "%lx-%lx %7s", lo, hi, perms) == 3 && (uintptr_t)p >= *lo && (uintptr_t)p < *hi;
  fclose(maps);
  return found;
}
#endif

/* True when the mapping that holds P has the permissions WANT, Linux only. */
static bool mapped_as(const void *p, const char *want) {
#ifdef __linux__
  unsigned long lo, hi;
  char perms[8];
  return mapping_of(p, &lo, &hi, perms) && strcmp(perms, want) == 0;
#else
  (void)p;
  (void)want;
  return true;
#endif
}

/* True when P and Q are in one mapping, Linux only. */
static bool one_mapping(const void *p, const void *q) {
#ifdef __linux__
  unsigned long lo, hi;
  char perms[8];
  return mapping_of(p, &lo, &hi, perms) && (uintptr_t)q >= lo && (uintptr_t)q < hi;
#else
  (void)p;
  (void)q;
  return true;
#endif
}

/* A reservation has no access; a page of it is opened writable, filled and sealed read-execute, and the next page
   keeps no access. */
static AGC_JIT_CALLER void code_memory(void) {
  size_t page = agc_jit_mem_page();
  assert(page >= 4096 && (page & (page - 1)) == 0 && AGC_JIT_CODE_CAP % page == 0);
  uint8_t *pages = agc_jit_mem_reserve(2 * page);
  assert(pages && mapped_as(pages, "---p") && mapped_as(pages + page, "---p"));
  assert(agc_jit_mem_open(pages, page));
  assert(mapped_as(pages, "rw-p") && mapped_as(pages + page, "---p"));
  memcpy(pages, forty_two, sizeof forty_two);
  assert(agc_jit_mem_seal(pages, page));
  assert(mapped_as(pages, "r-xp") && mapped_as(pages + page, "---p"));
  int (*fn)(void) = (int (*)(void))(uintptr_t)pages;
  assert(fn() == 42);
  agc_jit_mem_unmap(pages, 2 * page);
}

/* A JIT with `always` for the four functions of P, made here. */
static agc_jit *four_new(four_functions *p) {
  static const agc_trace quiet = {0};
  memset(p, 0, sizeof *p);
  for (uint32_t k = 0; k < FOUR; k++) {
    p->constants[k] = agc_int(k);
    p->code[k][0] = (agc_instr){AGC_OP_CONST, 1, (uint16_t)k, 0};
    p->code[k][1] = (agc_instr){AGC_OP_RETURN, 1, 0, 0};
    p->fns[k] = (agc_function){.name = agc_make_string("f", 1, 1), .registers = 2, .code = p->code[k],
                               .spans = p->spans, .count = 2};
  }
  p->program = (agc_program){.functions = p->fns, .function_count = FOUR, .constants = p->constants,
                             .constant_count = FOUR};
  agc_jit *jit = agc_jit_new(&p->program, AGC_JIT_ALWAYS, &quiet);
  assert(jit && !atomic_load(&jit->arena) && jit->cap == AGC_JIT_CODE_CAP);
  return jit;
}

/* Runs CODE, function K of a four_functions, which returns K. */
static AGC_JIT_CALLER void four_run(four_functions *p, agc_jit_code code, uint32_t k) {
  agc_value R[2] = {agc_nil(), agc_nil()};
  expect_exit(code(&vm, R, p->constants, 0), AGC_JIT_EXIT_RETURN, 1);
  assert(same_bits(R[1], agc_int(k)));
}

/* Each function `always` compiles is sealed at once, in the next whole pages of the first chunk of code memory,
   read-execute in one mapping, with no access past them, and the cap counts the bytes taken. A function that fits
   the last page under the cap gets it; the next one does not fit and stays interpreted. */
static void arena(void) {
  four_functions p;
  agc_jit *jit = four_new(&p);
  size_t page = agc_jit_mem_page();
  uint8_t *first = (uint8_t *)(uintptr_t)agc_jit_code_of(jit, 0, 0);
  uint8_t *second = (uint8_t *)(uintptr_t)agc_jit_code_of(jit, 1, 0);
  uint8_t *base = atomic_load(&jit->arena);
  assert(jit->chunk >= 2 * page && jit->chunk < AGC_JIT_CODE_CAP && jit->chunk_used == 2 * page);
  assert(first == base && second == base + page && atomic_load(&jit->used) == 2 * page);
  assert(mapped_as(first, "r-xp") && one_mapping(first, second) && mapped_as(base + 2 * page, "---p"));
  four_run(&p, (agc_jit_code)(uintptr_t)second, 1);
  atomic_store(&jit->used, AGC_JIT_CODE_CAP - page);
  agc_jit_code last = agc_jit_code_of(jit, 2, 0);
  assert((uint8_t *)(uintptr_t)last == base + 2 * page && atomic_load(&jit->used) == AGC_JIT_CODE_CAP);
  four_run(&p, last, 2);
  assert(!agc_jit_code_of(jit, 3, 0) && !agc_jit_may_run(jit, 3) && atomic_load(&jit->used) == AGC_JIT_CODE_CAP);
}

/* A smaller cap (what is left once the memory failed) bounds the code: two one-page functions fill two pages, and
   the third stays interpreted. */
static void small_cap(void) {
  four_functions p;
  agc_jit *jit = four_new(&p);
  size_t page = agc_jit_mem_page();
  jit->cap = 2 * page;
  agc_jit_code first = agc_jit_code_of(jit, 0, 0), second = agc_jit_code_of(jit, 1, 0);
  assert(first && second && jit->cap == 2 * page && atomic_load(&jit->used) == 2 * page);
  four_run(&p, second, 1);
  assert(!agc_jit_code_of(jit, 2, 0) && !agc_jit_may_run(jit, 2) && atomic_load(&jit->used) == 2 * page);
}

/* With `on`, functions without a loop compiled for native calls wait in the batch from their
   AGC_JIT_CALLEE_THRESHOLD-th CALL exit, and the next seal (here at that many more exits of one of them) publishes
   them together: they share one page of code memory, 16 bytes apart at most past the first one's end. Function 0 has
   a loop, so the run has a JIT; functions 1 and 2 return their index. */
static AGC_JIT_CALLER void batch(void) {
  static const agc_trace quiet = {0};
  static agc_instr loop[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_JUMP, 0, 0, 0}};
  static agc_instr one[] = {{AGC_OP_CONST, 1, 1, 0}, {AGC_OP_RETURN, 1, 0, 0}};
  static agc_instr two[] = {{AGC_OP_CONST, 1, 2, 0}, {AGC_OP_RETURN, 1, 0, 0}};
  static uint32_t spans[2] = {0};
  agc_value constants[3] = {agc_int(0), agc_int(1), agc_int(2)};
  agc_function fns[3] = {
    {.name = agc_make_string("loop", 4, 4), .registers = 2, .code = loop, .spans = spans, .count = 2},
    {.name = agc_make_string("one", 3, 3), .registers = 2, .code = one, .spans = spans, .count = 2},
    {.name = agc_make_string("two", 3, 3), .registers = 2, .code = two, .spans = spans, .count = 2},
  };
  agc_program program = {.functions = fns, .function_count = 3, .constants = constants, .constant_count = 3};
  agc_jit *jit = agc_jit_new(&program, AGC_JIT_ON, &quiet);
  assert(jit && agc_jit_native_only(jit, 1) && agc_jit_native_only(jit, 2));
  for (uint32_t call = 1; call <= AGC_JIT_CALLEE_THRESHOLD; call++)
    assert(!agc_jit_callee_code(jit, 1, false) && !agc_jit_callee_code(jit, 2, false));
  for (uint32_t call = AGC_JIT_CALLEE_THRESHOLD + 1; call < 2 * AGC_JIT_CALLEE_THRESHOLD; call++)
    assert(!agc_jit_callee_code(jit, 1, false));
  assert(atomic_load(&jit->claimed[1]) && atomic_load(&jit->claimed[2]) && !atomic_load(&jit->code[2]));
  assert(!agc_jit_may_run(jit, 1) && atomic_load(&jit->used) == 0);
  size_t page = agc_jit_mem_page();
  uint8_t *first = (uint8_t *)(uintptr_t)agc_jit_callee_code(jit, 1, false);
  uint8_t *second = (uint8_t *)(uintptr_t)atomic_load(&jit->code[2]);
  assert(first == atomic_load(&jit->arena) && second > first && second < first + page);
  assert((size_t)(second - first) % 16 == 0 && atomic_load(&jit->used) == page);
  assert(mapped_as(first, "r-xp") && agc_jit_may_run(jit, 1) && agc_jit_may_run(jit, 2));
  agc_value R[2] = {agc_nil(), agc_nil()};
  expect_exit(((agc_jit_code)(uintptr_t)first)(&vm, R, constants, 0), AGC_JIT_EXIT_RETURN, 1);
  assert(same_bits(R[1], agc_int(1)));
  expect_exit(((agc_jit_code)(uintptr_t)second)(&vm, R, constants, 0), AGC_JIT_EXIT_RETURN, 1);
  assert(same_bits(R[1], agc_int(2)));
}

/* A loop in the last function calls each of CALLEES functions once; the even ones call a builtin that is not a leaf,
   so they leave compiled code and stay out with `on`, and the caller's loop leaves too often then. Returns the work
   of settling it, and its instructions in *TOTAL. */
static size_t settle_work(uint32_t callees, size_t *total) {
  agc_instr *leaving = agc_alloc_atomic(2 * sizeof *leaving), *quiet = agc_alloc_atomic(sizeof *quiet);
  leaving[0] = (agc_instr){AGC_OP_CALL_BUILTIN, 0, 0, 0};
  leaving[1] = quiet[0] = (agc_instr){AGC_OP_RETURN, 0, 0, 0};
  agc_instr *loop = agc_alloc_atomic((callees + 2) * sizeof *loop);
  loop[0] = (agc_instr){AGC_OP_STEP, 1, 0, 0};
  for (uint32_t k = 0; k < callees; k++) loop[k + 1] = (agc_instr){AGC_OP_CALL, 0, (uint16_t)k, (uint16_t)(k >> 16)};
  loop[callees + 1] = (agc_instr){AGC_OP_JUMP, 0, 0, 0};
  agc_function *fns = agc_alloc((callees + 1) * sizeof *fns);
  *total = 0;
  for (uint32_t k = 0; k <= callees; k++) {
    fns[k] = (agc_function){.registers = 2};
    fns[k].code = k == callees ? loop : k % 2 ? quiet : leaving;
    fns[k].count = k == callees ? callees + 2 : k % 2 ? 1 : 2;
    *total += fns[k].count;
  }
  agc_builtin other = {.leaf = false};
  const agc_builtin *builtins[1] = {&other};
  agc_program program = {.functions = fns, .function_count = callees + 1, .builtins = builtins};
  bool *callable = agc_alloc_atomic(callees + 1), *looped = agc_alloc_atomic(callees + 1);
  bool *calling = agc_alloc_atomic(callees + 1);
  size_t work = agc_jit_settle(&program, callable, looped, calling);
  for (uint32_t k = 0; k < callees; k++) assert(callable[k] == (k % 2 == 1) && !looped[k] && !calling[k]);
  assert(!callable[callees] && looped[callees] && calling[callees]);
  return work;
}

/* Settling reads each instruction a few times and counts each call site once, so its work stays within a small
   multiple of the program's size, and twice the callees take about twice the work (a caller walked again at each
   callee that drops out made it grow with the square). */
static void settle_is_linear(void) {
  size_t total, double_total;
  size_t work = settle_work(20000, &total), double_work = settle_work(40000, &double_total);
  if (work > 5 * total || double_work > 5 * double_total || 2 * double_work > 5 * work)
    fprintf(stderr, "jit-test: settling did %zu and %zu units of work for %zu and %zu instructions\n", work,
            double_work, total, double_total);
  assert(work <= 5 * total && double_work <= 5 * double_total && 2 * double_work <= 5 * work);
}
#endif

int main(void) {
  agc_init();
  agc_gc_allow_threads();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
#if AGC_JIT_HOST
  code_memory();
  arena();
  small_cap();
  batch();
  settle_is_linear();
  compile_race();
  cap_inside_an_offset();
  bytes();
  call_return_exits();
  native_calls();
  direct_calls();
  loops_and_steps();
  int_rules();
  helpers();
  reads();
  string_cost();
  string_build_cost();
  maps_and_lists();
  closures();
  ineligible();
  every_opcode_compiles();
#else
  /* No emitter on this host: the JIT is never made. */
  agc_program empty = {0};
  assert(!agc_jit_new(&empty, AGC_JIT_ALWAYS, &vm.rt->trace));
#endif
  return 0;
}
