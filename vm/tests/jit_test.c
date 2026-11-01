/*
 * The JIT (vm/jit/): the x86-64 bytes of known instructions, compiled functions run directly (results, steps, exits,
 * failures, native calls, calls of function values, tail calls, direct builtins, map reads, lists, closures, globals,
 * structs, enums, `try`), block calls that start their block again in place, sealed code memory packed up to its cap,
 * the compile budget's stop, one copy made by racing threads, and the `on` decision.
 */
#include "../jit/jit.h"
#include "test_program.h"
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

enum { BLOCK_ITEMS = 1000 };

/* The program of block_calls_in_place. main: sum = [1..1000].reduce(0) do |acc, x| acc + x end, Test.record(sum), then [1..1000].map with a block that
   adds its capture 100, Test.record of that list. */
typedef struct {
  agc_function fns[3];
  agc_instr code[3][MAX_CODE];
  uint32_t spans[3][MAX_CODE];
  agc_span span_table[16];
  agc_test_source source;
  agc_value constants[8];
  const agc_builtin *builtins[3];
  agc_program program;
} block_program;

/* The program of string_code_calls. main: R1 = the String constant, R1 = R1.code (span 3), Test.record(R1)
   (span 4), return. */
typedef struct {
  agc_function fns[1];
  agc_instr code[1][MAX_CODE];
  uint32_t spans[1][MAX_CODE];
  agc_span span_table[8];
  agc_test_source source;
  agc_value constants[1];
  const agc_builtin *builtins[2];
  agc_program program;
} code_program;

static agc_vm vm;

/* The code memory test runs on every machine that has a JIT or will have one, emitter or not: a function that
   returns 42 (mov eax, 42; ret on x86-64, mov w0, #42; ret on arm64), and the mappings it lives in. */
#if defined(__x86_64__) || defined(_M_X64)
#define CODE_MEMORY_TEST 1
static const uint8_t forty_two[] = {0xB8, 42, 0, 0, 0, 0xC3};
#elif defined(__aarch64__)
#define CODE_MEMORY_TEST 1
static const uint8_t forty_two[] = {0x40, 0x05, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6};
#else
#define CODE_MEMORY_TEST 0
#endif

#if CODE_MEMORY_TEST
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
#endif

#if AGC_JIT_HOST
/* The tests of x86-64 encodings and sizes, and of native calls in compiled code, which arm64 does not make yet
   (#756): there each call takes its exit. vm/tests/jit_a64_test.c checks the arm64 words. */
#if defined(__x86_64__) || defined(_M_X64)
#define X64 1
#define NATIVE_CALLS 1
#else
#define X64 0
#define NATIVE_CALLS 0
#endif

/* N, as a count of the JIT's trace counters (transitions, turns, leaves): a build with the trace points compiled out
   (make TRACE=0, the vm-trace-off check) counts nothing. */
#define TRACE_COUNT(n) (AGC_TRACE_BUILD ? (uint64_t)(n) : 0)

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
  /* The entry from C jumps over the tail entry (jmp rel32) and the native entry (push rbx first). */
  assert(e.code[0] == 0xEB && e.code[AGC_JIT_TAIL_ENTRY] == 0xE9 && e.code[AGC_JIT_NATIVE_ENTRY] == 0x53);
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

/* A CALL that cannot be native and a RETURN not called natively take their exits, and a TAIL_CALL of a function past
   the program's table (hand-made code) leaves for the interpreter. */
static AGC_JIT_CALLER void call_return_exits(void) {
  one_function f;
  memset(&f, 0, sizeof f);
  emit(&f, AGC_OP_CALL, 0, 0, 0);
  emit(&f, AGC_OP_RETURN, 0, 0, 0);
  emit(&f, AGC_OP_TAIL_CALL, 1, 1, 0);
  agc_jit_code code = compile(&f);
  assert(code);
  agc_value R[8] = {agc_int(42)};
  expect_exit(code(&vm, R, f.constants, 0), AGC_JIT_EXIT_CALL, 0);
  expect_exit(code(&vm, R, f.constants, 1), AGC_JIT_EXIT_RETURN, 1);
  expect_exit(code(&vm, R, f.constants, 2), AGC_JIT_EXIT_INTERPRET, 2);
  assert(same_bits(R[0], agc_int(42)));
}

/* The task T runs function 0 in FRAMES (room for 2, one in use) with the 8 registers REGS. */
static void run_on(agc_task *t, agc_frame *frames, agc_value *regs) {
  t->frames = frames;
  t->frame_capacity = 2;
  t->frame_count = t->depth = 1;
  t->regs = regs;
  t->reg_capacity = 8;
}

/* The code of function 0 of PROGRAM, compiled with `always` once function 1 has code; *JIT is the run's JIT. */
static agc_jit_code first_two(agc_program *program, agc_jit **jit) {
  static const agc_trace quiet = {0};
  *jit = agc_jit_new(program, AGC_JIT_ALWAYS, &quiet);
  assert(*jit && agc_jit_code_of(*jit, 1, 0));
  agc_jit_code code = agc_jit_code_of(*jit, 0, 0);
  assert(code);
  return code;
}

/* Function 0 calls function 1, which adds 1 to its argument, natively: the frame is pushed and popped in compiled code
   and the result lands in the caller's window. A STEP exit inside the callee comes out of the caller with the callee's
   frame on top, and a task without room for the frame takes the CALL exit with nothing pushed. */
