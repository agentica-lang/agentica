/*
 * Runs with several scheduler threads (docs/vm/16-architecture.md §16.9): agc_vm_run with rt->schedulers > 1 starts the
 * schedulers and makes the calling thread the I/O thread. A storm of tasks that yield and meet on a channel; a stall
 * that the I/O thread finds (no program can reach one, since every wait of the language has a deadline); and a
 * failure of main while other tasks spin, which ends the run once. `make vm-tsan` runs it under ThreadSanitizer.
 */
#include "../core.h"
#include "test_program.h"
#include "test_support.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#if defined(__linux__) || defined(__APPLE__)

#define MAX_CODE 48
#define WORKERS 400
#define SCRATCH 20

enum { B_SPAWN, B_SLEEP, B_CH_NEW, B_CH_SEND, B_CH_RECV, B_ADD, B_FOREVER, B_DIE, B_COUNT };
enum { F_MAIN, F_WORK, F_PARK, F_SPIN, F_COUNT };

typedef struct {
  agc_function fns[F_COUNT];
  agc_instr code[F_COUNT][MAX_CODE];
  uint32_t spans[F_COUNT][MAX_CODE];
  agc_span span_table[8];
  agc_test_source source;
  agc_value constants[16];
  const agc_builtin *builtins[B_COUNT];
  agc_program program;
} prog;

/* The library builtins the programs call, in the order of the B_ names. */
static const struct {
  const char *name;
  uint32_t arity;
} library[] = {{"Task.spawn", 2}, {"Task.sleep", 1}, {"Channel.new", 1}, {"Channel.send", 3}, {"Channel.recv", 2}};

static _Atomic int64_t total;
static FILE *quiet;

static agc_value test_add(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  atomic_fetch_add(&total, agc_as_int(vm, args[0]));
  return agc_void();
}

static agc_value never_done(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)data;
  (void)context;
  return agc_void();
}

/* A job with no handle, no deadline and no callback that readies it: nothing can wake its task. */
static const agc_io_kind never_io = {NULL, never_done, never_done, NULL, true, "never", NULL, false, NULL};

static agc_value test_forever(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  agc_io_start(vm, &never_io, NULL, agc_void(), -1);
  agc_task_park(vm, false);
  return agc_void();
}

static agc_value test_die(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  agc_fail(vm, "RUNTIME-TEST", "main fails", span);
}

static const agc_builtin test_builtins[] = {
  {"Test.add", 1, test_add, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Test.forever", 1, test_forever, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Test.die", 1, test_die, AGC_NATIVE_NONE, AGC_COST_NONE, true},
};

/* The index of the next instruction of F, the target of a jump. */
static uint32_t here(const prog *p, uint32_t f) { return p->fns[f].count; }

static uint32_t constant(prog *p, int64_t v) { return agc_test_constant(&p->program, p->constants, v); }

static void emit(prog *p, uint32_t f, agc_opcode op, uint32_t a, uint32_t bx) {
  agc_test_emit(&p->fns[f], MAX_CODE, op, a, bx, 1);
}

/* An instruction with three register operands (a = b op c). */
static void emit3(prog *p, uint32_t f, agc_opcode op, uint32_t a, uint32_t b, uint32_t c) {
  emit(p, f, op, a, b | c << 16);
}

/* Calls BUILTIN with the one integer argument V. */
static void call_int(prog *p, uint32_t f, uint32_t builtin, int64_t v) {
  uint32_t k = constant(p, v);
  emit(p, f, AGC_OP_CONST, SCRATCH, k);
  emit(p, f, AGC_OP_CALL_BUILTIN, SCRATCH, builtin);
}

