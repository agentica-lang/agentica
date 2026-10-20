/*
 * Runs with several scheduler threads (§16.9; agc_vm_run with rt->schedulers > 1): a storm of tasks on a channel, a
 * stall that the I/O thread finds (also beside a service task's timer), main failing beside spinners (the run ends
 * once), and TCP calls issued and resumed on several schedulers while the I/O thread owns every socket. `make
 * vm-tsan` runs it under ThreadSanitizer.
 */
#include "../core.h"
#include "test_program.h"
#include "test_support.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#if defined(__linux__) || defined(__APPLE__)

#define MAX_CODE 96
#define WORKERS 400
#define SCRATCH 20
#define NET_TASKS 8

enum {
  B_SPAWN,
  B_SLEEP,
  B_CH_NEW,
  B_CH_SEND,
  B_CH_RECV,
  B_UNWRAP,
  B_AWAIT,
  B_LISTEN,
  B_PORT,
  B_CONNECT,
  B_ACCEPT,
  B_SEND,
  B_READ,
  B_CLOSE,
  B_CLOSE_LISTENER,
  B_ADD,
  B_FOREVER,
  B_DIE,
  B_WHERE,
  B_NET_WHERE,
  B_SERVICE,
  B_NO_PENDING,
  B_COUNT
};
enum { F_MAIN, F_WORK, F_PARK, F_SPIN, F_SEEN, F_NET, F_NAP, F_COUNT };

typedef struct {
  agc_function fns[F_COUNT];
  agc_instr code[F_COUNT][MAX_CODE];
  uint32_t spans[F_COUNT][MAX_CODE];
  agc_span span_table[8];
  agc_test_source source;
  agc_value constants[64];
  const agc_builtin *builtins[B_COUNT];
  agc_program program;
} prog;

/* The library builtins the programs call, in the order of the B_ names. */
static const struct {
  const char *name;
  uint32_t arity;
} library[] = {{"Task.spawn", 2},  {"Task.sleep", 1},     {"Channel.new", 1},       {"Channel.send", 3},
               {"Channel.recv", 2}, {"Result.unwrap!", 1}, {"Task.await", 1},        {"TCP.listen", 2},
               {"TCP.local_port", 1}, {"TCP.connect", 3},  {"TCP.accept", 2},        {"TCP.send", 3},
               {"TCP.read_line", 2}, {"TCP.close", 1},     {"TCP.close_listener", 1}};

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

/* One bit per scheduler that ran a call of Test.where. */
static _Atomic uint64_t schedulers_seen;

static int bits(uint64_t mask) {
  int n = 0;
  for (; mask; mask &= mask - 1) n++;
  return n;
}

/* Records the scheduler that runs the calling task; true once two different ones have. */
static agc_value test_where(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  uint64_t seen = atomic_fetch_or(&schedulers_seen, UINT64_C(1) << (vm->index % 64)) | UINT64_C(1) << (vm->index % 64);
  return agc_bool(bits(seen) >= 2);
}

/* One bit per scheduler that resumed a task after a TCP read. */
static _Atomic uint64_t net_seen;

/* Records the scheduler that runs the calling task right after a TCP read ended; true once two different ones have. */
static agc_value test_net_where(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  uint64_t bit = UINT64_C(1) << (vm->index % 64);
  return agc_bool(bits(atomic_fetch_or(&net_seen, bit) | bit) >= 2);
}

/* Test.service(f): runs f(channel) under a service root, as HttpWire.service runs a client's owner task. */
static agc_value test_service(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_value capacity = agc_int(1);
  agc_value channel = agc_find_builtin((const uint8_t *)"Channel.new", 11, 1)->fn(vm, &capacity, span);
  (void)agc_task_service(vm, args[0], channel, span);
  return agc_void();
}

/* Test.no_pending(_): Task.pending_count does not count service tasks. */
static agc_value test_no_pending(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  const agc_builtin *count = agc_find_builtin((const uint8_t *)"Task.pending_count", 18, 0);
  assert(agc_as_int(vm, count->fn(vm, NULL, span)) == 0);
  return agc_void();
}

static const agc_builtin test_builtins[] = {
  {"Test.add", 1, test_add, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Test.forever", 1, test_forever, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Test.die", 1, test_die, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Test.where", 1, test_where, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Test.net_where", 1, test_net_where, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Test.service", 1, test_service, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Test.no_pending", 1, test_no_pending, AGC_NATIVE_NONE, AGC_COST_NONE, true},
};

/* The index of the next instruction of F, the target of a jump. */
static uint32_t here(const prog *p, uint32_t f) { return p->fns[f].count; }

static uint32_t constant(prog *p, int64_t v) {
  assert(p->program.constant_count < sizeof p->constants / sizeof p->constants[0]);
  return agc_test_constant(&p->program, p->constants, v);
}