static AGC_JIT_CALLER void native_calls(void) {
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
  agc_jit *jit;
  agc_jit_code code = first_two(&program, &jit);
  agc_task *t = vm.task, saved = *vm.task;
  agc_frame frames[2] = {{.function = 0}};
  agc_value regs[8] = {0};
  run_on(t, frames, regs);
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

/* Function 0 calls function 1 natively with n in R2; function 1 tail-calls function 2 (sum) with (n, 0), which adds n,
   n - 1, ..., 1 by tail-calling itself, and returns the sum to function 0's R2. A native tail call keeps the frame's
   base, ret and depth and marks it tail, as replace_frame does; a callee without code, or a register file without room
   for its registers, takes the TAIL_CALL exit with the caller's frame and its window as they were. A STEP exit inside
   the chain comes out with the tail-called frame on top, and a million tail calls never grow the C stack. */
static AGC_JIT_CALLER void native_tail_calls(void) {
  static agc_instr outer[] = {{AGC_OP_CALL, 2, 1, 0}, {AGC_OP_RETURN, 2, 0, 0}};
  static agc_instr start[] = {
    {AGC_OP_STEP, 1, 0, 0}, {AGC_OP_MOVE, 2, 0, 0}, {AGC_OP_CONST, 3, 0, 0}, {AGC_OP_TAIL_CALL, 2, 2, 0}};
  static agc_instr sum[] = {
    {AGC_OP_STEP, 1, 0, 0},  {AGC_OP_CONST, 2, 0, 0}, {AGC_OP_EQ, 3, 0, 2},    {AGC_OP_JUMP_IF_FALSE, 3, 5, 0},
    {AGC_OP_RETURN, 1, 0, 0}, {AGC_OP_CONST, 4, 1, 0}, {AGC_OP_SUB_I, 4, 0, 4}, {AGC_OP_ADD_I, 5, 1, 0},
    {AGC_OP_TAIL_CALL, 4, 2, 0}};
  static uint32_t spans[9] = {0};
  agc_value constants[2] = {agc_int(0), agc_int(1)};
  agc_function fns[3] = {
    {.name = agc_make_string("outer", 5, 5), .registers = 4, .code = outer, .spans = spans, .count = 2},
    {.name = agc_make_string("start", 5, 5), .registers = 4, .params = 1, .code = start, .spans = spans, .count = 4},
    {.name = agc_make_string("sum", 3, 3), .registers = 6, .params = 2, .code = sum, .spans = spans, .count = 9},
  };
  agc_program program = {.functions = fns, .function_count = 3, .constants = constants, .constant_count = 2};
  agc_task *t = vm.task, saved = *vm.task;
  agc_value regs[8] = {0};
  agc_frame frames[2] = {{.function = 0}};
  run_on(t, frames, regs);
  agc_jit *jit;
  agc_jit_code code = first_two(&program, &jit);
  /* sum has no code yet. */
  regs[2] = agc_int(10);
  vm.next_stop = 1000;
  expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_TAIL_CALL, 3);
  assert(t->frame_count == 2 && t->depth == 2 && frames[1].function == 1 && !frames[1].tail);
  assert(same_bits(regs[2], agc_int(10)) && same_bits(regs[4], agc_int(10)) && same_bits(regs[5], agc_int(0)));
  assert(agc_jit_code_of(jit, 2, 0));
  /* sum's 6 registers from base 2 would pass a register file of 7. */
  t->frame_count = t->depth = 1;
  t->reg_capacity = 7;
  expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_TAIL_CALL, 3);
  assert(t->frame_count == 2 && frames[1].function == 1 && !frames[1].tail && same_bits(regs[2], agc_int(10)));
  /* They end exactly at the end of a file of 8: 1 STEP of start and 11 of sum, no exit until outer's RETURN. */
  t->frame_count = t->depth = 1;
  t->reg_capacity = 8;
  vm.next_stop = 1000;
  expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_RETURN, 1);
  assert(same_bits(regs[2], agc_int(55)) && t->frame_count == 1 && t->depth == 1 && vm.next_stop == 1000 - 12);
  /* The fourth STEP of sum is the slow one: three self tail calls ran. */
  regs[2] = agc_int(10);
  vm.next_stop = 5;
  expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_STEP, 0);
  assert(t->frame_count == 2 && t->depth == 2 && frames[0].pc == 1);
  assert(frames[1].function == 2 && frames[1].pc == 0 && frames[1].base == 2 && frames[1].ret == 2 && frames[1].tail &&
         !frames[1].native);
  assert(same_bits(regs[2], agc_int(7)) && same_bits(regs[3], agc_int(27)));
  /* A million tail calls in one run of the code. */
  t->frame_count = t->depth = 1;
  regs[2] = agc_int(1000000);
  vm.next_stop = INT64_MAX;
  expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_RETURN, 1);
  assert(same_bits(regs[2], agc_int(500000500000)) && t->frame_count == 1 && t->depth == 1);
  *t = saved;
  vm.next_stop = 1000;
}

/* A TAIL_CALL of a callee with more than AGC_JIT_TAIL_PARAMS arguments takes the TAIL_CALL exit, even a self one with
   room for its registers, and its code is a few bytes, however many arguments (65,534 at most); a self TAIL_CALL like
   that is no loop for `on`. */
static AGC_JIT_CALLER void wide_tail_calls(void) {
  agc_emitter e;
  agc_jit_code none = NULL;
  agc_instr call = {AGC_OP_TAIL_CALL, 1, 0, 0};
  size_t size[3];
  for (int k = 0; k < 3; k++) {
    agc_emit_begin(&e, 1);
    size_t start = e.len;
    uint32_t params = k == 2 ? AGC_JIT_TAIL_PARAMS : 65534;
    agc_emit_tail_call(&e, call, 0, k == 1, (uint64_t)(uintptr_t)&none, params, params + 1, 0);
    size[k] = e.len - start;
  }
  assert(size[0] <= 8 && size[1] <= 8 && size[2] > (size_t)32 * AGC_JIT_TAIL_PARAMS);
  /* A self TAIL_CALL (no native call needed) of 33 arguments exits with the frame as it was. */
  static agc_instr wide[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_TAIL_CALL, 1, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  static uint32_t spans[3] = {0};
  agc_value constants[1] = {agc_int(0)};
  uint32_t many = AGC_JIT_TAIL_PARAMS + 1;
  agc_function fns[1] = {{.name = agc_make_string("wide", 4, 4), .registers = many + 1, .params = many, .code = wide,
                          .spans = spans, .count = 3}};
  agc_program program = {.functions = fns, .function_count = 1, .constants = constants, .constant_count = 1};
  static const agc_trace quiet = {0};
  agc_jit *jit = agc_jit_new(&program, AGC_JIT_ALWAYS, &quiet);
  agc_jit_code code = jit ? agc_jit_code_of(jit, 0, 0) : NULL;
  assert(code);
  agc_task *t = vm.task, saved = *vm.task;
  agc_value regs[64] = {0};
  agc_frame frames[2] = {{.function = 0}};
  run_on(t, frames, regs);
  t->reg_capacity = 64;
  regs[0] = agc_int(99);
  regs[1] = agc_int(7);
  vm.next_stop = 1000;
  expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_TAIL_CALL, 1);
  assert(t->frame_count == 1 && frames[0].function == 0 && !frames[0].tail && same_bits(regs[0], agc_int(99)));
  *t = saved;
  bool callable[1], looped[1], calling[1];
  agc_jit_settle(&program, callable, looped, calling);
  assert(!looped[0]);
}

/* Function 0 calls the function value in R2 with R3 as its argument: function 1, which adds its capture to it into its
   R1. The call is native once function 1 has code (agc_jit_call_value pushes the frame, base 3 and result to R2, with
   the capture after the argument) and the result lands in R2, while R3, the callee's R0, keeps what the callee left
   there, as the interpreter's RETURN leaves it (#807: hand-made bytecode may read it after the call). A callee without
   code yet, a task without room for the frame, its registers or one more depth, and a value that does not match the
   call take the CALL_VALUE exit with nothing pushed, for run_compiled to call it, or fail, as the interpreter does. */
