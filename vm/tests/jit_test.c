/*
 * The JIT (vm/jit/): the x86-64 bytes of known instructions, compiled functions run directly (results, steps, exits,
 * failures that leave the result register alone), the code memory sealed read-execute, never writable then, and
 * one copy kept when several threads compile a function at once.
 */
#include "../jit/jit.h"

#include <assert.h>
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

static AGC_JIT_CALLER void loops_and_steps(void) {
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
static AGC_JIT_CALLER void binary(agc_opcode op, agc_value x, agc_value y, uint32_t status, agc_value want) {
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
  expect_exit(code(&vm, R, f.constants, 0), AGC_JIT_EXIT_INTERPRET, 1);
  assert(same_bits(R[3], agc_int(-5)));
}

/* The instructions that call their opcode helper: the C code's results (NaN compares false, -0.0 keeps its sign) and
   statuses (a Float division by zero, a list index outside the list, a wrong tag). */
static AGC_JIT_CALLER void helpers(void) {
  agc_value nan = agc_float(NAN), two = agc_float(2.0), any = agc_nil();
  agc_value items[3] = {agc_int(7), agc_int(8), agc_int(9)};
  agc_value list = agc_list_value(agc_list_from_array(items, 3));
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

/* Several schedulers ask for the code of one function at once (`make vm-tsan` runs this): each gets the one copy
   that was published, and the copies that lost the race were unmapped. The barrier lets them start together, so
   more than one compiles and the losing side of the compare-and-swap runs. */
#define RACERS 4
static agc_jit *race_jit;
static agc_jit_code race_code[RACERS];
static uv_barrier_t race_start;

static void race_one(void *arg) {
  assert(agc_gc_thread_enter());
  uv_barrier_wait(&race_start);
  race_code[(uintptr_t)arg] = agc_jit_code_of(race_jit, 0);
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
  for (size_t k = 0; k < RACERS; k++) assert(race_code[k] && race_code[k] == race_code[0]);
  assert(agc_jit_code_of(race_jit, 0) == race_code[0]);
  assert(atomic_load(&race_jit->used) == 4096);
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

/* Every opcode compiles with `always`: one without code of its own, such as CALL_BUILTIN, leaves for the interpreter
   at its pc. */
static AGC_JIT_CALLER void every_opcode_compiles(void) {
  static const agc_trace quiet = {0};
  for (uint32_t op = 0; op < AGC_OP_COUNT; op++) {
    one_function f;
    memset(&f, 0, sizeof f);
    emit(&f, (agc_opcode)op, 1, 1, 0);
    emit(&f, AGC_OP_RETURN, 0, 0, 0);
    program_of(&f);
    agc_jit *jit = agc_jit_new(&f.program, AGC_JIT_ALWAYS, &quiet);
    if (!jit || !agc_jit_code_of(jit, 0)) {
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
}

/* `on` keeps out a function without a loop, and one whose loop goes back to the interpreter (a builtin that is not a
   leaf) more than once in AGC_JIT_SPACING instructions; a leaf builtin does not count, as run_compiled calls it. A
   program where no function is compiled has no JIT at all. */
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
  agc_builtin leaf = {.leaf = true}, other = {.leaf = false};
  const agc_builtin *builtins[2] = {&leaf, &other};
  for (uint32_t which = 0; which < 2; which++) {
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

static AGC_JIT_CALLER void code_memory(void) {
  uint8_t *pages = agc_jit_mem_map(sizeof forty_two);
  assert(pages && mapped_as(pages, "rw-p"));
  memcpy(pages, forty_two, sizeof forty_two);
  assert(agc_jit_mem_seal(pages, sizeof forty_two));
  assert(mapped_as(pages, "r-xp"));
  int (*fn)(void) = (int (*)(void))(uintptr_t)pages;
  assert(fn() == 42);
  agc_jit_mem_unmap(pages, sizeof forty_two);
}
#endif

int main(void) {
  agc_init();
  agc_gc_allow_threads();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
#if AGC_JIT_HOST
  code_memory();
  compile_race();
  cap_inside_an_offset();
  bytes();
  loops_and_steps();
  int_rules();
  helpers();
  reads();
  string_cost();
  ineligible();
  every_opcode_compiles();
#else
  /* No emitter on this host: the JIT is never made. */
  agc_program empty = {0};
  assert(!agc_jit_new(&empty, AGC_JIT_ALWAYS, &vm.rt->trace));
#endif
  return 0;
}