static uint32_t text_constant(prog *p, const char *text) {
  assert(p->program.constant_count < sizeof p->constants / sizeof p->constants[0]);
  uint32_t k = p->program.constant_count++;
  p->constants[k] = agc_string_value(agc_make_string(text, strlen(text), strlen(text)));
  return k;
}

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

/* Calls Test.where and yields until it says that two schedulers have run it. */
static void seen_loop(prog *p, uint32_t f) {
  uint32_t top = here(p, f);
  call_int(p, f, B_WHERE, 0);
  uint32_t exit_jump = here(p, f);
  emit(p, f, AGC_OP_JUMP_IF_TRUE, SCRATCH, 0);
  call_int(p, f, B_SLEEP, 0);
  emit(p, f, AGC_OP_JUMP, 0, top);
  p->code[f][exit_jump].b = (uint16_t)here(p, f);
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

  /* seen(_): records its scheduler and yields until two schedulers have run such calls. */
  seen_loop(p, F_SEEN);
  emit(p, F_SEEN, AGC_OP_RETURN, 0, 0);

  /* nap(_): sleeps far longer than the test's deadline. */
  call_int(p, F_NAP, B_SLEEP, 100000000);
  emit(p, F_NAP, AGC_OP_RETURN, 0, 0);

  /* spin(_): yields for ever, until the end of the run cancels it. */
  call_int(p, F_SPIN, B_SLEEP, 0);
  emit(p, F_SPIN, AGC_OP_JUMP, 0, 0);

  /* net(listener): a round connects to the listener, accepts one connection (any task's), sends a line on its own
     socket, reads a line from the accepted one and closes both; rounds go on until Test.net_where has seen two
     schedulers resume a task after a read. A task connects before it accepts, so there are never more accepts than
     connections and no round waits for ever; the bytes come from whichever task's connection was taken. */
  uint32_t top = here(p, F_NET);
  emit(p, F_NET, AGC_OP_MOVE, SCRATCH, 0);
  emit(p, F_NET, AGC_OP_CALL_BUILTIN, SCRATCH, B_PORT);
  emit(p, F_NET, AGC_OP_MOVE, SCRATCH + 3, SCRATCH);
  emit(p, F_NET, AGC_OP_CONST, SCRATCH + 2, text_constant(p, "127.0.0.1"));
  emit(p, F_NET, AGC_OP_CONST, SCRATCH + 4, constant(p, 10000));
  emit(p, F_NET, AGC_OP_CALL_BUILTIN, SCRATCH + 2, B_CONNECT);
  emit(p, F_NET, AGC_OP_CALL_BUILTIN, SCRATCH + 2, B_UNWRAP);
  emit(p, F_NET, AGC_OP_MOVE, 2, SCRATCH + 2);
  emit(p, F_NET, AGC_OP_MOVE, SCRATCH, 0);
  emit(p, F_NET, AGC_OP_CONST, SCRATCH + 1, constant(p, 10000));
  emit(p, F_NET, AGC_OP_CALL_BUILTIN, SCRATCH, B_ACCEPT);
  emit(p, F_NET, AGC_OP_CALL_BUILTIN, SCRATCH, B_UNWRAP);
  emit(p, F_NET, AGC_OP_MOVE, 3, SCRATCH);
  emit(p, F_NET, AGC_OP_MOVE, SCRATCH, 2);
  emit(p, F_NET, AGC_OP_CONST, SCRATCH + 1, text_constant(p, "x\n"));
  emit(p, F_NET, AGC_OP_CONST, SCRATCH + 2, constant(p, 10000));
  emit(p, F_NET, AGC_OP_CALL_BUILTIN, SCRATCH, B_SEND);
  emit(p, F_NET, AGC_OP_CALL_BUILTIN, SCRATCH, B_UNWRAP);
  emit(p, F_NET, AGC_OP_MOVE, SCRATCH, 3);
  emit(p, F_NET, AGC_OP_CONST, SCRATCH + 1, constant(p, 10000));
  emit(p, F_NET, AGC_OP_CALL_BUILTIN, SCRATCH, B_READ);
  emit(p, F_NET, AGC_OP_CALL_BUILTIN, SCRATCH, B_UNWRAP);
  call_int(p, F_NET, B_NET_WHERE, 0);
  emit(p, F_NET, AGC_OP_MOVE, 4, SCRATCH);
  call_int(p, F_NET, B_ADD, 1);
  emit(p, F_NET, AGC_OP_MOVE, SCRATCH, 2);
  emit(p, F_NET, AGC_OP_CALL_BUILTIN, SCRATCH, B_CLOSE);
  emit(p, F_NET, AGC_OP_MOVE, SCRATCH, 3);
  emit(p, F_NET, AGC_OP_CALL_BUILTIN, SCRATCH, B_CLOSE);
  uint32_t done = here(p, F_NET);
  emit(p, F_NET, AGC_OP_JUMP_IF_TRUE, 4, 0);
  emit(p, F_NET, AGC_OP_JUMP, 0, top);
  p->code[F_NET][done].b = (uint16_t)here(p, F_NET);
  emit(p, F_NET, AGC_OP_RETURN, 0, 0);
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

/* The tasks of a run with four schedulers run on more than one of them: four tasks and main record where they run
   and yield until two schedulers have been seen. With one thread the run would never end, and the deadline of the
   test fails it; nothing here depends on how long a step takes. */
static void test_tasks_spread_over_schedulers(void) {
  prog *p = agc_alloc(sizeof *p);
  new_prog(p);
  for (int k = 0; k < 4; k++) {
    emit(p, F_MAIN, AGC_OP_CLOSURE, 10, F_SEEN);
    emit(p, F_MAIN, AGC_OP_CONST, 11, constant(p, k));
    emit(p, F_MAIN, AGC_OP_CALL_BUILTIN, 10, B_SPAWN);
  }
  seen_loop(p, F_MAIN);
  emit(p, F_MAIN, AGC_OP_RETURN, 0, 0);
  atomic_store(&schedulers_seen, 0);
  agc_outcome out = run(p, 4);
  assert(out.kind == AGC_DONE);
  assert(bits(atomic_load(&schedulers_seen)) >= 2);
}

/* TCP on four schedulers: main listens and spawns NET_TASKS net tasks, then awaits them and closes the listener. Every
   step of a socket is a request to the I/O thread; the tasks issue them and are resumed on whichever scheduler runs
   them, and the run ends once two schedulers have resumed a task after a read. Each round unwraps every result, so a
   failed step fails the run. Before 3c-2a such a run refused the TCP rows (agc_program_for_threads). */
static void test_tcp_over_schedulers(void) {
  prog *p = agc_alloc(sizeof *p);
  new_prog(p);
  emit(p, F_MAIN, AGC_OP_CONST, 10, text_constant(p, "127.0.0.1"));
  emit(p, F_MAIN, AGC_OP_CONST, 11, constant(p, 0));
  emit(p, F_MAIN, AGC_OP_CALL_BUILTIN, 10, B_LISTEN);
  emit(p, F_MAIN, AGC_OP_CALL_BUILTIN, 10, B_UNWRAP);
  emit(p, F_MAIN, AGC_OP_MOVE, 1, 10);
  for (uint32_t k = 0; k < NET_TASKS; k++) {
    emit(p, F_MAIN, AGC_OP_CLOSURE, 10, F_NET);
    emit(p, F_MAIN, AGC_OP_MOVE, 11, 1);
    emit(p, F_MAIN, AGC_OP_CALL_BUILTIN, 10, B_SPAWN);
    emit(p, F_MAIN, AGC_OP_MOVE, 2 + k, 10);
  }
  for (uint32_t k = 0; k < NET_TASKS; k++) {
    emit(p, F_MAIN, AGC_OP_MOVE, 10, 2 + k);
    emit(p, F_MAIN, AGC_OP_CALL_BUILTIN, 10, B_AWAIT);
  }
  emit(p, F_MAIN, AGC_OP_MOVE, 10, 1);
  emit(p, F_MAIN, AGC_OP_CALL_BUILTIN, 10, B_CLOSE_LISTENER);
  emit(p, F_MAIN, AGC_OP_RETURN, 0, 0);
  for (int round = 0; round < 3; round++) {
    atomic_store(&total, 0);
    atomic_store(&net_seen, 0);
    agc_outcome out = run(p, 4);
    assert(out.kind == AGC_DONE);
    assert(atomic_load(&total) >= NET_TASKS && bits(atomic_load(&net_seen)) >= 2);
  }
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

/* A service task's timer does not keep a stalled run waiting: main starts one that sleeps for longer than the test may
   take, sees that Task.pending_count leaves it out, and waits on a job nothing can end. Both one and four schedulers
   end the run as a stall at once. */
static void test_stall_beside_a_service(int64_t schedulers) {
  prog *p = agc_alloc(sizeof *p);
  new_prog(p);
  emit(p, F_MAIN, AGC_OP_CLOSURE, 10, F_NAP);
  emit(p, F_MAIN, AGC_OP_CALL_BUILTIN, 10, B_SERVICE);
  call_int(p, F_MAIN, B_SLEEP, 5);
  call_int(p, F_MAIN, B_NO_PENDING, 0);
  call_int(p, F_MAIN, B_FOREVER, 0);
  emit(p, F_MAIN, AGC_OP_RETURN, 0, 0);
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
  test_stall_beside_a_service(1);
  test_stall_beside_a_service(4);
  test_main_fails_beside_spinners(4);
  test_tasks_spread_over_schedulers();
  test_tcp_over_schedulers();
  fclose(quiet);
#endif
  puts("threads tests passed");
  return 0;
}