static AGC_JIT_CALLER void call_values(void) {
  static const agc_trace quiet = {0};
  static agc_instr caller[] = {{AGC_OP_CALL_VALUE, 2, 1, 0}, {AGC_OP_RETURN, 2, 0, 0}};
  static agc_instr callee[] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_ADD_I, 1, 0, 1}, {AGC_OP_RETURN, 1, 0, 0}};
  static uint32_t spans[3] = {0};
  agc_value constants[1] = {agc_int(0)};
  agc_function fns[2] = {
    {.name = agc_make_string("caller", 6, 6), .registers = 4, .code = caller, .spans = spans, .count = 2},
    {.name = agc_make_string("callee", 6, 6), .registers = 2, .params = 1, .captures = 1, .code = callee,
     .spans = spans, .count = 3},
  };
  agc_program program = {.functions = fns, .function_count = 2, .constants = constants, .constant_count = 1};
  agc_jit *jit = agc_jit_new(&program, AGC_JIT_ALWAYS, &quiet);
  assert(jit);
  agc_jit_code code = agc_jit_code_of(jit, 0, 0);
  assert(code);
  const agc_program *saved_program = vm.rt->program;
  agc_jit *saved_jit = vm.rt->jit;
  vm.rt->program = &program;
  vm.rt->jit = jit;
  agc_task *t = vm.task, saved = *vm.task;
  agc_frame frames[2] = {{.function = 0}};
  agc_value regs[8] = {0};
  run_on(t, frames, regs);
  agc_fn *adder = agc_new_fn(1, 1);
  adder->captured[0] = agc_int(100);
  agc_value fn = agc_fn_value(adder);
  vm.next_stop = 1000;
  /* Function 1 has no code yet. */
  regs[2] = fn;
  regs[3] = agc_int(41);
  expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_CALL_VALUE, 0);
  assert(t->frame_count == 1 && t->depth == 1 && same_bits(regs[2], fn));
  assert(agc_jit_code_of(jit, 1, 0));
  expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_RETURN, 1);
  assert(same_bits(regs[2], agc_int(141)) && t->frame_count == 1 && t->depth == 1 && frames[0].pc == 1);
  assert(same_bits(regs[3], agc_int(41)) && same_bits(regs[4], agc_int(141)));
  assert(vm.next_stop == 999);
  regs[2] = fn;
  regs[3] = agc_int(41);
  vm.next_stop = 1;
  expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_STEP, 0);
  assert(t->frame_count == 2 && t->depth == 2 && frames[0].pc == 1);
  assert(frames[1].function == 1 && frames[1].pc == 0 && frames[1].base == 3 && frames[1].ret == 2 &&
         !frames[1].tail && !frames[1].native);
  assert(same_bits(regs[3], agc_int(41)) && same_bits(regs[4], agc_int(100)));
  t->frame_count = t->depth = 1;
  vm.next_stop = 1000;
  /* No room for the frame, the callee's registers (3 + 2 of them) or one more depth. */
  t->frame_capacity = 1;
  expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_CALL_VALUE, 0);
  assert(t->frame_count == 1 && t->depth == 1);
  t->frame_capacity = 2;
  t->reg_capacity = 4;
  expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_CALL_VALUE, 0);
  t->depth = AGC_MAX_DEPTH;
  t->reg_capacity = 5;
  expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_CALL_VALUE, 0);
  assert(t->frame_count == 1 && t->depth == AGC_MAX_DEPTH);
  /* The callee's registers end exactly at the end of the register file. */
  t->depth = 1;
  regs[3] = agc_int(41);
  expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_RETURN, 1);
  assert(same_bits(regs[2], agc_int(141)) && t->frame_count == 1 && t->depth == 1);
  /* Not a function value, another arity, another capture count, a function past the table (hand-made code). */
  agc_value wrong[4] = {agc_int(5), agc_fn_value(agc_new_fn(0, 0)), agc_fn_value(agc_new_fn(1, 0)),
                        agc_fn_value(agc_new_fn(2, 0))};
  for (size_t k = 0; k < 4; k++) {
    regs[2] = wrong[k];
    expect_exit(code(&vm, regs, constants, 0), AGC_JIT_EXIT_CALL_VALUE, 0);
    assert(t->frame_count == 1 && t->depth == 1 && same_bits(regs[2], wrong[k]));
  }
  *t = saved;
  vm.rt->program = saved_program;
  vm.rt->jit = saved_jit;
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

static agc_value subtracts(agc_vm *v, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int(agc_as_int(v, args[0]) - agc_as_int(v, args[1]));
}

/* A CALL_BUILTIN of a direct row runs in compiled code (agc_jit_call_builtin): the result in the window, the top
   frame's pc after the call, the turn cost applied; a cost that ends the turn leaves with YIELD after the result is
   written; a failure is caught and leaves with RAISE, the failure recorded at the builtin's span and the window left
   alone. A row that is not direct takes the INTERPRET exit, and so does a leaf row at native depth 0
   (native_leaf_calls). */
