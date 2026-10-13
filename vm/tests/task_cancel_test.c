#include "../agc.h"

#include <assert.h>
#include <string.h>
#include <time.h>

#ifdef __linux__
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>
#include <uv.h>

#define MAX_CODE 64
#define MAX_FNS 11
#define SCRATCH 20

enum { B_SPAWN, B_AWAIT, B_SLEEP, B_MARK, B_CANCEL, B_CHECK, B_IO, B_FINISH, B_SELF, B_HTTP, B_UNTIL, B_CLOSE, B_IO_SHORT, B_BLOCK, B_DROP, B_COUNT };

enum { F_MAIN, F_IO, F_SLEEPER, F_AWAITER, F_MARK, F_SELF, F_ITEM, F_PARENT, F_HTTP, F_SHORT, F_DROP };

typedef struct {
  agc_function fns[MAX_FNS];
  agc_instr code[MAX_FNS][MAX_CODE];
  uint32_t spans[MAX_FNS][MAX_CODE];
  agc_span span_table[128];
  agc_source source;
  uint32_t line_start[1], line_chars[1];
  agc_value constants[64];
  const agc_builtin *builtins[B_COUNT];
  agc_program program;
} prog;

typedef void (*checker)(agc_vm *vm, int64_t n);

static int64_t marks[32];
static size_t mark_count;
static int done_calls;
static int dropped;
static int released;
static bool self_returned;
static int owned_closed;
static int tries;
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

static void close_handle(agc_vm *vm, agc_resource *r) {
  (void)vm;
  (void)r;
  owned_closed++;
}

static agc_value test_drop(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  agc_own(vm, handle, close_handle);
  agc_task_drop(vm, vm->task);
  self_returned = true;
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
                       agc_list_value(agc_new_list(0)), text("")};
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
  assert(++tries < 1000);
  agc_io_start(vm, &nap_io, NULL, agc_void(), 5);
  agc_task_park(vm, true);
  return agc_void();
}

static agc_value test_close(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  int64_t k = agc_as_int(vm, args[0]);
  assert(k < accepted_count && accepted[k] >= 0);
  close(accepted[k]);
  accepted[k] = -1;
  return agc_void();
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
  {"Test.drop_self", 1, test_drop, AGC_NATIVE_NONE, AGC_COST_NONE},
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

  mark_arg(p, F_DROP);
  call_reg(p, F_DROP, B_DROP, 0, 1);
  call_int(p, F_DROP, B_MARK, 995);
  finish_fn(p, F_DROP);
}

static void new_prog(prog *p) {
  memset(p, 0, sizeof *p);
  p->builtins[B_SPAWN] = agc_find_builtin((const uint8_t *)"Task.spawn", 10, 2);
  p->builtins[B_AWAIT] = agc_find_builtin((const uint8_t *)"Task.await", 10, 1);
  p->builtins[B_SLEEP] = agc_find_builtin((const uint8_t *)"Task.sleep", 10, 1);
  for (size_t k = 0; k < sizeof test_builtins / sizeof test_builtins[0]; k++) p->builtins[B_MARK + k] = &test_builtins[k];
  for (uint32_t f = 0; f < MAX_FNS; f++) {
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
  p->program.entry = F_MAIN;
  build_tasks(p);
}

static void release_count(void *native) { (*(int *)native)++; }

static void reset(void) {
  mark_count = 0;
  done_calls = 0;
  dropped = 0;
  self_returned = false;
  owned_closed = 0;
  tries = 0;
  client = agc_void();
  memset(jobs, 0, sizeof jobs);
}

static agc_outcome run(agc_vm *vm, prog *p) {
  agc_vm_init(vm, &p->program, stdout, quiet, INT64_MAX);
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
  assert(cancelled(r) && !r->next && vm->ready == NULL && !vm->main->children);
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

static void test_self_drop(void) { run_self(F_DROP, 1); }

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
#endif

int main(void) {
#ifdef __linux__
  agc_init();
  agc_io_init();
  quiet = fopen("/dev/null", "w");
  assert(quiet);
  test_states();
  test_parked_await();
  test_ready_then_await();
  test_self_cancel();
  test_self_drop();
  test_children_move();
  test_timer_fired_then_cancel();
  test_pool();
  fclose(quiet);
#endif
  puts("task cancel tests passed");
  return 0;
}
