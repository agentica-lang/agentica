/*
 * agc_task_cancel on the real scheduler, including a running task that
 * cancels itself after it took a handle, and a task parked as the caller of Task.map.
 */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "../core.h"

#include <assert.h>
#include <string.h>
#include <time.h>

#if defined(__linux__) || defined(__APPLE__)
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>
#include <uv.h>

#define MAX_CODE 64
#define MAX_FNS 22
#define SCRATCH 20

enum { B_SPAWN, B_AWAIT, B_SLEEP, B_MARK, B_CANCEL, B_CHECK, B_IO, B_FINISH, B_SELF, B_HTTP, B_UNTIL, B_CLOSE, B_IO_SHORT, B_BLOCK, B_POOL, B_GATE, B_SETTLED, B_OWN, B_PRINT, B_DRAIN, B_KEEP, B_CLOSING, B_CLOSE_DONE, B_CRASH, B_WINDOW, B_CH_NEW, B_CH_SEND, B_CH_RECV, B_AWAIT_TIMED, B_MAP, B_COUNT };

enum { F_MAIN, F_IO, F_SLEEPER, F_AWAITER, F_MARK, F_SELF, F_ITEM, F_PARENT, F_HTTP, F_SHORT, F_POOL, F_OWN, F_RECV, F_PRINT, F_KEEP, F_CLOSER, F_FINISH, F_TIMED, F_MAP_ITEM, F_MAP_GROUP, F_MAP_CLOSING, F_MAP_CRASHING };

typedef struct {
  agc_function fns[MAX_FNS];
  agc_instr code[MAX_FNS][MAX_CODE];
  uint32_t spans[MAX_FNS][MAX_CODE];
  agc_span span_table[128];
  agc_source source;
  uint32_t line_start[1], line_chars[1];
  agc_value constants[64];
  agc_enum_def enum_defs[1];
  agc_variant_def variant_defs[2];
  const agc_builtin *builtins[B_COUNT];
  agc_program program;
} prog;

typedef void (*checker)(agc_vm *vm, int64_t n);

typedef struct {
  agc_vm *vm;
  int64_t tag;
  agc_poller *poller;
} pool_request;

static int64_t marks[32];
static size_t mark_count;
static int done_calls;
static int dropped;
static int released;
static bool self_returned;
static int owned_closed;
static int tries;
static int window_calls;
static int end_calls;
static agc_task *closed[4];
static size_t closed_count;
static checker check;
static agc_resource *handle;
static agc_io_job *jobs[8];
static agc_value client;
static agc_task *grandchild;
static int listener = -1;
static FILE *quiet;
static int64_t port;
static int accepted[8];
static int accepted_count;
static int gate[2] = {-1, -1};
static int idle[2] = {-1, -1};
static int cancel_calls;
static _Atomic bool on_loop;
static int out_pipe[2] = {-1, -1};
static size_t junk_len, got_len;
static char block[16384];
static uint8_t got[1 << 20];

static agc_task *seen[4];

static agc_value ext_done(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)context;
  int64_t tag = *(int64_t *)data;
  free(data);
  done_calls++;
  return agc_int(tag);
}

static agc_value ext_expired(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)data;
  (void)context;
  return agc_int(-1);
}

static void ext_drop(void *data) {
  free(data);
  dropped++;
}

static bool ext_cancel(agc_vm *vm, void *data, agc_value context, bool deadline) {
  (void)vm;
  (void)data;
  (void)context;
  return deadline;
}

static const agc_io_kind ext_io = {NULL, ext_done, ext_expired, ext_drop, true, "test", NULL};
static const agc_io_kind short_io = {NULL, ext_done, ext_expired, ext_drop, true, "short", ext_cancel};

static agc_value napped(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)data;
  (void)context;
  return agc_void();
}

static const agc_io_kind nap_io = {NULL, napped, napped, NULL, false, "nap", NULL};

static agc_value nap_again(agc_vm *vm) {
  assert(++tries < 1000);
  agc_io_start(vm, &nap_io, NULL, agc_void(), 5);
  agc_task_park(vm, true);
  return agc_void();
}

static void pool_work(void *data) {
  const pool_request *q = data;
  char c;
  if (q->tag == 1)
    while (read(gate[0], &c, 1) < 0 && errno == EINTR) {}
}

static void pool_ready(void *data, int status) {
  (void)data;
  (void)status;
  assert(false);
}

static bool pool_more(void *data, agc_io_job *job) {
  (void)job;
  pool_request *q = data;
  if (q->tag != 2) return false;
  int err = 0;
  q->poller = agc_poller_open(q->vm, idle[0], &err);
  assert(q->poller);
  agc_poller_wait(q->poller, false, pool_ready, q);
  on_loop = true;
  return true;
}

static bool pool_cancel(agc_vm *vm, void *data, agc_value context, bool deadline) {
  (void)vm;
  (void)context;
  (void)deadline;
  pool_request *q = data;
  cancel_calls++;
  agc_poller_pause(q->poller);
  return true;
}

static agc_value pool_done(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)context;
  free(data);
  done_calls++;
  return agc_void();
}

static void pool_drop(void *data) {
  pool_request *q = data;
  if (q->poller) agc_poller_close(q->poller);
  free(q);
  dropped++;
}

static const agc_io_kind pool_io = {pool_work, pool_done, pool_done, pool_drop, false, "pool", pool_cancel};

static agc_value test_pool_job(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  pool_request *q = calloc(1, sizeof(pool_request));
  assert(q);
  q->vm = vm;
  q->tag = agc_as_int(vm, args[0]);
  agc_io_start_then(vm, &pool_io, q, agc_void(), 30000, pool_more);
  return agc_void();
}

static agc_value test_gate(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)vm;
  (void)args;
  (void)span;
  assert(write(gate[1], "x", 1) == 1);
  return agc_void();
}

static agc_value test_settled(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  int64_t want = agc_as_int(vm, args[0]);
  if (want == 0 ? on_loop : done_calls + dropped >= want) {
    tries = 0;
    return agc_void();
  }
  return nap_again(vm);
}

static agc_value test_mark(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  marks[mark_count++] = agc_as_int(vm, args[0]);
  return agc_void();
}

static agc_value test_cancel(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_task_cancel(vm, agc_as_task(vm, args[0]));
  return agc_void();
}

static agc_value test_check(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  check(vm, agc_as_int(vm, args[0]));
  return agc_void();
}

static agc_value handle_io(agc_vm *vm, const agc_io_kind *kind, int64_t tag, int64_t timeout) {
  agc_lock_status status = agc_handle_wait(vm, handle, &timeout);
  if (status == AGC_LOCK_WAIT) return agc_void();
  assert(status == AGC_LOCK_TAKEN);
  int64_t *data = malloc(sizeof(int64_t));
  assert(data);
  *data = tag;
  jobs[tag] = agc_io_start(vm, kind, data, agc_handle_value(handle), timeout);
  return agc_void();
}

static agc_value test_io(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return handle_io(vm, &ext_io, agc_as_int(vm, args[0]), 30000);
}

static agc_value test_io_short(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return handle_io(vm, &short_io, agc_as_int(vm, args[0]), 200);
}

