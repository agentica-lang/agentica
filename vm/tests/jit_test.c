/*
 * The JIT (vm/jit/): the x86-64 bytes of known instructions, compiled functions run directly (results, steps, exits,
 * failures that leave the result register alone), and the code memory sealed read-execute, never writable then.
 */
#include "../jit/jit.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

#define MAX_CODE 32

typedef struct {
  agc_program program;
  agc_function fn;
  agc_instr code[MAX_CODE];
  uint32_t spans[MAX_CODE];
  agc_value constants[4];
} one_function;

static agc_vm vm;

/* The tag and the 8-byte payload: bytes 4 to 7 are padding that the constructors leave unset. */
static bool same_bits(agc_value x, agc_value y) { return x.tag == y.tag && agc_value_word(x) == agc_value_word(y); }

#if AGC_JIT_HOST
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
  return agc_jit_code_of(jit, 0);
}

static void expect_exit(agc_jit_exit got, uint32_t status, uint32_t pc) { assert(got.status == status && got.pc == pc); }

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

static void loops_and_steps(void) {
  one_function f;
  sum_loop(&f);
  agc_jit_code code = compile(&f);
  assert(code);
  agc_value R[8] = {agc_int(10)};
  vm.next_stop = 1000;
  expect_exit(code(&vm, R, f.constants, 0), AGC_JIT_EXIT_INTERPRET, 9);
  assert(same_bits(R[2], agc_int(45)) && vm.next_stop == 1000 - 11);
  /* The STEP takes its fast path while next_stop is above its count, as the interpreter's: from 3, two passes, then
     the exit for the slow path at the STEP, and the code goes on from the next instruction. */
  R[0] = agc_int(10);
  vm.next_stop = 3;
  expect_exit(code(&vm, R, f.constants, 0), AGC_JIT_EXIT_STEP, 2);
  assert(vm.next_stop == 1 && same_bits(R[1], agc_int(2)));
  vm.next_stop = 1000;
  expect_exit(code(&vm, R, f.constants, 3), AGC_JIT_EXIT_INTERPRET, 9);
  assert(same_bits(R[2], agc_int(45)));
  /* A wrong tag on the compare leaves at its pc. */
  R[0] = agc_nil();
  expect_exit(code(&vm, R, f.constants, 0), AGC_STATUS_WRONG_TAG, 3);
}

/* R3 = R1 op R2, then RETURN R3: the exit for each case, and R3 left alone on a failure. */
static void binary(agc_opcode op, agc_value x, agc_value y, uint32_t status, agc_value want) {
  one_function f;
  memset(&f, 0, sizeof f);
  emit(&f, op, 3, 1, 2);
  emit(&f, AGC_OP_RETURN, 3, 0, 0);
  agc_jit_code code = compile(&f);
  assert(code);
  agc_value mark = agc_nil();
  agc_value R[8] = {agc_nil(), x, y, mark};
  agc_jit_exit out = code(&vm, R, f.constants, 0);
  if (status == AGC_STATUS_OK) {
    expect_exit(out, AGC_JIT_EXIT_INTERPRET, 1);
    assert(same_bits(R[3], want));
  } else {
    expect_exit(out, status, 0);
    assert(same_bits(R[3], mark));
  }
}

static void int_rules(void) {
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
  expect_exit(code(&vm, R, f.constants, 0), AGC_JIT_EXIT_INTERPRET, 1);
  assert(same_bits(R[3], agc_int(-5)));
}

/* A String compare charges its bytes to the task's turn cost, and the code leaves for the interpreter to apply it. */
static void string_cost(void) {
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

/* Functions with an instruction the emitter does not know stay interpreted. */
static void ineligible(void) {
  one_function f;
  memset(&f, 0, sizeof f);
  emit(&f, AGC_OP_CALL_BUILTIN, 0, 0, 0);
  emit(&f, AGC_OP_RETURN, 0, 0, 0);
  assert(!compile(&f));
}

/* mov eax, 42; ret */
static const uint8_t forty_two[] = {0xB8, 42, 0, 0, 0, 0xC3};
#endif

/* The permissions of the mapping that holds P in /proc/self/maps ("rw-p", "r-xp"), Linux only. */
static bool mapped_as(const void *p, const char *want) {
#ifdef __linux__
  FILE *maps = fopen("/proc/self/maps", "r");
  assert(maps);
  char line[512];
  bool found = false;
  while (!found && fgets(line, sizeof line, maps)) {
    unsigned long lo, hi;
    char perms[8];
    if (sscanf(line, "%lx-%lx %7s", &lo, &hi, perms) == 3 && (uintptr_t)p >= lo && (uintptr_t)p < hi)
      found = strcmp(perms, want) == 0;
  }
  fclose(maps);
  return found;
#else
  (void)p;
  (void)want;
  return true;
#endif
}

static void code_memory(void) {
#if AGC_JIT_HOST
  uint8_t *pages = agc_jit_mem_map(sizeof forty_two);
  assert(pages && mapped_as(pages, "rw-p"));
  memcpy(pages, forty_two, sizeof forty_two);
  assert(agc_jit_mem_seal(pages, sizeof forty_two));
  assert(mapped_as(pages, "r-xp"));
  int (*fn)(void) = (int (*)(void))(uintptr_t)pages;
  assert(fn() == 42);
  agc_jit_mem_unmap(pages, sizeof forty_two);
#endif
}

int main(void) {
  agc_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  code_memory();
#if AGC_JIT_HOST
  bytes();
  loops_and_steps();
  int_rules();
  string_cost();
  ineligible();
#else
  /* No emitter on this host: the JIT is never made. */
  agc_program empty = {0};
  assert(!agc_jit_new(&empty, AGC_JIT_ALWAYS, &vm.rt->trace));
#endif
  return 0;
}