static void new_prog(prog *p) {
  memset(p, 0, sizeof *p);
  for (size_t k = 0; k < sizeof library / sizeof library[0]; k++) {
    p->builtins[k] = agc_find_builtin((const uint8_t *)library[k].name, strlen(library[k].name), library[k].arity);
    assert(p->builtins[k]);
  }
  for (size_t k = 0; k < sizeof test_builtins / sizeof test_builtins[0]; k++) p->builtins[B_ADD + k] = &test_builtins[k];
  agc_test_program(&p->program, &p->source, p->span_table, 8, p->constants, p->builtins, B_COUNT, p->fns, F_COUNT,
                   &p->code[0][0], &p->spans[0][0], MAX_CODE, F_MAIN);
  p->fns[F_WORK].captures = 1;
  p->program.max_arity = 2;

  /* work(k), with the channel captured in r1: add k, yield twice, send k. */
  emit(p, F_WORK, AGC_OP_MOVE, SCRATCH, 0);
  emit(p, F_WORK, AGC_OP_CALL_BUILTIN, SCRATCH, B_ADD);
  call_int(p, F_WORK, B_SLEEP, 0);
  call_int(p, F_WORK, B_SLEEP, 0);
  emit(p, F_WORK, AGC_OP_MOVE, SCRATCH, 1);
  emit(p, F_WORK, AGC_OP_MOVE, SCRATCH + 1, 0);
  emit(p, F_WORK, AGC_OP_CONST, SCRATCH + 2, constant(p, 30000));
  emit(p, F_WORK, AGC_OP_CALL_BUILTIN, SCRATCH, B_CH_SEND);
  emit(p, F_WORK, AGC_OP_RETURN, 0, 0);

  /* park(_): waits for ever. */
  call_int(p, F_PARK, B_FOREVER, 0);
  emit(p, F_PARK, AGC_OP_RETURN, 0, 0);

  /* spin(_): yields for ever, until the end of the run cancels it. */
  call_int(p, F_SPIN, B_SLEEP, 0);
  emit(p, F_SPIN, AGC_OP_JUMP, 0, 0);
}

/* main: the storm. Spawns WORKERS tasks on one channel and receives WORKERS values. */
static void storm_main(prog *p) {
  emit(p, F_MAIN, AGC_OP_CONST, 10, constant(p, WORKERS));
  emit(p, F_MAIN, AGC_OP_CALL_BUILTIN, 10, B_CH_NEW);
  emit(p, F_MAIN, AGC_OP_MOVE, 1, 10);
  emit(p, F_MAIN, AGC_OP_CONST, 2, constant(p, 0));
  emit(p, F_MAIN, AGC_OP_CONST, 3, constant(p, WORKERS));
  emit(p, F_MAIN, AGC_OP_CONST, 4, constant(p, 1));
  uint32_t spawn_loop = here(p, F_MAIN);
  emit3(p, F_MAIN, AGC_OP_LT_I, 5, 2, 3);
  uint32_t spawn_exit = here(p, F_MAIN);
  emit(p, F_MAIN, AGC_OP_JUMP_IF_FALSE, 5, 0);
  emit(p, F_MAIN, AGC_OP_MOVE, 10, 1);
  emit(p, F_MAIN, AGC_OP_CLOSURE, 10, F_WORK);
  emit(p, F_MAIN, AGC_OP_MOVE, 11, 2);
  emit(p, F_MAIN, AGC_OP_CALL_BUILTIN, 10, B_SPAWN);
  emit3(p, F_MAIN, AGC_OP_ADD_I, 2, 2, 4);
  emit(p, F_MAIN, AGC_OP_JUMP, 0, spawn_loop);
  p->code[F_MAIN][spawn_exit].b = (uint16_t)here(p, F_MAIN);
  emit(p, F_MAIN, AGC_OP_CONST, 2, constant(p, 0));
  uint32_t recv_loop = here(p, F_MAIN);
  emit3(p, F_MAIN, AGC_OP_LT_I, 5, 2, 3);
  uint32_t recv_exit = here(p, F_MAIN);
  emit(p, F_MAIN, AGC_OP_JUMP_IF_FALSE, 5, 0);
  emit(p, F_MAIN, AGC_OP_MOVE, 10, 1);
  emit(p, F_MAIN, AGC_OP_CONST, 11, constant(p, 30000));
  emit(p, F_MAIN, AGC_OP_CALL_BUILTIN, 10, B_CH_RECV);
  emit3(p, F_MAIN, AGC_OP_ADD_I, 2, 2, 4);
  emit(p, F_MAIN, AGC_OP_JUMP, 0, recv_loop);
  p->code[F_MAIN][recv_exit].b = (uint16_t)here(p, F_MAIN);
  emit(p, F_MAIN, AGC_OP_RETURN, 0, 0);
}