static agc_value test_block(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  int64_t ms = agc_as_int(vm, args[0]);
  struct timespec delay = {0, (long)ms * 1000000L};
  while (nanosleep(&delay, &delay) != 0) {}
  return agc_void();
}

static agc_value test_finish(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_io_ready(jobs[agc_as_int(vm, args[0])]);
  return agc_void();
}

static agc_value test_self(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  agc_task_cancel(vm, vm->task);
  self_returned = true;
  return agc_void();
}

static void close_handle(agc_vm *vm, agc_resource *r, agc_task *ender) {
  (void)vm;
  (void)r;
  (void)ender;
  owned_closed++;
}

static agc_value test_own(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  agc_own(vm, handle, close_handle);
  agc_task_cancel(vm, vm->task);
  self_returned = true;
  return agc_void();
}

static agc_value test_keep(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  agc_own(vm, handle, close_handle);
  return agc_void();
}

static agc_value test_closing(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  vm->task->closing += 2;
  assert(closed_count < sizeof closed / sizeof closed[0]);
  closed[closed_count++] = vm->task;
  return agc_void();
}

static agc_value test_crash(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  agc_fail(vm, "RUNTIME-INVALID-COUNT", "test crash", span);
}

/* A waker that gets in between the park mark and the end of the turn: the first call wakes its own task, as another
   thread could. The task must not park: the turn ends with the task woken, and the builtin runs again. */
static agc_value test_window(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  if (window_calls++ == 0) {
    agc_task_park(vm, true);
    assert(vm->task->state == AGC_TASK_PARKING);
    agc_task_wake(vm, vm->task, "test");
    assert(vm->task->state == AGC_TASK_WOKEN && !agc_runq_peek(vm->rt->runq));
  }
  return agc_void();
}

static agc_value test_close_done(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_task_close_done(vm, agc_as_task(vm, args[0]));
  return agc_void();
}

static agc_value text(const char *s) { return agc_string_value(agc_make_string(s, strlen(s), strlen(s))); }

static agc_value test_http(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  if (agc_is(client, AGC_T_VOID)) {
    agc_value options[5] = {agc_int(10000), agc_int(60000), agc_int(1), agc_int(1 << 20), text("")};
    agc_value made = agc_find_builtin((const uint8_t *)"HttpWire.client", 15, 5)->fn(vm, options, span);
    assert(agc_as_result(vm, made)->ok);
    client = agc_as_result(vm, made)->value;
  }
  agc_value call[8] = {client, text("https"), text("127.0.0.1"), agc_int(port), text("GET"), text("/"),
                       agc_list_value(agc_list_from_array(NULL, 0)), text("")};
  return agc_find_builtin((const uint8_t *)"HttpWire.exchange", 17, 8)->fn(vm, call, span);
}

static void accept_all(void) {
  for (;;) {
    int fd = accept(listener, NULL, NULL);
    if (fd < 0) {
      assert(errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR);
      return;
    }
    assert(accepted_count < 8);
    accepted[accepted_count++] = fd;
  }
}

static agc_value test_until(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  accept_all();
  if (accepted_count >= agc_as_int(vm, args[0])) {
    tries = 0;
    return agc_void();
  }
  return nap_again(vm);
}

static agc_value test_close(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  int64_t k = agc_as_int(vm, args[0]);
  assert(k < accepted_count && accepted[k] >= 0);
  close(accepted[k]);
  accepted[k] = -1;
  return agc_void();
}

static agc_value test_print(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  int64_t tag = agc_as_int(vm, args[0]);
  size_t n = tag == 2 ? 1024 : sizeof block;
  memset(block, tag == 0 ? 'a' : tag == 1 ? 'b' : 'c', n);
  agc_output *out = &vm->rt->out;
  agc_write(vm, out, agc_output_waiting(vm, out) ? NULL : agc_make_string(block, n, n), false);
  return agc_void();
}

static agc_value test_drain(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)vm;
  (void)args;
  (void)span;
  for (;;) {
    ssize_t n = read(out_pipe[0], got + got_len, sizeof got - got_len);
    if (n <= 0) break;
    got_len += (size_t)n;
  }
  if (got_len >= junk_len + AGC_OUTPUT_BUFFER + 1024) {
    tries = 0;
    return agc_void();
  }
  return nap_again(vm);
}