static AGC_JIT_CALLER void direct_calls(void) {
  static const agc_builtin add_row = {"Test.adds", 2, adds, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true};
  static const agc_builtin fail_row = {"Test.refuses", 0, refuses, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true};
  static const agc_builtin tail_row = {"Test.adds", 2, adds, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false};
  static const agc_builtin leaf_row = {"Test.subtracts", 2, subtracts, AGC_NATIVE_NONE, AGC_COST_NONE,
                                       false, true, false};
  static one_function fs[4];
  const agc_builtin *rows[4] = {&add_row, &fail_row, &tail_row, &leaf_row};
  agc_task *t = vm.task, saved = *vm.task;
  agc_outcome outcome = *vm.outcome;
  agc_frame frames[1] = {{.function = 0}};
  t->frames = frames;
  t->frame_capacity = t->frame_count = t->depth = 1;
  agc_jit_code code[4];
  for (uint16_t k = 0; k < 4; k++) {
    memset(&fs[k], 0, sizeof fs[k]);
    emit(&fs[k], AGC_OP_CALL_BUILTIN, 1, k, 0);
    emit(&fs[k], AGC_OP_RETURN, 1, 0, 0);
    fs[k].spans[0] = 7;
    fs[k].program.builtins = rows;
    fs[k].program.builtin_count = 4;
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
  expect_exit(code[3](&vm, R, NULL, 0), AGC_JIT_EXIT_INTERPRET, 0);
  *vm.outcome = outcome;
  *t = saved;
  vm.next_stop = 1000;
}

/* Function 0 calls function 1 natively, whose CALL_BUILTIN of a leaf row (agc_jit_call_leaf) runs in compiled code:
   the result in the callee's window, its frame's pc after the call, nothing charged even with no turn left, and the
   RETURN native, so the native call is never unwound. Entered at native depth 0, the same code takes the INTERPRET
   exit at the call instead, for run_compiled to call the leaf. A leaf that fails under the native call leaves with
   RAISE, the callee's frame on top and the failure at the builtin's span. */
static AGC_JIT_CALLER void native_leaf_calls(void) {
  static const agc_builtin rows[2] = {
    {"Test.subtracts", 2, subtracts, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false},
    {"Test.refuses", 0, refuses, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false}};
  agc_task *t = vm.task, saved = *vm.task;
  agc_outcome outcome = *vm.outcome;
  int64_t left = vm.turn_left;
  for (uint16_t k = 0; k < 2; k++) {
    agc_instr caller[] = {{AGC_OP_CALL, 2, 1, 0}, {AGC_OP_RETURN, 2, 0, 0}};
    agc_instr callee[] = {{AGC_OP_CALL_BUILTIN, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
    uint32_t spans[2] = {7, 0};
    const agc_builtin *table[1] = {&rows[k]};
    agc_function fns[2] = {
      {.name = agc_make_string("caller", 6, 6), .registers = 4, .code = caller, .spans = spans, .count = 2},
      {.name = agc_make_string("callee", 6, 6), .registers = 2, .code = callee, .spans = spans, .count = 2},
    };
    agc_program program = {.functions = fns, .function_count = 2, .builtins = table, .builtin_count = 1};
    agc_jit *jit;
    agc_jit_code code = first_two(&program, &jit);
    agc_frame frames[2] = {{.function = 0}};
    agc_value regs[8] = {0};
    run_on(t, frames, regs);
    regs[2] = agc_int(50);
    regs[3] = agc_int(8);
    vm.turn_left = 1;
    vm.rt->program = &program;
    if (k == 0) {
      expect_exit(code(&vm, regs, NULL, 0), AGC_JIT_EXIT_RETURN, 1);
      assert(same_bits(regs[2], agc_int(42)) && t->frame_count == 1 && t->turn_cost == 0 && vm.turn_left == 1);
      agc_jit_code alone = agc_jit_code_of(jit, 1, 0);
      expect_exit(alone(&vm, regs + 2, NULL, 0), AGC_JIT_EXIT_INTERPRET, 0);
      assert(same_bits(regs[2], agc_int(42)));
    } else {
      expect_exit(code(&vm, regs, NULL, 0), AGC_JIT_EXIT_RAISE, 0);
      assert(t->frame_count == 2 && frames[1].function == 1 && frames[1].pc == 1 && !vm.jit_catch);
      assert(vm.outcome->kind == AGC_FAILED && strcmp(vm.outcome->code, "RUNTIME-TEST") == 0 && vm.outcome->span == 8);
      assert(same_bits(regs[2], agc_int(50)));
    }
    vm.rt->program = NULL;
    *vm.outcome = outcome;
  }
  *t = saved;
  vm.turn_left = left;
}

static agc_value counts(agc_vm *v, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int((int64_t)agc_as_string(v, args[0])->chars * 10);
}

/* R1 = ROW(ARG), then RETURN R1, compiled and run at native depth 0 with one unit of the turn left: the exit, with R1
   in *OUT. A plain leaf charges nothing, so the turn is as it was. */
static AGC_JIT_CALLER agc_jit_exit plain_call(const agc_builtin *row, agc_value arg, agc_value *out) {
  static one_function f;
  const agc_builtin *rows[1] = {row};
  memset(&f, 0, sizeof f);
  emit(&f, AGC_OP_CALL_BUILTIN, 1, 0, 0);
  emit(&f, AGC_OP_RETURN, 1, 0, 0);
  f.program.builtins = rows;
  f.program.builtin_count = 1;
  agc_jit_code code = compile(&f);
  assert(code);
  agc_task *t = vm.task, saved = *vm.task;
  agc_frame frames[1] = {{.function = 0}};
  t->frames = frames;
  t->frame_capacity = t->frame_count = t->depth = 1;
  int64_t left = vm.turn_left;
  vm.turn_left = 1;
  agc_value R[4] = {agc_nil(), arg, agc_nil(), agc_nil()};
  agc_jit_exit got = code(&vm, R, NULL, 0);
  assert(t->turn_cost == 0 && vm.turn_left == 1);
  *out = R[1];
  vm.turn_left = left;
  *t = saved;
  return got;
}

/* The rows of plain_leaves are leaf rows of the builtin tables, and only those get checks; a one-character check
   follows a String tag check of the same argument. Such a row runs in compiled
   code at native depth 0 too (agc_jit_call_plain): the result in the window and nothing charged, while an argument
   with another tag takes the INTERPRET exit at the call, its window left alone. */
static AGC_JIT_CALLER void plain_leaf_calls(void) {
  size_t plain = 0;
  for (size_t t = 0; t < agc_builtin_table_count; t++)
    for (size_t i = 0; i < *agc_builtin_tables[t].count; i++) {
      const agc_builtin *b = &agc_builtin_tables[t].entries[i];
      const agc_jit_plain *checks = agc_jit_plain_of(b);
      if (checks) plain++;
      assert(!checks || b->leaf);
      assert(!checks || !checks->one_char || checks->tags[0] == AGC_T_STRING);
    }
  assert(plain == 6);
  static const agc_builtin row = {"String.length", 1, counts, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false};
  static const agc_builtin not_leaf = {"String.length", 1, counts, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false};
  assert(agc_jit_plain_of(&row) && !agc_jit_plain_of(&not_leaf));
  agc_value got;
  expect_exit(plain_call(&row, agc_string_value(agc_make_string("abc", 3, 3)), &got), AGC_JIT_EXIT_RETURN, 1);
  assert(same_bits(got, agc_int(30)));
  expect_exit(plain_call(&row, agc_int(30), &got), AGC_JIT_EXIT_INTERPRET, 0);
  assert(same_bits(got, agc_int(30)));
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
  /* TRY gives an ok Result's value; an error (which returns from the frame) or a wrong tag leaves for the
     interpreter. */
  static const agc_opcode tries[] = {AGC_OP_TRY, AGC_OP_TRY_STEP};
  for (size_t k = 0; k < 2; k++) {
    agc_opcode op = tries[k];
    binary(op, agc_result_value(true, y), any, AGC_STATUS_OK, y);
    binary(op, agc_result_value(false, y), any, out, any);
    binary(op, x, any, out, any);
  }
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

/* GLOBAL reads its slot when it runs, and an unset one (tag Void) leaves for the interpreter, R3 untouched. STRUCT and
   ENUM build their values from the window at R1 in compiled code; a variant without a payload gives its shared value.
   An index past the program's tables (hand-made code) leaves for the interpreter. */
static AGC_JIT_CALLER void globals_structs_enums(void) {
  /* globals[1] is zeroed: tag Void, a slot never set. */
  agc_value globals[2] = {agc_int(1)}, any = agc_nil(), R[8];
  agc_struct_def structs[1] = {{.count = 2}};
  agc_variant_def variants[2] = {{.arity = 0, .shared = agc_new_enum(0, 0)}, {.arity = 2}};
  one_function f;
  memset(&f, 0, sizeof f);
  emit(&f, AGC_OP_GLOBAL, 3, 1, 0);
  emit(&f, AGC_OP_RETURN, 3, 0, 0);
  f.program.globals = globals;
  f.program.global_count = 2;
  agc_jit_code code = compile(&f);
  memset(R, 0, sizeof R);
  R[3] = any;
  expect_exit(code(&vm, R, f.constants, 0), AGC_JIT_EXIT_INTERPRET, 0);
  assert(same_bits(R[3], any));
  globals[1] = agc_int(9);
  expect_exit(code(&vm, R, f.constants, 0), AGC_JIT_EXIT_RETURN, 1);
  assert(same_bits(R[3], agc_int(9)));
  f.program.global_count = 1;
  expect_exit(compile(&f)(&vm, R, f.constants, 0), AGC_JIT_EXIT_INTERPRET, 0);
  agc_value x = agc_int(5), y = agc_float(1.5);
  static const agc_opcode makes[] = {AGC_OP_STRUCT, AGC_OP_ENUM};
  for (size_t k = 0; k < 2; k++) {
    agc_opcode op = makes[k];
    for (uint32_t c = 0; c < 2; c++) {
      memset(&f, 0, sizeof f);
      emit(&f, op, 3, 1, c);
      emit(&f, AGC_OP_RETURN, 3, 0, 0);
      f.program.structs = structs;
      f.program.struct_count = 1;
      f.program.variants = variants;
      f.program.variant_count = 2;
      code = compile(&f);
      memset(R, 0, sizeof R);
      R[1] = x;
      R[2] = y;
      R[3] = any;
      bool beyond = op == AGC_OP_STRUCT && c == 1;
      expect_exit(code(&vm, R, f.constants, 0), beyond ? AGC_JIT_EXIT_INTERPRET : AGC_JIT_EXIT_RETURN, beyond ? 0 : 1);
      if (beyond) {
        assert(same_bits(R[3], any));
      } else if (op == AGC_OP_STRUCT) {
        const agc_struct *st = agc_as_struct(&vm, R[3]);
        assert(st->type == 0 && st->n == 2 && same_bits(st->fields[0], x) && same_bits(st->fields[1], y));
      } else if (c == 0) {
        assert(agc_as_enum(&vm, R[3]) == variants[0].shared);
      } else {
        const agc_enum *e = agc_as_enum(&vm, R[3]);
        assert(e->variant == 1 && e->n == 2 && same_bits(e->payload[0], x) && same_bits(e->payload[1], y));
      }
    }
  }
}

/* STRUCT_WITH copies the struct at R1 with the update's field set from R2 in compiled code. The copy charges its size
   and applies it, as the interpreter's case does: 4 fields (64 bytes) take one unit of the turn, and a turn that the
   charge ends leaves with YIELD after the result is written. A receiver that is not a struct of the update's type with
   its declared field count, and an update past the program's table (hand-made code), leave for the interpreter, R3 and
   the turn cost untouched. */
static AGC_JIT_CALLER void struct_updates(void) {
  agc_struct_def structs[2] = {{.count = 4}, {.count = 2}};
  uint32_t fields[1] = {2};
  agc_update_def updates[1] = {{.type = 0, .count = 1, .fields = fields}};
  one_function f;
  memset(&f, 0, sizeof f);
  emit(&f, AGC_OP_STRUCT_WITH, 3, 1, 0);
  emit(&f, AGC_OP_RETURN, 3, 0, 0);
  f.program.structs = structs;
  f.program.struct_count = 2;
  f.program.updates = updates;
  f.program.update_count = 1;
  agc_jit_code code = compile(&f);
  const agc_program *saved = vm.rt->program;
  vm.rt->program = &f.program;
  agc_struct *old = agc_new_struct(0, 4);
  for (int64_t k = 0; k < 4; k++) old->fields[k] = agc_int(k);
  agc_value any = agc_nil(), R[8] = {agc_nil(), agc_struct_value(old), agc_int(9), any};
  vm.task->turn_cost = 0;
  vm.turn_left = vm.batch = vm.next_stop = vm.stop_set = 1000;
  for (int pass = 0; pass < 2; pass++) {
    expect_exit(code(&vm, R, f.constants, 0), pass ? AGC_JIT_EXIT_YIELD : AGC_JIT_EXIT_RETURN, pass ? 0 : 1);
    const agc_struct *st = agc_as_struct(&vm, R[3]);
    assert(st != old && st->type == 0 && st->n == 4 && same_bits(st->fields[1], agc_int(1)));
    assert(same_bits(st->fields[2], agc_int(9)) && same_bits(old->fields[2], agc_int(2)));
    assert(vm.task->turn_cost == 0 && vm.yield == (pass == 1));
    if (!pass) assert(vm.turn_left == 999);
    vm.turn_left = 1;
    R[3] = any;
  }
  vm.yield = false;
  agc_value wrong[3] = {agc_int(5), agc_struct_value(agc_new_struct(1, 2)), agc_struct_value(agc_new_struct(0, 2))};
  for (size_t k = 0; k < 3; k++) {
    R[1] = wrong[k];
    expect_exit(code(&vm, R, f.constants, 0), AGC_JIT_EXIT_INTERPRET, 0);
    assert(same_bits(R[3], any) && vm.task->turn_cost == 0);
  }
  f.program.update_count = 0;
  R[1] = agc_struct_value(old);
  expect_exit(compile(&f)(&vm, R, f.constants, 0), AGC_JIT_EXIT_INTERPRET, 0);
  assert(same_bits(R[3], any));
  vm.rt->program = saved;
  vm.next_stop = 1000;
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

/* The values that Test.record saw, in order. */
static agc_value recorded[4];
static size_t record_count;

static agc_value record(agc_vm *v, agc_value *args, uint32_t span) {
  (void)v;
  (void)span;
  if (record_count < sizeof recorded / sizeof recorded[0]) recorded[record_count++] = args[0];
  return args[0];
}

static void block_program_of(block_program *b) {
  static const agc_builtin record_row = {"Test.record", 1, record, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false};
  memset(b, 0, sizeof *b);
  b->builtins[0] = agc_find_builtin((const uint8_t *)"List.reduce", 11, 3);
  b->builtins[1] = agc_find_builtin((const uint8_t *)"List.map", 8, 2);
  b->builtins[2] = &record_row;
  assert(b->builtins[0] && b->builtins[1]);
  agc_test_program(&b->program, &b->source, b->span_table, 16, b->constants, b->builtins, 3, b->fns, 3,
                   &b->code[0][0], &b->spans[0][0], MAX_CODE, 0);
  agc_value items[BLOCK_ITEMS];
  for (int64_t k = 0; k < BLOCK_ITEMS; k++) items[k] = agc_int(k + 1);
  agc_fn *add = agc_new_fn(1, 0), *shift = agc_new_fn(2, 1);
  shift->captured[0] = agc_int(100);
  b->constants[0] = agc_list_value(agc_list_from_array(items, BLOCK_ITEMS));
  b->constants[1] = agc_int(0);
  b->constants[2] = agc_fn_value(add);
  b->constants[3] = agc_fn_value(shift);
  b->program.constant_count = 4;
  b->fns[1].params = 2;
  b->fns[2].captures = 1;
  agc_function *main_fn = &b->fns[0];
  agc_test_emit(main_fn, MAX_CODE, AGC_OP_STEP, 1, 0, 1);
  agc_test_emit(main_fn, MAX_CODE, AGC_OP_CONST, 1, 0, 1);
  agc_test_emit(main_fn, MAX_CODE, AGC_OP_CONST, 2, 1, 1);
  agc_test_emit(main_fn, MAX_CODE, AGC_OP_CONST, 3, 2, 1);
  agc_test_emit(main_fn, MAX_CODE, AGC_OP_CALL_BUILTIN, 1, 0, 2);
  agc_test_emit(main_fn, MAX_CODE, AGC_OP_CALL_BUILTIN, 1, 2, 3);
  agc_test_emit(main_fn, MAX_CODE, AGC_OP_CONST, 4, 0, 1);
  agc_test_emit(main_fn, MAX_CODE, AGC_OP_CONST, 5, 3, 1);
  agc_test_emit(main_fn, MAX_CODE, AGC_OP_CALL_BUILTIN, 4, 1, 4);
  agc_test_emit(main_fn, MAX_CODE, AGC_OP_CALL_BUILTIN, 4, 2, 5);
  agc_test_emit(main_fn, MAX_CODE, AGC_OP_RETURN, 4, 0, 1);
  for (uint32_t f = 1; f < 3; f++) {
    agc_test_emit(&b->fns[f], MAX_CODE, AGC_OP_STEP, 1, 0, 6);
    agc_test_emit(&b->fns[f], MAX_CODE, AGC_OP_ADD_I, 0, 0 | (1u << 16), 6); /* R0 = R0 + R1 */
    agc_test_emit(&b->fns[f], MAX_CODE, AGC_OP_RETURN, 0, 0, 6);
  }
}

/* One run of the block program with at most MAX_STEPS steps, with no JIT or with `always` (its trace on, so it counts
   the transitions and turns in COUNTS[0] and [1]): the outcome, and the steps left in *LEFT. */
static agc_outcome run_blocks(block_program *b, bool jit, int64_t max_steps, int64_t *left, uint64_t counts[2]) {
  static FILE *quiet;
  if (!quiet) quiet = tmpfile(); /* not /dev/null: Windows has none */
  assert(quiet);
  record_count = 0;
  agc_vm run;
  agc_vm_init(&run, &b->program, stdout, quiet, max_steps);
  agc_jit *j = NULL;
  if (jit) {
    static agc_trace counting = {.mask = AGC_TRACE_JIT, .fd = -1};
    j = agc_jit_new(&b->program, AGC_JIT_ALWAYS, &counting);
    assert(j);
    run.rt->jit = j;
  }
  agc_outcome outcome = agc_vm_run(&run);
  *left = atomic_load(&run.rt->steps_left);
  counts[0] = j ? atomic_load(&j->transitions) : 0;
  counts[1] = j ? atomic_load(&j->turns) : 0;
  return outcome;
}

/* A compiled block that returns to its block call while items are left starts over in place
   (agc_jit_block_return): the frame keeps its slot and gets the next arguments and its captures, the step and turn
   cost of each call are charged as the interpreter charges them, and the turns that end inside the call end where
   the interpreter's do. Only the last item of each call, and main's RETURN, take the RETURN exit. Step limits that
   stop inside the calls stop both tiers at the same step. */
static AGC_JIT_CALLER void block_calls_in_place(void) {
  static block_program b;
  block_program_of(&b);
  int64_t left_off, left_jit;
  uint64_t counts[2];
  agc_outcome off = run_blocks(&b, false, 1000000, &left_off, counts);
  assert(off.kind == AGC_DONE && record_count == 2);
  agc_value sum = recorded[0], list = recorded[1];
  assert(same_bits(sum, agc_int(BLOCK_ITEMS * (BLOCK_ITEMS + 1) / 2)));
  agc_outcome on = run_blocks(&b, true, 1000000, &left_jit, counts);
  assert(on.kind == AGC_DONE && record_count == 2 && left_jit == left_off);
  assert(same_bits(recorded[0], sum) && agc_equal(&vm, recorded[1], list, 0));
  const agc_list *shifted = agc_as_list(&vm, recorded[1]);
  assert(agc_list_len(shifted) == BLOCK_ITEMS && same_bits(agc_list_get(shifted, 0), agc_int(101)) &&
         same_bits(agc_list_get(shifted, BLOCK_ITEMS - 1), agc_int(BLOCK_ITEMS + 100)));
  /* Each call of a block takes a step and a turn cost: 2000 calls end turns of 2000 steps inside them. */
  assert(counts[0] == TRACE_COUNT(3) && (counts[1] >= 3 || !AGC_TRACE_BUILD));
  /* The calls take about 1000000 - left_off steps; the limits stop inside the reduce and the map. */
  int64_t used = 1000000 - left_off;
  for (int64_t limit = used / 7; limit < used; limit += used / 7) {
    agc_outcome a = run_blocks(&b, false, limit, &left_off, counts);
    agc_outcome c = run_blocks(&b, true, limit, &left_jit, counts);
    assert(a.kind == AGC_FAILED && c.kind == a.kind && strcmp(a.code, "RUNTIME-STEP-LIMIT") == 0);
    assert(strcmp(c.code, a.code) == 0 && c.span == a.span && left_jit == left_off);
  }
}

/* One run of the code_program of TEXT with no JIT or with `always` (its trace on, so it counts the leaves that
   run_compiled called in *LEAVES): the outcome. Test.record is no leaf here, so only String.code can be counted. */
static agc_outcome run_code(code_program *c, const char *text, bool jit, uint64_t *leaves) {
  static const agc_builtin record_row = {"Test.record", 1, record, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false};
  static FILE *quiet;
  if (!quiet) quiet = tmpfile(); /* not /dev/null: Windows has none */
  assert(quiet);
  memset(c, 0, sizeof *c);
  c->builtins[0] = agc_find_builtin((const uint8_t *)"String.code", 11, 1);
  c->builtins[1] = &record_row;
  assert(c->builtins[0]);
  agc_test_program(&c->program, &c->source, c->span_table, 8, c->constants, c->builtins, 2, c->fns, 1, &c->code[0][0],
                   &c->spans[0][0], MAX_CODE, 0);
  size_t bytes = strlen(text), chars = 0;
  for (size_t k = 0; k < bytes; k++) chars += ((uint8_t)text[k] & 0xC0) != 0x80;
  c->constants[0] = agc_string_value(agc_make_string(text, bytes, chars));
  c->program.constant_count = 1;
  agc_test_emit(&c->fns[0], MAX_CODE, AGC_OP_STEP, 1, 0, 1);
  agc_test_emit(&c->fns[0], MAX_CODE, AGC_OP_CONST, 1, 0, 2);
  agc_test_emit(&c->fns[0], MAX_CODE, AGC_OP_CALL_BUILTIN, 1, 0, 3);
  agc_test_emit(&c->fns[0], MAX_CODE, AGC_OP_CALL_BUILTIN, 1, 1, 4);
  agc_test_emit(&c->fns[0], MAX_CODE, AGC_OP_RETURN, 1, 0, 5);
  record_count = 0;
  agc_vm run;
  agc_vm_init(&run, &c->program, stdout, quiet, 1000);
  agc_jit *j = NULL;
  if (jit) {
    static agc_trace counting = {.mask = AGC_TRACE_JIT, .fd = -1};
    j = agc_jit_new(&c->program, AGC_JIT_ALWAYS, &counting);
    assert(j);
    run.rt->jit = j;
  }
  agc_outcome outcome = agc_vm_run(&run);
  *leaves = j ? atomic_load(&j->leaves) : 0;
  return outcome;
}

/* String.code is a plain leaf with a one-character check: on a one-character String (two bytes here) compiled code
   calls it at native depth 0 with no exit, and on an empty or longer String, or another tag, it takes the INTERPRET
   exit at the call, its window left alone. A whole run then fails in run_compiled's call of the leaf with the code and
   span that the interpreter fails with. */
static AGC_JIT_CALLER void string_code_calls(void) {
  const agc_builtin *row = agc_find_builtin((const uint8_t *)"String.code", 11, 1);
  assert(row && agc_jit_plain_of(row) && agc_jit_plain_of(row)->one_char);
  agc_value got;
  expect_exit(plain_call(row, agc_string_value(agc_make_string("\xC3\xA9", 2, 1)), &got), AGC_JIT_EXIT_RETURN, 1);
  assert(same_bits(got, agc_int(0xE9)));
  const agc_value others[] = {agc_string_value(agc_make_string("ab", 2, 2)),
                              agc_string_value(agc_make_string("", 0, 0)), agc_int(7)};
  for (size_t k = 0; k < sizeof others / sizeof others[0]; k++) {
    expect_exit(plain_call(row, others[k], &got), AGC_JIT_EXIT_INTERPRET, 0);
    assert(same_bits(got, others[k]));
  }
  static code_program c;
  static const char *const texts[] = {"\xC3\xA9", "ab", ""};
  for (size_t k = 0; k < sizeof texts / sizeof texts[0]; k++) {
    uint64_t leaves_off, leaves_on;
    agc_outcome off = run_code(&c, texts[k], false, &leaves_off);
    size_t recorded_off = record_count;
    agc_outcome on = run_code(&c, texts[k], true, &leaves_on);
    assert(on.kind == off.kind && record_count == recorded_off);
    if (k == 0) {
      assert(off.kind == AGC_DONE && record_count == 1 && same_bits(recorded[0], agc_int(0xE9)) && leaves_on == 0);
    } else {
      assert(off.kind == AGC_FAILED && strcmp(off.code, "RUNTIME-INVALID-CHARACTER") == 0 && off.span == 4);
      assert(strcmp(on.code, off.code) == 0 && on.span == off.span && leaves_on == TRACE_COUNT(1));
    }
  }
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

/* The first row of the builtin tables named NAME, or NULL. */
static const agc_builtin *table_row(const char *name) {
  for (size_t t = 0; t < agc_builtin_table_count; t++)
    for (size_t i = 0; i < *agc_builtin_tables[t].count; i++)
      if (strcmp(agc_builtin_tables[t].entries[i].name, name) == 0) return &agc_builtin_tables[t].entries[i];
  return NULL;
}

/* The names of agc_jit_parking are sorted for bsearch, and each one is a row of the builtin tables, so a renamed row
   fails here instead of dropping out of the list. */
static void parking_rows(void) {
  for (size_t k = 0; k < agc_jit_parking_count; k++) {
    const agc_builtin *b = table_row(agc_jit_parking[k]);
    if (!b) fprintf(stderr, "jit-test: agc_jit_parking names %s, which is no builtin row\n", agc_jit_parking[k]);
    assert(b && agc_jit_parks(b));
    assert(k == 0 || strcmp(agc_jit_parking[k - 1], agc_jit_parking[k]) < 0);
  }
}

/* While no code is published, sampled turns that count no entry widen the sample to one turn in AGC_JIT_SAMPLE_MAX.
   An entry counted after that sets it back to one in AGC_JIT_SAMPLE at the next sampled turn, the function still
   compiles, and then every turn runs the jit copy. One scheduler's draws are the same in each run. */
static void sample_resets(void) {
  static const agc_trace quiet = {0};
  one_function f;
  sum_loop(&f);
  program_of(&f);
  agc_jit *jit = agc_jit_new(&f.program, AGC_JIT_ON, &quiet);
  assert(jit);
  uint32_t frames = vm.task->frame_count;
  vm.task->frame_count = 0;
  for (uint32_t turn = 0; turn < 100000; turn++) (void)agc_jit_turn(jit, &vm);
  assert(1u << atomic_load(&jit->sample_bits) == AGC_JIT_SAMPLE_MAX);
  assert(!agc_jit_code_of(jit, 0, 0));
  uint32_t turns = 0;
  while (!agc_jit_turn(jit, &vm)) turns++;
  assert(1u << atomic_load(&jit->sample_bits) == AGC_JIT_SAMPLE && turns < 100000);
  agc_jit_code code = NULL;
  for (uint32_t entry = 1; entry < AGC_JIT_THRESHOLD && !code; entry++) code = agc_jit_code_of(jit, 0, 0);
  assert(code);
  for (uint32_t turn = 0; turn < 1000; turn++) assert(agc_jit_turn(jit, &vm));
  vm.task->frame_count = frames;
}

/* `on` keeps out a function without a loop, and one whose loop goes back to the interpreter (a builtin that is neither
   a leaf nor direct nor a block call) more than once in AGC_JIT_SPACING instructions, one that may park counting
   AGC_JIT_PARK_WEIGHT times; a leaf or direct builtin does not count, as compiled code calls it, nor a block call,
   which run_compiled starts. A function without a loop that
   calls a leaf builtin may still get code for native calls; one that starts a block call may not. A program where no
   function is compiled has no JIT at all. */
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
  /* A builtin that may park (Channel.recv) counts AGC_JIT_PARK_WEIGHT trips out: a loop that calls it once stays out
     below AGC_JIT_PARK_WEIGHT * AGC_JIT_SPACING instructions. A `shared` row that never parks (Channel.closed?)
     counts one, as any other call that leaves. */
  const agc_builtin *shared_rows[2] = {table_row("Channel.recv"), table_row("Channel.closed?")};
  assert(shared_rows[0] && shared_rows[1] && shared_rows[1]->shared && !agc_jit_parks(shared_rows[1]));
  enum { PARKS = AGC_JIT_PARK_WEIGHT * AGC_JIT_SPACING };
  agc_instr parking[PARKS];
  for (uint32_t which = 0; which < 2; which++) {
    uint32_t qualifies = which == 0 ? PARKS : AGC_JIT_SPACING;
    for (uint32_t size = qualifies - 1; size <= qualifies; size++) {
      parking[0] = (agc_instr){AGC_OP_STEP, 1, 0, 0};
      parking[1] = (agc_instr){AGC_OP_CALL_BUILTIN, 0, (uint16_t)which, 0};
      for (uint32_t pc = 2; pc + 1 < size; pc++) parking[pc] = (agc_instr){AGC_OP_MOVE, 1, 2, 0};
      parking[size - 1] = (agc_instr){AGC_OP_JUMP, 0, 0, 0};
      agc_function parks[1] = {{.registers = 3, .code = parking, .count = size}};
      agc_program parks_program = {.functions = parks, .function_count = 1, .builtins = shared_rows};
      bool parks_callable[1], parks_looped[1], parks_calling[1];
      agc_jit_settle(&parks_program, parks_callable, parks_looped, parks_calling);
      assert(parks_looped[0] && parks_callable[0] == (size == qualifies));
    }
  }
  /* A TAIL_CALL counts as a call, by its callee: a loop that tail-calls a function that may get code does not leave,
     and one whose callee leaves (a builtin that is neither leaf, direct nor a block call) does. */
  agc_builtin other_row = {.leaf = false};
  const agc_builtin *other_rows[1] = {&other_row};
  agc_instr loop[3] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_TAIL_CALL, 0, 1, 0}, {AGC_OP_JUMP, 0, 0, 0}};
  agc_instr callee[2] = {{AGC_OP_CALL_BUILTIN, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  for (uint32_t leaving = 0; leaving < 2; leaving++) {
    agc_function fns[2] = {{.registers = 2, .code = loop, .count = 3},
                           {.registers = 2, .code = callee + !leaving, .count = 1 + leaving}};
    agc_program program = {.functions = fns, .function_count = 2, .builtins = other_rows};
    bool callable[2], looped[2], calling[2];
    agc_jit_settle(&program, callable, looped, calling);
    assert(looped[0] && !looped[1] && calling[0] && !calling[1]);
    assert(callable[0] == !leaving && callable[1] == !leaving);
  }
  /* A function without a loop that calls a leaf builtin may get code for native calls, as compiled code calls the
     builtin itself; one that starts a block call may not, and the loop that calls it then leaves at the call. */
  agc_builtin leaf_row = {.leaf = true}, block_row = {.native = AGC_NATIVE_FILTER};
  const agc_builtin *callee_rows[2] = {&leaf_row, &block_row};
  agc_instr calls_loop[3] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CALL, 0, 1, 0}, {AGC_OP_JUMP, 0, 0, 0}};
  for (uint16_t which = 0; which < 2; which++) {
    agc_instr body[2] = {{AGC_OP_CALL_BUILTIN, 0, which, 0}, {AGC_OP_RETURN, 0, 0, 0}};
    agc_function fns[2] = {{.registers = 2, .code = calls_loop, .count = 3},
                           {.registers = 2, .code = body, .count = 2}};
    agc_program program = {.functions = fns, .function_count = 2, .builtins = callee_rows};
    bool callable[2], looped[2], calling[2];
    agc_jit_settle(&program, callable, looped, calling);
    assert(callable[0] == (which == 0) && callable[1] == (which == 0));
  }
  /* A builtin row's answer is kept per row, apart for a loop and a function without one: a block call leaves from the
     function, not from the loop, whichever of the two settle reads first. The loop's one trip out is its call of the
     function, which drops; a second one would keep the loop out too. */
  enum { BLOCK_LOOP = AGC_JIT_SPACING };
  agc_instr block_body[2] = {{AGC_OP_CALL_BUILTIN, 0, 1, 0}, {AGC_OP_RETURN, 0, 0, 0}}, block_loop[BLOCK_LOOP];
  for (uint16_t loop_first = 0; loop_first < 2; loop_first++) {
    uint16_t body = loop_first, loop_at = !loop_first;
    block_loop[0] = (agc_instr){AGC_OP_STEP, 1, 0, 0};
    block_loop[1] = (agc_instr){AGC_OP_CALL_BUILTIN, 0, 1, 0};
    block_loop[2] = (agc_instr){AGC_OP_CALL, 0, body, 0};
    for (uint32_t pc = 3; pc + 1 < BLOCK_LOOP; pc++) block_loop[pc] = (agc_instr){AGC_OP_MOVE, 1, 2, 0};
    block_loop[BLOCK_LOOP - 1] = (agc_instr){AGC_OP_JUMP, 0, 0, 0};
    agc_function fns[2];
    fns[body] = (agc_function){.registers = 3, .code = block_body, .count = 2};
    fns[loop_at] = (agc_function){.registers = 3, .code = block_loop, .count = BLOCK_LOOP};
    agc_program program = {.functions = fns, .function_count = 2, .builtins = callee_rows};
    bool callable[2], looped[2], calling[2];
    agc_jit_settle(&program, callable, looped, calling);
    assert(!callable[body] && callable[loop_at] && looped[loop_at] && !looped[body]);
  }
  /* A function whose only loop is a TAIL_CALL of itself has a loop, so `on` compiles it at its entries; a TAIL_CALL of
     another function is no loop. */
  agc_instr self_tail[3] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_TAIL_CALL, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  agc_instr other_tail[3] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_TAIL_CALL, 0, 0, 0}, {AGC_OP_RETURN, 0, 0, 0}};
  agc_function tails[2] = {{.registers = 2, .code = self_tail, .count = 3},
                           {.registers = 2, .code = other_tail, .count = 3}};
  agc_program tail_program = {.functions = tails, .function_count = 2};
  bool tail_callable[2], tail_looped[2], tail_calling[2];
  agc_jit_settle(&tail_program, tail_callable, tail_looped, tail_calling);
  assert(tail_looped[0] && !tail_looped[1] && tail_callable[0] && tail_callable[1]);
  tail_program.function_count = 1;
  assert(agc_jit_new(&tail_program, AGC_JIT_ON, &quiet));
  /* A CALL_VALUE does not leave and counts as calling: its callee, known only when it runs, is called natively once it
     has code. */
  agc_instr values[3] = {{AGC_OP_STEP, 1, 0, 0}, {AGC_OP_CALL_VALUE, 0, 0, 0}, {AGC_OP_JUMP, 0, 0, 0}};
  agc_function looping[1] = {{.registers = 2, .code = values, .count = 3}};
  agc_program program = {.functions = looping, .function_count = 1};
  bool callable[1], looped[1], calling[1];
  agc_jit_settle(&program, callable, looped, calling);
  assert(callable[0] && looped[0] && calling[0]);
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
   the third does not fit, which spends the budget: it and the fourth, never walked, stay interpreted. */
static void small_cap(void) {
  four_functions p;
  agc_jit *jit = four_new(&p);
  size_t page = agc_jit_mem_page();
  jit->cap = 2 * page;
  agc_jit_code first = agc_jit_code_of(jit, 0, 0), second = agc_jit_code_of(jit, 1, 0);
  assert(first && second && jit->cap == 2 * page && atomic_load(&jit->used) == 2 * page);
  four_run(&p, second, 1);
  assert(!agc_jit_code_of(jit, 2, 0) && !agc_jit_may_run(jit, 2) && atomic_load(&jit->used) == 2 * page);
  uint64_t work = atomic_load(&jit->work);
  assert(atomic_load(&jit->spent) && atomic_load(&jit->claimed[3]) && !agc_jit_may_run(jit, 3));
  assert(!agc_jit_code_of(jit, 3, 0) && atomic_load(&jit->work) == work);
}

/* The work budget: each compile takes its instructions plus AGC_JIT_COMPILE_BASE before the walk. Two functions fit
   it exactly; the third does not, so it and the fourth stay interpreted without a walk or a byte of code memory, and
   the code made before still runs. */
static AGC_JIT_CALLER void work_budget(void) {
  four_functions p;
  agc_jit *jit = four_new(&p);
  assert(jit->budget == AGC_JIT_BUDGET && atomic_load(&jit->work) == 0 && !atomic_load(&jit->spent));
  uint64_t one = p.fns[0].count + AGC_JIT_COMPILE_BASE;
  jit->budget = 2 * one;
  agc_jit_code first = agc_jit_code_of(jit, 0, 0), second = agc_jit_code_of(jit, 1, 0);
  assert(first && second && atomic_load(&jit->work) == 2 * one && !atomic_load(&jit->spent));
  size_t used = atomic_load(&jit->used);
  assert(!agc_jit_code_of(jit, 2, 0) && !agc_jit_may_run(jit, 2) && atomic_load(&jit->spent));
  assert(atomic_load(&jit->claimed[3]) && !agc_jit_may_run(jit, 3) && !agc_jit_code_of(jit, 3, 0));
  assert(atomic_load(&jit->work) == 2 * one && atomic_load(&jit->used) == used);
  assert(agc_jit_code_of(jit, 0, 0) == first && agc_jit_may_run(jit, 1));
  four_run(&p, first, 0);
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
#if CODE_MEMORY_TEST
  code_memory();
#endif
#if AGC_JIT_HOST
  arena();
  small_cap();
  work_budget();
  batch();
  settle_is_linear();
  compile_race();
  if (X64) cap_inside_an_offset();
  if (X64) bytes();
  call_return_exits();
  if (NATIVE_CALLS) native_calls();
  if (NATIVE_CALLS) native_leaf_calls();
  plain_leaf_calls();
  string_code_calls();
  if (NATIVE_CALLS) native_tail_calls();
  if (NATIVE_CALLS) wide_tail_calls();
  if (NATIVE_CALLS) call_values();
  direct_calls();
  loops_and_steps();
  int_rules();
  helpers();
  reads();
  string_cost();
  string_build_cost();
  maps_and_lists();
  closures();
  globals_structs_enums();
  struct_updates();
  parking_rows();
  ineligible();
  sample_resets();
  block_calls_in_place();
  every_opcode_compiles();
#else
  /* No emitter on this host: the JIT is never made. */
  agc_program empty = {0};
  assert(!agc_jit_new(&empty, AGC_JIT_ALWAYS, &vm.rt->trace));
#endif
  return 0;
}