/* main: spawns three tasks with FN, then sleeps and calls the builtin LAST. */
static void spawning_main(prog *p, uint32_t fn, uint32_t last) {
  for (int k = 0; k < 3; k++) {
    emit(p, F_MAIN, AGC_OP_CLOSURE, 10, fn);
    emit(p, F_MAIN, AGC_OP_CONST, 11, constant(p, k));
    emit(p, F_MAIN, AGC_OP_CALL_BUILTIN, 10, B_SPAWN);
  }
  call_int(p, F_MAIN, B_SLEEP, 5);
  call_int(p, F_MAIN, last, 0);
  emit(p, F_MAIN, AGC_OP_RETURN, 0, 0);
}

static agc_outcome run(prog *p, int64_t schedulers) {
  static agc_vm vm;
  agc_vm_init(&vm, &p->program, stdout, quiet, INT64_MAX);
  vm.rt->schedulers = schedulers;
  agc_outcome out = agc_vm_run(&vm);
  agc_io_goodbye(&vm);
  return out;
}

static bool failed_with(const agc_outcome *o, const char *code) {
  return o->kind == AGC_FAILED && o->code && strcmp(o->code, code) == 0;
}

/* Every worker runs once, whichever scheduler takes it, and main sees every send. */
static void test_storm(int64_t schedulers) {
  prog *p = agc_alloc(sizeof *p);
  new_prog(p);
  storm_main(p);
  for (int round = 0; round < 5; round++) {
    atomic_store(&total, 0);
    agc_outcome out = run(p, schedulers);
    assert(out.kind == AGC_DONE);
    assert(atomic_load(&total) == (int64_t)WORKERS * (WORKERS - 1) / 2);
  }
}

/* Every task waits on a job that nothing can end: the I/O thread sees each scheduler idle with no request, no ready
   job, no timer and no live handle, and ends the run as one scheduler does. */
static void test_stall(int64_t schedulers) {
  prog *p = agc_alloc(sizeof *p);
  new_prog(p);
  spawning_main(p, F_PARK, B_FOREVER);
  agc_outcome out = run(p, schedulers);
  assert(failed_with(&out, "RUNTIME-INTERNAL"));
}

/* Main fails on whatever scheduler runs it while three tasks keep yielding: its failure is the outcome, and the run
   ends with every scheduler joined. */
static void test_main_fails_beside_spinners(int64_t schedulers) {
  prog *p = agc_alloc(sizeof *p);
  new_prog(p);
  spawning_main(p, F_SPIN, B_DIE);
  for (int round = 0; round < 5; round++) {
    agc_outcome out = run(p, schedulers);
    assert(failed_with(&out, "RUNTIME-TEST"));
  }
}
#endif

int main(void) {
#if defined(__linux__) || defined(__APPLE__)
  agc_test_deadline(300);
  agc_init();
  agc_io_init();
  agc_gc_allow_threads();
  quiet = fopen("/dev/null", "w");
  assert(quiet);
  test_storm(1);
  test_storm(4);
  test_stall(1);
  test_stall(4);
  test_main_fails_beside_spinners(4);
  fclose(quiet);
#endif
  puts("threads tests passed");
  return 0;
}