static const agc_builtin test_builtins[] = {
  {"Test.mark", 1, test_mark, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.cancel", 1, test_cancel, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.check", 1, test_check, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.io", 1, test_io, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.finish", 1, test_finish, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.cancel_self", 1, test_self, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.http", 1, test_http, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.until", 1, test_until, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.close", 1, test_close, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.io_short", 1, test_io_short, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.block", 1, test_block, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.pool", 1, test_pool_job, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.gate", 1, test_gate, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.settled", 1, test_settled, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.own_self", 1, test_own, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.print", 1, test_print, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.drain", 1, test_drain, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.keep", 1, test_keep, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.closing", 1, test_closing, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.close_done", 1, test_close_done, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.crash", 1, test_crash, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.window", 1, test_window, AGC_NATIVE_NONE, AGC_COST_NONE},
};

static void emit(prog *p, uint32_t f, agc_opcode op, uint32_t a, uint32_t bx, uint32_t span) {
  agc_function *fn = &p->fns[f];
  assert(fn->count < MAX_CODE);
  p->code[f][fn->count] = (agc_instr){(uint16_t)op, (uint16_t)a, (uint16_t)(bx & 0xffff), (uint16_t)(bx >> 16)};
  p->spans[f][fn->count++] = span;
}

static uint32_t constant(prog *p, int64_t v) {
  uint32_t k = p->program.constant_count++;
  p->constants[k] = agc_int(v);
  return k;
}

static void call_int(prog *p, uint32_t f, uint32_t builtin, int64_t v) {
  emit(p, f, AGC_OP_CONST, SCRATCH, constant(p, v), 1);
  emit(p, f, AGC_OP_CALL_BUILTIN, SCRATCH, builtin, 1);
}

static void call_reg(prog *p, uint32_t f, uint32_t builtin, uint32_t reg, uint32_t span) {
  emit(p, f, AGC_OP_MOVE, SCRATCH, reg, 1);
  emit(p, f, AGC_OP_CALL_BUILTIN, SCRATCH, builtin, span);
}

static void spawn(prog *p, uint32_t f, uint32_t reg, uint32_t fn, int64_t arg) {
  emit(p, f, AGC_OP_CLOSURE, reg, fn, 1);
  emit(p, f, AGC_OP_CONST, reg + 1, constant(p, arg), 1);
  emit(p, f, AGC_OP_CALL_BUILTIN, reg, B_SPAWN, 1);
}

static void spawn_with(prog *p, uint32_t f, uint32_t reg, uint32_t fn, uint32_t arg) {
  emit(p, f, AGC_OP_CLOSURE, reg, fn, 1);
  emit(p, f, AGC_OP_MOVE, reg + 1, arg, 1);
  emit(p, f, AGC_OP_CALL_BUILTIN, reg, B_SPAWN, 1);
}

static void cancel_after_run(prog *p, uint32_t reg) {
  call_int(p, F_MAIN, B_SLEEP, 0);
  call_int(p, F_MAIN, B_CHECK, 1);
  call_reg(p, F_MAIN, B_CANCEL, reg, 1);
  call_int(p, F_MAIN, B_CHECK, 2);
}

static void mark_arg(prog *p, uint32_t f) { call_reg(p, f, B_MARK, 0, 1); }

static void finish_fn(prog *p, uint32_t f) { emit(p, f, AGC_OP_RETURN, 0, 0, 1); }

static void build_tasks(prog *p) {
  call_reg(p, F_IO, B_IO, 0, 1);
  mark_arg(p, F_IO);
  finish_fn(p, F_IO);

  mark_arg(p, F_SLEEPER);
  call_int(p, F_SLEEPER, B_SLEEP, 60000);
  call_int(p, F_SLEEPER, B_MARK, 999);
  finish_fn(p, F_SLEEPER);

  call_reg(p, F_AWAITER, B_AWAIT, 0, 77);
  call_int(p, F_AWAITER, B_MARK, 998);
  finish_fn(p, F_AWAITER);

  mark_arg(p, F_MARK);
  finish_fn(p, F_MARK);

  mark_arg(p, F_SELF);
  call_reg(p, F_SELF, B_SELF, 0, 1);
  call_int(p, F_SELF, B_MARK, 997);
  finish_fn(p, F_SELF);

  spawn(p, F_ITEM, 2, F_PARENT, 0);
  call_int(p, F_ITEM, B_SLEEP, 60000);
  call_int(p, F_ITEM, B_MARK, 996);
  finish_fn(p, F_ITEM);

  spawn(p, F_PARENT, 2, F_SLEEPER, 8);
  finish_fn(p, F_PARENT);

  emit(p, F_HTTP, AGC_OP_MOVE, 1, 0, 1);
  emit(p, F_HTTP, AGC_OP_CALL_BUILTIN, 1, B_HTTP, 1);
  mark_arg(p, F_HTTP);
  emit(p, F_HTTP, AGC_OP_RETURN, 1, 0, 1);

  call_reg(p, F_SHORT, B_IO_SHORT, 0, 1);
  mark_arg(p, F_SHORT);
  finish_fn(p, F_SHORT);

  call_reg(p, F_POOL, B_POOL, 0, 1);
  mark_arg(p, F_POOL);
  finish_fn(p, F_POOL);

  mark_arg(p, F_OWN);
  call_reg(p, F_OWN, B_OWN, 0, 1);
  call_int(p, F_OWN, B_MARK, 995);
  finish_fn(p, F_OWN);

  emit(p, F_RECV, AGC_OP_MOVE, 1, 0, 1);
  emit(p, F_RECV, AGC_OP_CONST, 2, constant(p, 30000), 1);
  emit(p, F_RECV, AGC_OP_CALL_BUILTIN, 1, B_CH_RECV, 1);
  call_int(p, F_RECV, B_MARK, 1);
  emit(p, F_RECV, AGC_OP_RETURN, 1, 0, 1);

  call_reg(p, F_PRINT, B_PRINT, 0, 1);
  finish_fn(p, F_PRINT);

  call_reg(p, F_KEEP, B_KEEP, 0, 1);
  call_int(p, F_KEEP, B_SLEEP, 60000);
  call_int(p, F_KEEP, B_MARK, 994);
  finish_fn(p, F_KEEP);

  call_reg(p, F_CLOSER, B_CLOSING, 0, 1);
  finish_fn(p, F_CLOSER);

  call_reg(p, F_FINISH, B_CLOSE_DONE, 0, 1);
  finish_fn(p, F_FINISH);

  emit(p, F_TIMED, AGC_OP_MOVE, SCRATCH, 0, 1);
  emit(p, F_TIMED, AGC_OP_CONST, SCRATCH + 1, constant(p, 30000), 1);
  emit(p, F_TIMED, AGC_OP_CALL_BUILTIN, SCRATCH, B_AWAIT_TIMED, 1);
  call_int(p, F_TIMED, B_MARK, 993);
  finish_fn(p, F_TIMED);

  mark_arg(p, F_MAP_ITEM);
  call_int(p, F_MAP_ITEM, B_SLEEP, 60000);
  call_int(p, F_MAP_ITEM, B_MARK, 992);
  finish_fn(p, F_MAP_ITEM);

  /* An item that ends with two file closes pending and gives ok(1). */
  uint32_t ok_one = p->program.constant_count++;
  p->constants[ok_one] = agc_result_value(true, agc_int(1));
  call_reg(p, F_MAP_CLOSING, B_CLOSING, 0, 1);
  emit(p, F_MAP_CLOSING, AGC_OP_CONST, 1, ok_one, 1);
  emit(p, F_MAP_CLOSING, AGC_OP_RETURN, 1, 0, 1);

  /* The same, but it crashes before it can return. */
  call_reg(p, F_MAP_CRASHING, B_CLOSING, 0, 1);
  call_reg(p, F_MAP_CRASHING, B_CRASH, 0, 1);
  finish_fn(p, F_MAP_CRASHING);
}

static void new_prog(prog *p) {
  memset(p, 0, sizeof *p);
  p->builtins[B_SPAWN] = agc_find_builtin((const uint8_t *)"Task.spawn", 10, 2);
  p->builtins[B_AWAIT] = agc_find_builtin((const uint8_t *)"Task.await", 10, 1);
  p->builtins[B_SLEEP] = agc_find_builtin((const uint8_t *)"Task.sleep", 10, 1);
  p->builtins[B_CH_NEW] = agc_find_builtin((const uint8_t *)"Channel.new", 11, 1);
  p->builtins[B_CH_SEND] = agc_find_builtin((const uint8_t *)"Channel.send", 12, 3);
  p->builtins[B_CH_RECV] = agc_find_builtin((const uint8_t *)"Channel.recv", 12, 2);
  p->builtins[B_AWAIT_TIMED] = agc_find_builtin((const uint8_t *)"Task.await", 10, 2);
  p->builtins[B_MAP] = agc_find_builtin((const uint8_t *)"Task.map", 8, 4);
  for (size_t k = 0; k < sizeof test_builtins / sizeof test_builtins[0]; k++) p->builtins[B_MARK + k] = &test_builtins[k];
  for (uint32_t f = 0; f < MAX_FNS; f++) {
    p->fns[f].name = agc_make_string("f", 1, 1);
    p->fns[f].params = f == F_MAIN ? 0 : 1;
    p->fns[f].registers = 32;
    p->fns[f].code = p->code[f];
    p->fns[f].spans = p->spans[f];
  }
  p->source.name = agc_make_string("t.agc", 5, 5);
  p->source.text = agc_make_string("x\n", 2, 2);
  p->source.lines = 1;
  p->line_chars[0] = 1;
  p->source.line_start = p->line_start;
  p->source.line_chars = p->line_chars;
  for (uint32_t k = 0; k < 128; k++) p->span_table[k] = (agc_span){0, 1, k + 1, 1, k + 2};
  p->program.sources = &p->source;
  p->program.source_count = 1;
  p->program.spans = p->span_table;
  p->program.span_count = 128;
  p->program.constants = p->constants;
  p->program.builtins = p->builtins;
  p->program.builtin_count = B_COUNT;
  p->program.functions = p->fns;
  p->program.function_count = MAX_FNS;
  p->enum_defs[0] = (agc_enum_def){agc_make_string("Await", 5, 5), 0, 2};
  p->variant_defs[0] = (agc_variant_def){agc_make_string("Done", 4, 4), 0, 1, NULL};
  p->variant_defs[1] = (agc_variant_def){agc_make_string("TimedOut", 8, 8), 0, 0, agc_new_enum(1, 0)};
  p->program.enums = p->enum_defs;
  p->program.enum_count = 1;
  p->program.variants = p->variant_defs;
  p->program.variant_count = 2;
  p->program.max_arity = 1;
  p->program.entry = F_MAIN;
  build_tasks(p);
}

static void release_count(void *native) { (*(int *)native)++; }

static void reset(void) {
  mark_count = 0;
  end_calls = 0;
  closed_count = 0;
  done_calls = 0;
  dropped = 0;
  cancel_calls = 0;
  on_loop = false;
  self_returned = false;
  owned_closed = 0;
  tries = 0;
  window_calls = 0;
  client = agc_void();
  memset(jobs, 0, sizeof jobs);
}

static agc_outcome run(agc_vm *vm, prog *p) {
  agc_vm_init(vm, &p->program, stdout, quiet, INT64_MAX);
  if (out_pipe[1] >= 0) agc_output_open(vm, &vm->rt->out, out_pipe[1]);
  handle = agc_register(vm, &released, release_count);
  return agc_vm_run(vm);
}

static void settle(agc_vm *vm) {
  uv_loop_t *loop = agc_io_uv(vm);
  agc_io_poll(vm, false);
  uv_run(loop, UV_RUN_NOWAIT);
  assert(!uv_loop_alive(loop));
  assert(agc_io_close(vm));
}

static agc_task *reg_task(agc_vm *vm, uint32_t r) { return agc_as_task(vm, vm->main->regs[r]); }

static size_t child_count(const agc_task *t) {
  size_t n = 0;
  for (const agc_task *c = t->children; c; c = c->next_sibling) n++;
  return n;
}

static bool cancelled(const agc_task *t) { return t->state == AGC_TASK_DONE && t->cancelled; }

static void check_states(agc_vm *vm, int64_t n) {
  agc_task *a = reg_task(vm, 0), *b = reg_task(vm, 2), *c = reg_task(vm, 4), *d = reg_task(vm, 6);
  agc_task *s = reg_task(vm, 8), *w = reg_task(vm, 10);
  switch (n) {
    case 1:
      assert(a->state == AGC_TASK_PARKED && a->parked && handle->holder == a->parked);
      assert(handle->waiters == b && b->wait_next == c && c->wait_next == d && b->lock_wait == handle);
      assert(s->state == AGC_TASK_PARKED && s->waiters == w && w->awaiting == s);
      assert(child_count(vm->main) == 6 && a->parent == vm->main);
      break;
    case 2:
      assert(cancelled(w) && !s->waiters);
      assert(cancelled(a) && !a->parked && handle->holder && handle->native);
      assert(cancelled(b) && handle->waiters == c && c->wait_next == d);
      assert(cancelled(s));
      assert(child_count(vm->main) == 2 && done_calls == 0);
      break;
    case 3:
      assert(done_calls == 1 && !handle->holder && handle->native);
      assert(handle->next_owner == c && c->state == AGC_TASK_READY && handle->waiters == d);
      break;
    case 4:
      assert(cancelled(c) && handle->next_owner == d && !handle->waiters);
      break;
    default:
      assert(done_calls == 2 && d->state == AGC_TASK_DONE && !d->cancelled);
      assert(!handle->holder && !handle->next_owner && handle->native);
      assert(!vm->main->children);
      assert(mark_count == 2 && marks[0] == 5 && marks[1] == 4);
  }
}

static void test_states(void) {
  prog p;
  new_prog(&p);
  spawn(&p, F_MAIN, 0, F_IO, 1);
  spawn(&p, F_MAIN, 2, F_IO, 2);
  spawn(&p, F_MAIN, 4, F_IO, 3);
  spawn(&p, F_MAIN, 6, F_IO, 4);
  spawn(&p, F_MAIN, 8, F_SLEEPER, 5);
  spawn_with(&p, F_MAIN, 10, F_AWAITER, 8);
  call_int(&p, F_MAIN, B_SLEEP, 0);
  call_int(&p, F_MAIN, B_CHECK, 1);
  call_reg(&p, F_MAIN, B_CANCEL, 10, 1);
  call_reg(&p, F_MAIN, B_CANCEL, 0, 1);
  call_reg(&p, F_MAIN, B_CANCEL, 2, 1);
  call_reg(&p, F_MAIN, B_CANCEL, 8, 1);
  call_int(&p, F_MAIN, B_CHECK, 2);
  call_int(&p, F_MAIN, B_FINISH, 1);
  call_int(&p, F_MAIN, B_SLEEP, 0);
  call_int(&p, F_MAIN, B_CHECK, 3);
  call_reg(&p, F_MAIN, B_CANCEL, 4, 1);
  call_int(&p, F_MAIN, B_CHECK, 4);
  call_int(&p, F_MAIN, B_SLEEP, 0);
  call_int(&p, F_MAIN, B_FINISH, 4);
  call_reg(&p, F_MAIN, B_AWAIT, 6, 1);
  call_int(&p, F_MAIN, B_CHECK, 5);
  finish_fn(&p, F_MAIN);
  reset();
  check = check_states;
  released = 0;
  agc_vm vm;
  agc_outcome o = run(&vm, &p);
  assert(o.kind == AGC_DONE);
  settle(&vm);
  assert(released == 1);
}

static void check_cancel_check(prog *p, uint32_t reg) {
  call_int(p, F_MAIN, B_CHECK, 1);
  call_reg(p, F_MAIN, B_CANCEL, reg, 1);
  call_int(p, F_MAIN, B_CHECK, 2);
}

static void run_done(prog *p, checker c) {
  finish_fn(p, F_MAIN);
  reset();
  check = c;
  agc_vm vm;
  agc_outcome o = run(&vm, p);
  assert(o.kind == AGC_DONE);
  settle(&vm);
}

static void check_timer_ready(agc_vm *vm, int64_t n) {
  agc_task *a = reg_task(vm, 0);
  if (n == 1) {
    assert(a->state == AGC_TASK_READY && a->parked && handle->holder == a->parked);
  } else if (n == 2) {
    assert(cancelled(a) && handle->holder && dropped == 0);
  } else {
    assert(!handle->holder && dropped == 1 && done_calls == 0 && mark_count == 0);
  }
}

static void test_timer_fired_then_cancel(void) {
  prog p;
  new_prog(&p);
  spawn(&p, F_MAIN, 0, F_SHORT, 1);
  call_int(&p, F_MAIN, B_SLEEP, 0);
  call_int(&p, F_MAIN, B_BLOCK, 300);
  call_int(&p, F_MAIN, B_SLEEP, 0);
  check_cancel_check(&p, 0);
  call_int(&p, F_MAIN, B_SLEEP, 0);
  call_int(&p, F_MAIN, B_CHECK, 3);
  run_done(&p, check_timer_ready);
}

static void test_woken_while_parking(void) {
  prog p;
  new_prog(&p);
  call_int(&p, F_MAIN, B_WINDOW, 0);
  call_int(&p, F_MAIN, B_MARK, 1);
  finish_fn(&p, F_MAIN);
  reset();
  agc_vm vm;
  agc_outcome o = run(&vm, &p);
  assert(o.kind == AGC_DONE && window_calls == 2 && mark_count == 1 && marks[0] == 1);
  settle(&vm);
}

static void check_await(agc_vm *vm, int64_t n) {
  (void)n;
  agc_task *s = reg_task(vm, 0), *w = reg_task(vm, 2);
  assert(s->waiters == w && w->state == AGC_TASK_PARKED);
}

static void test_parked_await(void) {
  prog p;
  new_prog(&p);
  spawn(&p, F_MAIN, 0, F_SLEEPER, 5);
  spawn_with(&p, F_MAIN, 2, F_AWAITER, 0);
  call_int(&p, F_MAIN, B_SLEEP, 0);
  call_int(&p, F_MAIN, B_CHECK, 1);
  call_reg(&p, F_MAIN, B_CANCEL, 0, 1);
  call_int(&p, F_MAIN, B_SLEEP, 0);
  call_int(&p, F_MAIN, B_MARK, 995);
  finish_fn(&p, F_MAIN);
  reset();
  check = check_await;
  agc_vm vm;
  agc_outcome o = run(&vm, &p);
  assert(o.kind == AGC_EXITED && o.exit_code == 1);
  assert(mark_count == 2 && marks[0] == 5 && marks[1] == 995);
  const agc_task *awaiter = reg_task(&vm, 2);
  assert(awaiter->crashed && !awaiter->observed && awaiter->state == AGC_TASK_DONE);
  static const char crash[] = "task crashed: RUNTIME-TASK-CANCELLED at t.agc:1:78: task was cancelled";
  assert(awaiter->crash->bytes == sizeof crash - 1 && memcmp(awaiter->crash->data, crash, sizeof crash - 1) == 0);
  assert(agc_io_close(&vm));
}

static void check_ready(agc_vm *vm, int64_t n) {
  (void)n;
  agc_task *r = reg_task(vm, 0);
  assert(cancelled(r) && !r->next && !agc_runq_peek(vm->rt->runq) && !vm->main->children);
}

static void test_ready_then_await(void) {
  prog p;
  new_prog(&p);
  spawn(&p, F_MAIN, 0, F_MARK, 6);
  call_reg(&p, F_MAIN, B_CANCEL, 0, 1);
  call_int(&p, F_MAIN, B_CHECK, 1);
  call_reg(&p, F_MAIN, B_AWAIT, 0, 88);
  finish_fn(&p, F_MAIN);
  reset();
  check = check_ready;
  agc_vm vm;
  agc_outcome o = run(&vm, &p);
  assert(o.kind == AGC_FAILED && strcmp(o.code, "RUNTIME-TASK-CANCELLED") == 0 && o.span == 88);
  assert(mark_count == 0);
  assert(agc_io_close(&vm));
}

static void run_self(uint32_t fn, int closed) {
  prog p;
  new_prog(&p);
  spawn(&p, F_MAIN, 0, fn, 1);
  call_reg(&p, F_MAIN, B_AWAIT, 0, 99);
  finish_fn(&p, F_MAIN);
  reset();
  agc_vm vm;
  agc_outcome o = run(&vm, &p);
  assert(o.kind == AGC_FAILED && strcmp(o.code, "RUNTIME-TASK-CANCELLED") == 0 && o.span == 99);
  assert(self_returned && owned_closed == closed && mark_count == 1 && marks[0] == 1);
  assert(agc_io_close(&vm));
}

static void test_self_cancel(void) { run_self(F_SELF, 0); }

static void test_self_own(void) { run_self(F_OWN, 1); }

static void check_keep(agc_vm *vm, int64_t n) {
  agc_task *keeper = reg_task(vm, 0);
  if (n == 1) {
    assert(owned_closed == 0 && handle->owner == keeper && keeper->state == AGC_TASK_PARKED);
  } else {
    assert(owned_closed == 1 && !handle->owner && !keeper->owned && cancelled(keeper) && mark_count == 0);
  }
}

static void count_end(agc_vm *vm, agc_task *t) {
  (void)vm;
  (void)t;
  end_calls++;
}

/* The end hook of a task that ended with closes pending (Task.map's) runs once, when the last close is done. */
static void check_closing(agc_vm *vm, int64_t n) {
  agc_task *closer = reg_task(vm, 0);
  agc_task *awaiter = reg_task(vm, 2);
  assert(closer->state == AGC_TASK_DONE && mark_count == 0);
  if (n == 1) {
    assert(closer->closing == 2 && closer->waiters == awaiter && awaiter->state == AGC_TASK_PARKED);
    closer->end = count_end;
  } else if (n == 2) {
    assert(closer->closing == 2 && !closer->waiters && cancelled(awaiter));
  } else if (n == 3) {
    assert(closer->closing == 1 && !closer->waiters && cancelled(awaiter));
    assert(end_calls == 0 && closer->end == count_end);
  } else {
    assert(closer->closing == 0 && !closer->waiters);
    assert(end_calls == 1 && !closer->end);
  }
}

static void test_closing_task(void) {
  prog p;
  new_prog(&p);
  spawn(&p, F_MAIN, 0, F_CLOSER, 1);
  spawn_with(&p, F_MAIN, 2, F_AWAITER, 0);
  cancel_after_run(&p, 2);
  call_reg(&p, F_MAIN, B_CLOSE_DONE, 0, 1);
  call_int(&p, F_MAIN, B_CHECK, 3);
  spawn_with(&p, F_MAIN, 4, F_FINISH, 0);
  call_reg(&p, F_MAIN, B_AWAIT, 0, 88);
  call_int(&p, F_MAIN, B_CHECK, 4);
  run_done(&p, check_closing);
}

static void test_cancel_closes_owned(void) {
  prog p;
  new_prog(&p);
  spawn(&p, F_MAIN, 0, F_KEEP, 1);
  call_int(&p, F_MAIN, B_SLEEP, 0);
  check_cancel_check(&p, 0);
  run_done(&p, check_keep);
}

static void check_children(agc_vm *vm, int64_t n) {
  agc_task *item = reg_task(vm, 0);
  if (n == 1) {
    agc_task *parent = agc_as_task(vm, item->regs[2]);
    grandchild = item->children;
    assert(parent->state == AGC_TASK_DONE && !parent->parent && !parent->children);
    assert(grandchild && !grandchild->next_sibling && grandchild->parent == item);
    assert(grandchild->state == AGC_TASK_PARKED && item->state == AGC_TASK_PARKED);
    assert(vm->main->children == item && !item->next_sibling);
    return;
  }
  assert(cancelled(item) && cancelled(grandchild) && !item->children && !vm->main->children);
}

static void test_children_move(void) {
  prog p;
  new_prog(&p);
  spawn(&p, F_MAIN, 0, F_ITEM, 0);
  call_int(&p, F_MAIN, B_SLEEP, 0);
  call_int(&p, F_MAIN, B_SLEEP, 0);
  call_int(&p, F_MAIN, B_SLEEP, 0);
  check_cancel_check(&p, 0);
  run_done(&p, check_children);
  assert(mark_count == 1 && marks[0] == 8);
}

static void check_channel(agc_vm *vm, int64_t n) {
  agc_task *a = reg_task(vm, 2), *b = reg_task(vm, 4);
  if (n == 1) {
    assert(a->state == AGC_TASK_PARKED && a->parked && a->channel.channel && !a->channel.reserved);
    assert(b->state == AGC_TASK_PARKED && b->parked && b->channel.channel == a->channel.channel);
  } else if (n == 2) {
    assert(cancelled(a) && !a->parked && !a->channel.channel);
    assert(b->state == AGC_TASK_READY && b->channel.reserved && mark_count == 0);
  } else {
    const agc_result *r = agc_as_result(vm, b->result);
    assert(b->state == AGC_TASK_DONE && !b->cancelled && r->ok && agc_as_int(vm, r->value) == 9);
    assert(mark_count == 1 && marks[0] == 1);
  }
}

static void test_channel_waiters(void) {
  prog p;
  new_prog(&p);
  call_int(&p, F_MAIN, B_CH_NEW, 2);
  emit(&p, F_MAIN, AGC_OP_MOVE, 0, SCRATCH, 1);
  spawn_with(&p, F_MAIN, 2, F_RECV, 0);
  spawn_with(&p, F_MAIN, 4, F_RECV, 0);
  call_int(&p, F_MAIN, B_SLEEP, 0);
  call_int(&p, F_MAIN, B_CHECK, 1);
  emit(&p, F_MAIN, AGC_OP_MOVE, 6, 0, 1);
  emit(&p, F_MAIN, AGC_OP_CONST, 7, constant(&p, 9), 1);
  emit(&p, F_MAIN, AGC_OP_CONST, 8, constant(&p, 0), 1);
  emit(&p, F_MAIN, AGC_OP_CALL_BUILTIN, 6, B_CH_SEND, 1);
  call_reg(&p, F_MAIN, B_CANCEL, 2, 1);
  call_int(&p, F_MAIN, B_CHECK, 2);
  call_int(&p, F_MAIN, B_SLEEP, 0);
  call_int(&p, F_MAIN, B_CHECK, 3);
  run_done(&p, check_channel);
}

static void await_timed(prog *p, uint32_t task, uint32_t into, int64_t ms) {
  emit(p, F_MAIN, AGC_OP_MOVE, SCRATCH, task, 1);
  emit(p, F_MAIN, AGC_OP_CONST, SCRATCH + 1, constant(p, ms), 1);
  emit(p, F_MAIN, AGC_OP_CALL_BUILTIN, SCRATCH, B_AWAIT_TIMED, 1);
  emit(p, F_MAIN, AGC_OP_MOVE, into, SCRATCH, 1);
}

static void check_timed_cancel(agc_vm *vm, int64_t n) {
  agc_task *sleeper = reg_task(vm, 0), *waiter = reg_task(vm, 2);
  if (n == 1) {
    assert(sleeper->waiters == waiter && waiter->awaiting == sleeper && waiter->state == AGC_TASK_PARKED);
    assert(waiter->parked && waiter->await_deadline);
  } else {
    assert(!sleeper->waiters && !sleeper->waiters_tail && cancelled(waiter) && !waiter->awaiting && !waiter->parked);
    assert(sleeper->state == AGC_TASK_PARKED && mark_count == 1 && marks[0] == 5);
  }
}

static void test_timed_await_cancel(void) {
  prog p;
  new_prog(&p);
  spawn(&p, F_MAIN, 0, F_SLEEPER, 5);
  spawn_with(&p, F_MAIN, 2, F_TIMED, 0);
  cancel_after_run(&p, 2);
  call_reg(&p, F_MAIN, B_CANCEL, 0, 1);
  run_done(&p, check_timed_cancel);
}

static void check_timed_end(agc_vm *vm, int64_t n) {
  agc_task *sleeper = reg_task(vm, 0), *quick = reg_task(vm, 2);
  const agc_enum *outcome = agc_as_enum(vm, vm->main->regs[n == 1 ? 4 : 6]);
  assert(!vm->main->awaiting && !vm->main->await_deadline && !vm->main->parked);
  if (n == 1) {
    assert(outcome->variant == 1 && outcome->n == 0);
    assert(!sleeper->waiters && !sleeper->waiters_tail && sleeper->state == AGC_TASK_PARKED);
  } else {
    assert(outcome->variant == 0 && outcome->n == 1 && agc_as_int(vm, outcome->payload[0]) == 6);
    assert(quick->state == AGC_TASK_DONE && !quick->waiters && mark_count == 2 && marks[1] == 6);
  }
}

static void test_timed_await_ends(void) {
  prog p;
  new_prog(&p);
  spawn(&p, F_MAIN, 0, F_SLEEPER, 5);
  spawn(&p, F_MAIN, 2, F_MARK, 6);
  await_timed(&p, 0, 4, 20);
  call_int(&p, F_MAIN, B_CHECK, 1);
  await_timed(&p, 2, 6, 30000);
  call_int(&p, F_MAIN, B_CHECK, 2);
  call_reg(&p, F_MAIN, B_CANCEL, 0, 1);
  run_done(&p, check_timed_end);
}

static void check_output(agc_vm *vm, int64_t n) {
  agc_output *o = &vm->rt->out;
  agc_task *first = reg_task(vm, 0), *second = reg_task(vm, 2);
  if (n == 1) {
    assert(o->len == AGC_OUTPUT_BUFFER && o->waiters == first && first->wait_next == second);
    assert(first->output.out == o && second->output.out == o && o->waiters_tail == second);
  } else if (n == 2) {
    assert(cancelled(first) && !first->output.out && first->output.done == 0);
    assert(o->len == AGC_OUTPUT_BUFFER && o->waiters == second && !second->wait_next && o->waiters_tail == second);
    assert(second->state == AGC_TASK_PARKED);
  } else {
    assert(second->state == AGC_TASK_DONE && !second->cancelled && !o->len && !o->waiters);
    assert(got_len == junk_len + AGC_OUTPUT_BUFFER + 1024);
    for (size_t k = 0; k < got_len; k++) {
      uint8_t want = k < junk_len ? 'j' : k < junk_len + AGC_OUTPUT_BUFFER ? 'a' : 'c';
      assert(got[k] == want);
    }
  }
}

static void test_output_waiter(void) {
  assert(pipe(out_pipe) == 0);
  assert(fcntl(out_pipe[0], F_SETFL, O_NONBLOCK) == 0);
  assert(fcntl(out_pipe[1], F_SETFL, O_NONBLOCK) == 0);
  uint8_t junk[1024];
  memset(junk, 'j', sizeof junk);
  junk_len = 0;
  got_len = 0;
  for (;;) {
    ssize_t n = write(out_pipe[1], junk, sizeof junk);
    if (n < 0) break;
    junk_len += (size_t)n;
  }
  prog p;
  new_prog(&p);
  for (int k = 0; k < 4; k++) call_int(&p, F_MAIN, B_PRINT, 0);
  spawn(&p, F_MAIN, 0, F_PRINT, 1);
  spawn(&p, F_MAIN, 2, F_PRINT, 2);
  cancel_after_run(&p, 0);
  call_int(&p, F_MAIN, B_DRAIN, 0);
  call_reg(&p, F_MAIN, B_AWAIT, 2, 1);
  call_int(&p, F_MAIN, B_CHECK, 3);
  run_done(&p, check_output);
  close(out_pipe[0]);
  close(out_pipe[1]);
  out_pipe[0] = out_pipe[1] = -1;
}

static void check_pool(agc_vm *vm, int64_t n) {
  (void)n;
  accept_all();
  assert(accepted_count == 3);
  assert(!agc_as_result(vm, reg_task(vm, 0)->result)->ok && !agc_as_result(vm, reg_task(vm, 6)->result)->ok);
  assert(cancelled(reg_task(vm, 2)) && cancelled(reg_task(vm, 4)));
  assert(mark_count == 2 && marks[0] == 1 && marks[1] == 4);
}

static void open_listener(void) {
  listener = socket(AF_INET, SOCK_STREAM, 0);
  assert(listener >= 0);
  struct sockaddr_in addr = {0};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  assert(bind(listener, (struct sockaddr *)&addr, sizeof addr) == 0);
  assert(listen(listener, 8) == 0);
  socklen_t len = sizeof addr;
  assert(getsockname(listener, (struct sockaddr *)&addr, &len) == 0);
  port = ntohs(addr.sin_port);
  assert(fcntl(listener, F_SETFL, O_NONBLOCK) == 0);
}

static void test_pool(void) {
  prog p;
  new_prog(&p);
  spawn(&p, F_MAIN, 0, F_HTTP, 1);
  call_int(&p, F_MAIN, B_UNTIL, 1);
  spawn(&p, F_MAIN, 2, F_HTTP, 2);
  spawn(&p, F_MAIN, 4, F_HTTP, 3);
  spawn(&p, F_MAIN, 6, F_HTTP, 4);
  call_int(&p, F_MAIN, B_SLEEP, 0);
  call_reg(&p, F_MAIN, B_CANCEL, 4, 1);
  call_int(&p, F_MAIN, B_CLOSE, 0);
  call_reg(&p, F_MAIN, B_AWAIT, 0, 1);
  call_int(&p, F_MAIN, B_UNTIL, 2);
  call_reg(&p, F_MAIN, B_CANCEL, 2, 1);
  call_int(&p, F_MAIN, B_UNTIL, 3);
  call_int(&p, F_MAIN, B_CLOSE, 2);
  call_reg(&p, F_MAIN, B_AWAIT, 6, 1);
  call_int(&p, F_MAIN, B_CHECK, 1);
  finish_fn(&p, F_MAIN);
  reset();
  check = check_pool;
  open_listener();
  agc_vm vm;
  agc_outcome o = run(&vm, &p);
  assert(o.kind == AGC_DONE);
  for (int k = 0; k < accepted_count; k++)
    if (accepted[k] >= 0) close(accepted[k]);
  close(listener);
  assert(agc_io_close(&vm));
}

static void check_pool_phase(agc_vm *vm, int64_t n) {
  if (n == 1) {
    assert(cancelled(reg_task(vm, 0)) && cancel_calls == 0 && dropped == 0 && done_calls == 0);
  } else {
    assert(cancel_calls == 0 && dropped == 0 && done_calls == 1 && mark_count == 0);
  }
}

static void test_cancel_pool_phase(void) {
  prog p;
  new_prog(&p);
  spawn(&p, F_MAIN, 0, F_POOL, 1);
  call_int(&p, F_MAIN, B_SLEEP, 0);
  call_reg(&p, F_MAIN, B_CANCEL, 0, 1);
  call_int(&p, F_MAIN, B_CHECK, 1);
  call_int(&p, F_MAIN, B_GATE, 0);
  call_int(&p, F_MAIN, B_SETTLED, 1);
  call_int(&p, F_MAIN, B_CHECK, 2);
  run_done(&p, check_pool_phase);
}

static void check_loop_phase(agc_vm *vm, int64_t n) {
  if (n == 1) {
    assert(cancelled(reg_task(vm, 0)) && cancel_calls == 1);
  } else {
    assert(dropped == 1 && done_calls == 0 && mark_count == 0);
  }
}

static void test_cancel_loop_phase(void) {
  assert(pipe(idle) == 0);
  prog p;
  new_prog(&p);
  spawn(&p, F_MAIN, 0, F_POOL, 2);
  call_int(&p, F_MAIN, B_SETTLED, 0);
  call_reg(&p, F_MAIN, B_CANCEL, 0, 1);
  call_int(&p, F_MAIN, B_CHECK, 1);
  call_int(&p, F_MAIN, B_SETTLED, 1);
  call_int(&p, F_MAIN, B_CHECK, 2);
  run_done(&p, check_loop_phase);
  assert(fcntl(idle[0], F_GETFD) == -1 && errno == EBADF);
  close(idle[1]);
}
/* The function of a task that calls Task.map over [1, 2, 3] with `limit` and `timeout_ms` and the function `item`, and
   that marks 991 if the call returns. */
static void map_group(prog *p, uint32_t item, int64_t limit, int64_t timeout_ms) {
  agc_value items[3] = {agc_int(1), agc_int(2), agc_int(3)};
  uint32_t list = p->program.constant_count++;
  p->constants[list] = agc_list_value(agc_list_from_array(items, 3));
  emit(p, F_MAP_GROUP, AGC_OP_CONST, 1, list, 1);
  emit(p, F_MAP_GROUP, AGC_OP_CONST, 2, constant(p, limit), 1);
  emit(p, F_MAP_GROUP, AGC_OP_CONST, 3, constant(p, timeout_ms), 1);
  emit(p, F_MAP_GROUP, AGC_OP_CLOSURE, 4, item, 1);
  emit(p, F_MAP_GROUP, AGC_OP_CALL_BUILTIN, 1, B_MAP, 1);
  call_int(p, F_MAP_GROUP, B_MARK, 991);
  emit(p, F_MAP_GROUP, AGC_OP_RETURN, 1, 0, 1);
}

static void check_map_cancel(agc_vm *vm, int64_t n) {
  agc_task *group = reg_task(vm, 0);
  if (n == 1) {
    /* Two items run, as children of the caller, which is parked in the call; the third waits for a free place. */
    assert(group->state == AGC_TASK_PARKED && child_count(group) == 2);
    seen[0] = group->children;
    seen[1] = group->children->next_sibling;
    assert(mark_count == 2 && marks[0] == 1 && marks[1] == 2);
  } else if (n == 2) {
    /* The cancel of the caller reaches the items in flight, and nothing wakes the caller again. */
    assert(cancelled(group) && child_count(group) == 0);
    assert(cancelled(seen[0]) && cancelled(seen[1]));
  } else {
    /* The pending item never started, and the call never returned. */
    assert(mark_count == 2 && cancelled(group) && agc_is(group->result, AGC_T_VOID));
  }
}

static void test_map_caller_cancelled(void) {
  prog p;
  new_prog(&p);
  map_group(&p, F_MAP_ITEM, 2, 30000);
  spawn(&p, F_MAIN, 0, F_MAP_GROUP, 0);
  call_int(&p, F_MAIN, B_SLEEP, 20);
  call_int(&p, F_MAIN, B_CHECK, 1);
  call_reg(&p, F_MAIN, B_CANCEL, 0, 1);
  call_int(&p, F_MAIN, B_CHECK, 2);
  call_int(&p, F_MAIN, B_SLEEP, 30);
  call_int(&p, F_MAIN, B_CHECK, 3);
  run_done(&p, check_map_cancel);
}

static bool timed_out(agc_vm *vm, agc_value slot) {
  const agc_result *r = agc_as_result(vm, slot);
  const agc_string *message = agc_as_string(vm, r->value);
  return !r->ok && message->bytes == 15 && memcmp(message->data, "task: timed out", 15) == 0;
}

/* The three slots of a Task.map over [1, 2, 3] whose caller returned. */
static const agc_list *map_slots(agc_vm *vm, const agc_task *group) {
  assert(group->state == AGC_TASK_DONE && !group->cancelled && !group->children);
  const agc_list *slots = agc_as_list(vm, group->result);
  assert(agc_list_len(slots) == 3);
  return slots;
}

static void check_map_deadlines(agc_vm *vm, int64_t n) {
  (void)n;
  agc_task *group = reg_task(vm, 0);
  /* Each item ran out of time on its own, one after the other (limit 1), and its slot has the timeout error. */
  const agc_list *slots = map_slots(vm, group);
  for (size_t k = 0; k < 3; k++) assert(timed_out(vm, agc_list_get(slots, k)));
  assert(mark_count == 4 && marks[0] == 1 && marks[1] == 2 && marks[2] == 3 && marks[3] == 991);
}

static void test_map_deadlines(void) {
  prog p;
  new_prog(&p);
  map_group(&p, F_MAP_ITEM, 1, 30);
  spawn(&p, F_MAIN, 0, F_MAP_GROUP, 0);
  call_reg(&p, F_MAIN, B_AWAIT, 0, 1);
  call_int(&p, F_MAIN, B_CHECK, 1);
  run_done(&p, check_map_deadlines);
}

/* Ends the pending file closes of a task, as the two jobs of the task would. */
static void finish_closes(agc_vm *vm, agc_task *t) {
  assert(t->state == AGC_TASK_DONE && t->closing == 2);
  agc_task_close_done(vm, t);
  assert(t->closing == 1);
  agc_task_close_done(vm, t);
  assert(t->closing == 0 && !t->end && !t->end_data);
}

static void check_map_closes(agc_vm *vm, int64_t n) {
  agc_task *group = reg_task(vm, 0);
  if (n == 1) {
    /* Every item returned, and none is settled while its closes are pending: the caller still waits. */
    assert(group->state == AGC_TASK_PARKED && closed_count == 3);
    for (size_t k = 0; k < closed_count; k++) {
      assert(closed[k]->closing == 2 && closed[k]->end && !closed[k]->cancelled);
      finish_closes(vm, closed[k]);
    }
  } else {
    const agc_list *slots = map_slots(vm, group);
    for (size_t k = 0; k < 3; k++) {
      const agc_result *r = agc_as_result(vm, agc_list_get(slots, k));
      assert(r->ok && agc_as_int(vm, r->value) == 1);
    }
  }
}

static void test_map_closes(void) {
  prog p;
  new_prog(&p);
  map_group(&p, F_MAP_CLOSING, 3, 30000);
  spawn(&p, F_MAIN, 0, F_MAP_GROUP, 0);
  call_int(&p, F_MAIN, B_SLEEP, 20);
  call_int(&p, F_MAIN, B_CHECK, 1);
  call_reg(&p, F_MAIN, B_AWAIT, 0, 1);
  call_int(&p, F_MAIN, B_CHECK, 2);
  run_done(&p, check_map_closes);
}

static void check_map_late_closes(agc_vm *vm, int64_t n) {
  agc_task *group = reg_task(vm, 0);
  if (n == 1) {
    /* Item 1 crashed with its closes pending and ran out of time: its slot is the timeout, and its crash, which nobody
       will read, counts as observed. Item 2 is within its time. */
    assert(group->state == AGC_TASK_PARKED && closed_count == 2);
    assert(closed[0]->crashed && closed[0]->observed && !closed[1]->observed);
    assert(vm->crash_count == 2 && vm->observed_count == 1 && vm->crashes == closed[1]);
    /* The late end of its closes settles nothing and wakes nobody. */
    finish_closes(vm, closed[0]);
    assert(group->state == AGC_TASK_PARKED);
    /* The closes of item 2 end in time: it settles with its crash as the error, and the caller wakes. */
    finish_closes(vm, closed[1]);
    assert(group->state == AGC_TASK_READY);
  } else {
    assert(closed_count == 3);
    const agc_list *slots = map_slots(vm, group);
    assert(timed_out(vm, agc_list_get(slots, 0)) && !timed_out(vm, agc_list_get(slots, 1)));
    assert(!agc_as_result(vm, agc_list_get(slots, 1))->ok && timed_out(vm, agc_list_get(slots, 2)));
    /* Every crash was read, by the caller or at the deadline, so none is reported at the end of the run. */
    assert(vm->crash_count == 3 && vm->observed_count == 3 && !vm->crashes);
    assert(closed[2]->closing == 2);
    finish_closes(vm, closed[2]);
  }
}

static void test_map_late_closes(void) {
  prog p;
  new_prog(&p);
  map_group(&p, F_MAP_CRASHING, 1, 150);
  spawn(&p, F_MAIN, 0, F_MAP_GROUP, 0);
  call_int(&p, F_MAIN, B_SLEEP, 225);
  call_int(&p, F_MAIN, B_CHECK, 1);
  call_reg(&p, F_MAIN, B_AWAIT, 0, 1);
  call_int(&p, F_MAIN, B_CHECK, 2);
  run_done(&p, check_map_late_closes);
}
#endif

int main(void) {
#if defined(__linux__) || defined(__APPLE__)
  agc_init();
  agc_io_init();
  quiet = fopen("/dev/null", "w");
  assert(quiet);
  test_states();
  test_woken_while_parking();
  test_parked_await();
  test_ready_then_await();
  test_self_cancel();
  test_self_own();
  test_cancel_closes_owned();
  test_closing_task();
  test_children_move();
  test_timer_fired_then_cancel();
  test_channel_waiters();
  test_timed_await_cancel();
  test_timed_await_ends();
  test_map_caller_cancelled();
  test_map_deadlines();
  test_map_closes();
  test_map_late_closes();
  signal(SIGPIPE, SIG_IGN);
  test_output_waiter();
  test_pool();
  assert(pipe(gate) == 0);
  test_cancel_pool_phase();
  close(gate[0]);
  close(gate[1]);
  test_cancel_loop_phase();
  fclose(quiet);
#endif
  puts("task cancel tests passed");
  return 0;
}
