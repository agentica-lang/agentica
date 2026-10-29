/*
 * The interpreter: agc_run_turn runs one turn of the current task (yield,
 * parked or done) under the step and cost budgets. It also runs frames,
 * registers, calls, TAIL_CALL, TRY, Int rules, closures and the List callback
 * builtins. Core layer. Design: docs/vm/05-values-execution-builtins.md §6.
 */
#include "core.h"
#include "jit/jit.h"
#include "list_impl.h"

#include <assert.h>
#include <inttypes.h>
#include <math.h>
#include <string.h>
#if AGC_LEAF_CHECK
#include <stdio.h>
#endif

/* An opcode helper (agc_op_* in core.h) is defined inline and always inlined into turn_loop. core.h declares it
   without `inline`, so this definition is also its one external definition (C11 6.7.4p7), which a JIT calls; core.h
   must stay included before the definitions. clang's -Wstatic-in-inline (under -Wpedantic) is a false positive here,
   as the definition is not an inline definition. */
#define OP_HELPER inline __attribute__((always_inline))

typedef enum { SORT_INT, SORT_FLOAT, SORT_TEXT } sort_kind;

/* The result of one run_compiled call: no code ran, the turn yields or parks/done, an unsupported instruction is left
   for the opcode switch, or the new top frame (after a CALL, TAIL_CALL, CALL_VALUE or RETURN exit, or an exit from a
   native call) reloads. */
typedef enum { COMPILED_NONE, COMPILED_YIELD, COMPILED_PARKED, COMPILED_ONE, COMPILED_RELOAD, COMPILED_DONE } compiled_result;

typedef struct {
  uint64_t key;
  uint64_t item;
} sort_entry;

struct agc_native {
  agc_native_kind kind;
  uint32_t span;
  bool started;
  bool more;
  size_t count;
  int64_t cur, last, dir;
  agc_value list, fn, acc, item;
  agc_list_cursor items;
  agc_list_builder out;
  agc_value *kept;
  agc_stepper *stepper;
};

/* Where a failure or an exit jumps: the catch of a builtin that compiled code calls, which hands it on outside
   compiled code (run_compiled), else the turn's or the run's target. */
static _Noreturn void unwind(agc_vm *vm) {
  agc_catch_buf *jit_catch = vm->jit_catch;
  if (jit_catch) {
    vm->jit_catch = NULL;
    AGC_THROW(*jit_catch);
  }
  longjmp(vm->in_turn ? vm->turn : vm->fail, 1);
}

static _Noreturn void raise_failure(agc_vm *vm) {
  agc_stack_capture(vm, vm->outcome);
  unwind(vm);
}

/* A frame of the run of prelude frames (docs/future/25-ruby-typed-idioms.md §25.6): a function with the prelude flag,
   or a native frame (List.map and the like running a block) that a prelude frame called, which is transparent to the
   rule. Natives never sit on natives, since a native calls its callback through a frame of its own. */
static bool in_prelude_run(const agc_program *p, const agc_task *t, uint32_t at) {
  const agc_frame *frame = &t->frames[at];
  if (frame->native) {
    /* One step down is enough: a native never sits on a native, so the frame below is a function frame. */
    if (at == 0 || t->frames[at - 1].native) return false;
    frame = &t->frames[at - 1];
  }
  return frame->function < p->function_count && p->functions[frame->function].prelude;
}

/* The span a runtime error is reported at. In the user's code it is the span the instruction gave. While a prelude
   function runs, the span of its own instructions is the fixed place of its file, which tells the user nothing, so the
   error moves to the call the user wrote: the call of the outermost frame of the innermost run of prelude frames. When
   argument is not negative and that call is a CALL of the function with argument spans (the loader checked their
   range), the error is reported at the span of that argument, as a builtin does with span + 1 + i. With no frame of
   the user below the run (a crafted file that flags main, or the entry of a task) the span stays what it was. */
static uint32_t report_span(const agc_vm *vm, uint32_t span, int64_t argument) {
  const agc_task *t = vm->task;
  if (!t || !t->frames || t->frame_count == 0 || t->frame_count > t->frame_capacity) return span;
  const agc_program *p = vm->rt->program;
  uint32_t top = t->frame_count - 1;
  if (!in_prelude_run(p, t, top)) return span;
  uint32_t outer = top;
  while (outer > 0 && in_prelude_run(p, t, outer - 1)) outer--;
  if (outer == 0) return span;
  const agc_frame *caller = &t->frames[outer - 1];
  if (caller->native) return caller->native->span;
  if (caller->function >= p->function_count) return span;
  const agc_function *fn = &p->functions[caller->function];
  if (caller->pc == 0 || caller->pc > fn->count) return span;
  uint32_t call = fn->spans[caller->pc - 1];
  const agc_frame *callee = &t->frames[outer];
  const agc_instr *in = &fn->code[caller->pc - 1];
  uint32_t target = (uint32_t)in->b | ((uint32_t)in->c << 16);
  if (argument >= 0 && !callee->tail && in->op == AGC_OP_CALL && target == callee->function &&
      (uint64_t)argument < p->functions[callee->function].params)
    return call + 1 + (uint32_t)argument;
  return call;
}

void agc_fail(agc_vm *vm, const char *code, const char *message, uint32_t span) {
  agc_outcome *o = vm->outcome;
  o->kind = AGC_FAILED;
  o->code = code;
  o->message = message;
  o->message_len = strlen(message);
  o->text = NULL;
  o->span = report_span(vm, span, -1);
  raise_failure(vm);
}

void agc_fail_text(agc_vm *vm, const char *code, const agc_string *message, uint32_t span) {
  agc_fail_argument(vm, code, message, -1, span);
}

void agc_fail_argument(agc_vm *vm, const char *code, const agc_string *message, int64_t argument, uint32_t span) {
  agc_outcome *o = vm->outcome;
  o->kind = AGC_FAILED;
  o->code = code;
  o->text = message;
  o->message = message->data;
  o->message_len = message->bytes;
  o->span = report_span(vm, span, argument);
  raise_failure(vm);
}

void agc_exit(agc_vm *vm, int64_t code) {
  vm->outcome->kind = AGC_EXITED;
  vm->outcome->exit_code = code;
  unwind(vm);
}

void agc_stop(agc_vm *vm, int sig) {
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "stop signal=%d", sig);
  agc_exit(vm, 128 + sig);
}

agc_task *agc_new_task(agc_vm *vm) {
  agc_task *t = agc_alloc(sizeof(agc_task));
  t->id = atomic_fetch_add(&vm->rt->next_task_id, 1);
  t->state = AGC_TASK_READY;
  t->result = agc_void();
  return t;
}

/* A scheduler context of RT: every one is made here, because a zeroed timer heap would say a timer is due at once
   (agc_timers in port.h). Its failures go to its own record until agc_vm_init points the first context at rt. */
void agc_vm_init_context(agc_vm *vm, agc_runtime *rt) {
  memset(vm, 0, sizeof *vm);
  vm->rt = rt;
  vm->outcome = &vm->own;
  atomic_init(&vm->timers.next_due, UINT64_MAX);
}

void agc_vm_init(agc_vm *vm, const agc_program *program, FILE *out, FILE *err, int64_t max_steps) {
  agc_runtime *rt = agc_alloc(sizeof(agc_runtime));
  rt->program = program;
  rt->out.file = out;
  rt->out.fd = -1;
  rt->err.file = err;
  rt->err.fd = -1;
  atomic_init(&rt->steps_left, max_steps);
  rt->in.fd = -1;
  rt->flush_timeout = AGC_FLUSH_TIMEOUT_MS;
  rt->hash_key[0] = 0x0706050403020100ULL;
  rt->hash_key[1] = 0x0f0e0d0c0b0a0908ULL;
  rt->args = agc_list_value(agc_list_from_array(NULL, 0));
  rt->empty_list = agc_list_value(agc_list_from_array(NULL, 0));
  /* A Set is the map under another tag, so the empty Map and Set are one object. */
  agc_map *empty = agc_new_map();
  rt->empty_map = agc_map_value(empty);
  rt->empty_set = agc_set_value(empty);
  rt->empty_string = agc_new_string(0, 0);
  for (size_t c = 0; c < AGC_ASCII_CHARS; c++) {
    char ch = (char)c;
    rt->chars[c] = agc_make_string(&ch, 1, 1);
  }
  atomic_init(&rt->next_task_id, 1);
  rt->runq = agc_runq_new();
  rt->sync = agc_lock_new("sync");
  rt->out.lock = agc_lock_new("stdout");
  rt->err.lock = agc_lock_new("stderr");
  rt->log.level = -1;
  rt->log.lowest = AGC_LOG_NO_HANDLER;
  agc_trace_parse(&rt->trace, NULL, 2);
  rt->schedulers = 1;
  agc_vm_init_context(vm, rt);
  vm->outcome = &rt->outcome;
  vm->rt->main = vm->task = agc_new_task(vm);
  agc_random_seed(&vm->task->random, 0);
}

void agc_charge(agc_vm *vm, uint64_t units) {
  agc_task *t = vm->task;
  uint64_t room = (uint64_t)INT64_MAX - (uint64_t)t->turn_cost;
  t->turn_cost += (int64_t)(units < room ? units : room);
}

void agc_charge_bytes(agc_vm *vm, size_t bytes) { agc_charge(vm, bytes / AGC_COST_BYTES); }

static void sync_budget(agc_vm *vm) {
  int64_t spent = vm->stop_set - vm->next_stop;
  vm->turn_left -= spent;
  vm->batch -= spent;
  vm->stop_set = vm->next_stop;
}

static void set_counter(agc_vm *vm) {
  int64_t c = vm->turn_left < vm->batch ? vm->turn_left : vm->batch;
  /* With the profile on, no STEP takes the fast path in the loop, so step_slow sees each one and counts it. */
  if (c < 0 || AGC_PROFILE_ON(vm)) c = 0;
#ifdef AGC_NO_GC
  /* Past the soft allocation limit the next STEP takes the slow path, which ends the run (agc_alloc_limit_check). */
  if (agc_alloc_over_limit()) c = 0;
#endif
  vm->next_stop = vm->stop_set = c;
}

static void take_steps(agc_vm *vm, int64_t want) {
  int64_t left = atomic_load(&vm->rt->steps_left);
  int64_t got;
  do {
    got = left < want ? left : want;
  } while (!atomic_compare_exchange_weak(&vm->rt->steps_left, &left, left - got));
  vm->batch += got;
  vm->turn_taken += got;
}

static void end_turn_now(agc_vm *vm) {
  vm->yield = true;
  vm->next_stop = vm->stop_set = 0;
}

void agc_turn_begin(agc_vm *vm) {
  vm->turn_left = AGC_TURN_STEPS;
  vm->batch = 0;
  vm->turn_taken = 0;
  vm->turn_cost_used = 0;
  vm->yield = false;
  take_steps(vm, AGC_TURN_STEPS);
  set_counter(vm);
}

/* Ends the turn and returns the steps it spent, which the scheduler adds to the task's count. */
uint64_t agc_turn_finish(agc_vm *vm) {
  sync_budget(vm);
  uint64_t spent = (uint64_t)(vm->turn_taken - vm->batch);
  if (vm->batch > 0) atomic_fetch_add(&vm->rt->steps_left, vm->batch);
  vm->batch = 0;
  vm->turn_taken = 0;
  vm->next_stop = vm->stop_set = 0;
  return spent;
}

/* The steps the running task has spent: those of its finished turns and those of this one so far. Steps count only
   STEP instructions and the steps the interpreter and builtins count, so the number is the same on every run of the
   same work, with or without the profile. */
uint64_t agc_task_steps(const agc_vm *vm) {
  int64_t pending = vm->stop_set - vm->next_stop;
  return vm->task->steps + (uint64_t)(vm->turn_taken - vm->batch + pending);
}

/* The profile hooks (AGENTICA_VM_TRACE=profile) are out of line and cold. The loop itself is built twice, with and
 * without the hooks (turn_loop), so a run without the profile has the code it had before. */
#define PROFILE_HOOK __attribute__((noinline, cold))

/* True when frame AT of T is the native frame that runs STEPPER: a Profile.measure whose block has not returned. */
bool agc_frame_runs(const agc_task *t, uint32_t at, const agc_stepper *stepper) {
  if (at >= t->frame_count) return false;
  const agc_native *st = t->frames[at].native;
  return st && st->kind == AGC_NATIVE_STEPPER && st->stepper == stepper;
}

/* The name of frame K of T in a folded stack: a function, the builtin of a native frame, or the label of a
   Profile.measure. A native frame always sits on the function frame whose CALL_BUILTIN started it, and that frame's
   pc is just past the call, so the builtin's index is read there and the native frame need not keep it. */
static uint64_t frame_code(const agc_vm *vm, const agc_task *t, uint32_t k) {
  const agc_frame *frame = &t->frames[k];
  const agc_native *st = frame->native;
  if (!st) return AGC_PROFILE_CODE(AGC_PROFILE_FUNCTION, frame->function);
  if (st->kind == AGC_NATIVE_STEPPER && st->stepper->step == agc_profile_measure_step)
    return AGC_PROFILE_CODE(AGC_PROFILE_LABEL, agc_profile_measure_label(st->stepper));
  const agc_program *p = vm->rt->program;
  const agc_frame *caller = k > 0 ? &t->frames[k - 1] : NULL;
  if (!caller || caller->native || caller->function >= p->function_count || caller->pc == 0 ||
      caller->pc > p->functions[caller->function].count)
    return AGC_PROFILE_CODE(AGC_PROFILE_BUILTIN, UINT32_MAX);
  const agc_instr *in = &p->functions[caller->function].code[caller->pc - 1];
  if (in->op != AGC_OP_CALL_BUILTIN) return AGC_PROFILE_CODE(AGC_PROFILE_BUILTIN, UINT32_MAX);
  return AGC_PROFILE_CODE(AGC_PROFILE_BUILTIN, (uint32_t)in->b | ((uint32_t)in->c << 16));
}

/* One sample of the folded output: the frames of the running task, outermost first, with WEIGHT steps. A stack deeper
   than AGC_PROFILE_FRAMES keeps its outer and inner halves around one "..." frame. */
static void profile_sample(agc_vm *vm, uint64_t weight) {
  const agc_task *t = vm->task;
  uint64_t *codes = vm->profile->frames;
  uint32_t n = t->frame_count, kept = 0, half = AGC_PROFILE_FRAMES / 2;
  for (uint32_t k = 0; k < n; k++) {
    if (n > AGC_PROFILE_FRAMES && k == half) {
      codes[kept++] = AGC_PROFILE_CODE(AGC_PROFILE_CUT, 0);
      k = n - (AGC_PROFILE_FRAMES - half - 1);
    }
    codes[kept++] = frame_code(vm, t, k);
  }
  agc_profile_add_stack(vm->profile, codes, kept, weight);
}

/* The steps of a STEP, or of one pass of a native loop, go to the function that runs them. With folded output, every
   `every` steps of the run take a sample, weighted by the steps it stands for. */
static PROFILE_HOOK void profile_steps(agc_vm *vm, int64_t n) {
  const agc_task *t = vm->task;
  if (t->frame_count == 0) return;
  agc_profile *profile = vm->profile;
  const agc_frame *frame = &t->frames[t->frame_count - 1];
  profile->steps[frame->native ? profile->functions : frame->function] += (uint64_t)n;
  if (!profile->every) return;
  if ((uint64_t)n < profile->left) {
    profile->left -= (uint64_t)n;
    return;
  }
  uint64_t over = (uint64_t)n - profile->left;
  profile->left = profile->every - over % profile->every;
  profile_sample(vm, (1 + over / profile->every) * profile->every);
}

static PROFILE_HOOK void profile_call(agc_vm *vm, uint32_t function) { vm->profile->calls[function]++; }

static PROFILE_HOOK void profile_builtin_call(agc_vm *vm, uint32_t id) {
  vm->profile->builtin_calls[id]++;
  vm->profile->builtin_native++;
}

/* The count of one instruction and of its pair with the one before it in the frame (*BEFORE, AGC_OP_COUNT for none).
   It runs once per instruction, so it is inline: only the copy of turn_loop that has `profiling` true calls it. An
   opcode out of range is left to the loop's own failure. */
static inline __attribute__((always_inline)) void profile_op(agc_profile *profile, uint32_t *before, uint32_t op) {
  if (op >= AGC_OP_COUNT) return;
  profile->ops[op]++;
  if (*before < AGC_OP_COUNT) profile->pairs[*before * AGC_OP_COUNT + op]++;
  *before = op;
}

/* The call of a builtin. Once the VM is shared (agc_share) a builtin whose row is marked `shared` runs with rt->sync
 * held, so the task tree, the waiter lists, the channels, the handles and the logger table are seen by one scheduler
 * at a time. The lock is not held when the builtin returns: a builtin that must wait registers the wait and returns,
 * and the task parks outside the lock. A builtin that fails leaves the lock to agc_sync_reset. */
static inline agc_value call_builtin(agc_vm *vm, const agc_builtin *b, agc_value *args, uint32_t span) {
  if (__builtin_expect(vm->rt->shared, 0) && b->shared) {
    agc_sync_take(vm);
    agc_value result = b->fn(vm, args, span);
    agc_sync_drop(vm);
    return result;
  }
  return b->fn(vm, args, span);
}

#if AGC_LEAF_CHECK
/* Names the leaf builtin and what it did that a leaf must not (a row marked leaf by mistake). */
static _Noreturn __attribute__((noinline, cold)) void leaf_broken(const agc_builtin *b, const char *what) {
  char detail[160];
  (void)snprintf(detail, sizeof detail, "builtin %s/%" PRIu32 " is marked leaf but %s", b->name, b->arity, what);
  agc_internal_abort(detail);
}

/* The call of a leaf builtin (agc_builtin.leaf), checked: it parked (or asked to retry), started a stepper, charged
   turn cost, counted a step, asked to yield or left rt->sync taken, any of which the generic tail of CALL_BUILTIN
   would have handled, so the run stops. */
static inline agc_value call_leaf(agc_vm *vm, const agc_builtin *b, agc_value *args, uint32_t span) {
  const agc_task *t = vm->task;
  int64_t cost = t->turn_cost, stop = vm->next_stop, left = vm->turn_left;
  uint32_t depth = vm->sync_depth;
  bool yielded = vm->yield, retry = t->retry;
  agc_value result = b->fn(vm, args, span);
  if (t->parking || t->retry != retry) leaf_broken(b, "parked");
  if (t->stepper) leaf_broken(b, "started a stepper");
  if (t->turn_cost != cost) leaf_broken(b, "charged turn cost");
  if (vm->next_stop != stop || vm->turn_left != left || vm->yield != yielded)
    leaf_broken(b, "counted a step or asked to yield");
  if (vm->sync_depth != depth) leaf_broken(b, "left rt->sync taken");
  return result;
}
#else
/* The call of a leaf builtin (agc_builtin.leaf). A leaf row is never shared, so the caller takes no lock; a leaf that
   reads shared state takes rt->sync and drops it itself (agc_builtin.leaf). */
static inline agc_value call_leaf(agc_vm *vm, const agc_builtin *b, agc_value *args, uint32_t span) {
  return b->fn(vm, args, span);
}
#endif

/* A builtin call with its count and time: the time of the call itself, so a builtin that parks is timed until it
 * does. A LEAF call goes through call_leaf, so the check of the leaf rule runs under the profile too. */
static PROFILE_HOOK agc_value profile_builtin(agc_vm *vm, const agc_builtin *b, uint32_t id, agc_value *args,
                                              uint32_t span, bool leaf) {
  uint64_t began = agc_trace_now();
  agc_value result = leaf ? call_leaf(vm, b, args, span) : call_builtin(vm, b, args, span);
  vm->profile->builtin_calls[id]++;
  vm->profile->builtin_ns[id] += agc_trace_now() - began;
  return result;
}

static void step_slow(agc_vm *vm, int64_t n, uint32_t span) {
#ifdef AGC_NO_GC
  agc_alloc_limit_check();
#endif
  if (AGC_PROFILE_ON(vm)) profile_steps(vm, n);
  sync_budget(vm);
  if (vm->batch < n) take_steps(vm, n - vm->batch + AGC_TURN_STEPS);
  if (vm->batch < n)
    agc_fail(vm, "RUNTIME-STEP-LIMIT", "execution step budget exhausted", span + (uint32_t)vm->batch);
  vm->batch -= n;
  vm->turn_left -= n;
  if (vm->turn_left <= 0) {
    end_turn_now(vm);
    return;
  }
  set_counter(vm);
}

static void count_step(agc_vm *vm, uint32_t span) {
  if (vm->next_stop > 1) {
    vm->next_stop--;
    return;
  }
  step_slow(vm, 1, span);
}

/* One step for a builtin that starts work of its own, as the interpreter counts one for each callback it makes. */
void agc_count_step(agc_vm *vm, uint32_t span) { count_step(vm, span); }

bool agc_step_turn(agc_vm *vm, uint32_t span) {
  count_step(vm, span);
  return vm->yield;
}

static bool apply_cost(agc_vm *vm) {
  int64_t c = vm->task->turn_cost;
  vm->task->turn_cost = 0;
  if (vm->rt->no_turn_cost) return false;
  vm->turn_cost_used = vm->turn_cost_used < INT64_MAX - c ? vm->turn_cost_used + c : INT64_MAX;
  sync_budget(vm);
  vm->turn_left = vm->turn_left > INT64_MIN + c ? vm->turn_left - c : INT64_MIN;
  if (vm->turn_left <= 0) {
    end_turn_now(vm);
    return true;
  }
  set_counter(vm);
  return false;
}

bool agc_turn_charge(agc_vm *vm) { return vm->task->turn_cost && apply_cost(vm); }

static void ensure_registers(agc_vm *vm, agc_task *t, size_t needed, uint32_t span) {
  if (needed <= t->reg_capacity) return;
  if (needed > AGC_MAX_REGISTERS) agc_fail(vm, "RUNTIME-STACK-OVERFLOW", "call depth limit exceeded", span);
  size_t capacity = t->reg_capacity ? t->reg_capacity : 256;
  while (capacity < needed) capacity *= 2;
  agc_value *regs = agc_alloc(agc_size_mul(capacity, sizeof(agc_value)));
  if (t->reg_capacity) memcpy(regs, t->regs, t->reg_capacity * sizeof(agc_value));
  t->regs = regs;
  t->reg_capacity = capacity;
}

static agc_frame *new_frame(agc_task *t) {
  if (t->frame_count == t->frame_capacity) {
    uint32_t capacity = t->frame_capacity ? t->frame_capacity * 2 : 64;
    agc_frame *frames = agc_alloc(agc_size_mul(capacity, sizeof(agc_frame)));
    if (t->frame_count) memcpy(frames, t->frames, t->frame_count * sizeof(agc_frame));
    t->frames = frames;
    t->frame_capacity = capacity;
  }
  return &t->frames[t->frame_count++];
}

static void push_frame(agc_vm *vm, agc_task *t, uint32_t function, uint32_t base, uint32_t ret, uint32_t span) {
  if (t->depth >= AGC_MAX_DEPTH) agc_fail(vm, "RUNTIME-STACK-OVERFLOW", "call depth limit exceeded", span);
  ensure_registers(vm, t, (size_t)base + vm->rt->program->functions[function].registers, span);
  agc_frame *frame = new_frame(t);
  frame->function = function;
  frame->pc = 0;
  frame->base = base;
  frame->ret = ret;
  frame->tail = false;
  frame->native = NULL;
  t->depth++;
}

static void call_value(agc_vm *vm, agc_task *t, agc_value value, uint32_t window, const agc_value *args, uint32_t argc,
                       uint32_t ret, uint32_t span) {
  const agc_program *p = vm->rt->program;
  const agc_fn *fn = agc_as_fn(vm, value);
  if (fn->function >= p->function_count || p->functions[fn->function].params != argc ||
      p->functions[fn->function].captures != fn->n)
    agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: function value does not match its call", span);
  /* The one profile test left in a normal build: these two entries are shared by both copies of the turn loop. */
  if (AGC_PROFILE_ON(vm)) profile_call(vm, fn->function);
  push_frame(vm, t, fn->function, window, ret, span);
  agc_value *R = t->regs + window;
  if (args) memcpy(R, args, (size_t)argc * sizeof(agc_value));
  if (fn->n) memcpy(R + argc, fn->captured, (size_t)fn->n * sizeof(agc_value));
}

void agc_task_call(agc_vm *vm, agc_task *t, agc_value fn, uint32_t window, const agc_value *args, uint32_t argc,
                   uint32_t ret, uint32_t span) {
  call_value(vm, t, fn, window, args, argc, ret, span);
}

void agc_task_enter(agc_vm *vm, agc_task *t, uint32_t function) {
  /* Like call_value: a profile test that a normal build still pays, once per task start. */
  if (AGC_PROFILE_ON(vm)) profile_call(vm, function);
  push_frame(vm, t, function, 0, 0, 0);
}

static void finish_native(agc_vm *vm, agc_value result) {
  agc_task *t = vm->task;
  agc_frame *frame = &t->frames[t->frame_count - 1];
  uint32_t base = frame->base;
  frame->native = NULL;
  t->frame_count--;
  t->regs[base] = result;
  if (t->turn_cost) apply_cost(vm);
}

static uint64_t int_order(int64_t i) { return (uint64_t)i ^ ((uint64_t)1 << 63); }

static uint64_t float_order(double d) {
  if (isnan(d)) return UINT64_MAX;
  if (d == 0) d = 0;
  uint64_t bits;
  memcpy(&bits, &d, sizeof bits);
  return (bits >> 63) ? ~bits : bits | ((uint64_t)1 << 63);
}

static bool entry_less(sort_kind kind, const sort_entry *x, const sort_entry *y) {
  if (kind != SORT_TEXT) return x->key < y->key;
  const agc_string *a = (const agc_string *)(uintptr_t)x->key, *b = (const agc_string *)(uintptr_t)y->key;
  size_t n = a->bytes < b->bytes ? a->bytes : b->bytes;
  int order = n ? memcmp(a->data, b->data, n) : 0;
  return order < 0 || (order == 0 && a->bytes < b->bytes);
}

static sort_entry *sort_entries(agc_vm *vm, const agc_list *keys, size_t n, sort_kind kind, bool carry) {
  size_t bytes = agc_size_mul(n, sizeof(sort_entry));
  sort_entry *entries = kind == SORT_TEXT ? agc_alloc(bytes) : agc_alloc_atomic(bytes);
  agc_list_cursor cursor;
  agc_value key;
  agc_list_cursor_begin(&cursor, keys, 0);
  for (size_t k = 0; agc_list_cursor_next(&cursor, &key); k++) {
    entries[k].item = carry ? agc_value_word(key) : k;
    if (kind == SORT_INT)
      entries[k].key = int_order(agc_as_int(vm, key));
    else if (kind == SORT_FLOAT)
      entries[k].key = float_order(agc_as_float(vm, key));
    else
      entries[k].key = (uint64_t)(uintptr_t)agc_as_string(vm, key);
  }
  return entries;
}

/* 1 when the keys never decrease, -1 when each is below the one before, else 0 */
static int sort_direction(sort_kind kind, const sort_entry *entries, size_t n) {
  bool up = true, down = true;
  for (size_t k = 1; k < n && (up || down); k++) {
    bool below = entry_less(kind, &entries[k], &entries[k - 1]);
    up = up && !below;
    down = down && below;
  }
  return up ? 1 : down ? -1 : 0;
}

static const sort_entry *sort_merge(sort_kind kind, sort_entry *from, sort_entry *to, size_t n) {
  for (size_t width = 1; width < n; width *= 2) {
    for (size_t lo = 0; lo < n; lo += 2 * width) {
      size_t mid = n - lo < width ? n : lo + width;
      size_t hi = n - mid < width ? n : mid + width;
      size_t i = lo, j = mid, k = lo;
      while (i < mid && j < hi) to[k++] = entry_less(kind, &from[j], &from[i]) ? from[j++] : from[i++];
      while (i < mid) to[k++] = from[i++];
      while (j < hi) to[k++] = from[j++];
    }
    sort_entry *swap = from;
    from = to;
    to = swap;
  }
  return from;
}

agc_value agc_sort_by_keys(agc_vm *vm, const agc_list *items, const agc_list *keys) {
  size_t n = agc_list_len(items);
  if (n < 2) return agc_list_value((agc_list *)items);
  uint64_t rounds = 0;
  for (size_t width = 1; width < n; width *= 2) rounds++;
  agc_charge(vm, (uint64_t)n * rounds);
  agc_value first = agc_list_get(keys, 0);
  sort_kind kind = agc_is(first, AGC_T_STRING) ? SORT_TEXT : agc_is(first, AGC_T_FLOAT) ? SORT_FLOAT : SORT_INT;
  bool carry = items == keys && agc_list_kind(items);
  sort_entry *entries = sort_entries(vm, keys, n, kind, carry);
  int direction = sort_direction(kind, entries, n);
  if (direction > 0) return agc_list_value((agc_list *)items);
  if (direction < 0) return agc_list_value(agc_list_reverse(items));
  size_t bytes = agc_size_mul(n, sizeof(sort_entry));
  sort_entry *scratch = kind == SORT_TEXT ? agc_alloc(bytes) : agc_alloc_atomic(bytes);
  const sort_entry *order = sort_merge(kind, entries, scratch, n);
  agc_list_builder sorted;
  agc_list_builder_sized(&sorted, n);
  if (carry) {
    uint32_t tag = agc_list_kind(items);
    for (size_t k = 0; k < n; k++) agc_list_builder_push(&sorted, agc_word_value(tag, order[k].item));
  } else {
    for (size_t k = 0; k < n; k++) agc_list_builder_push(&sorted, list_get(items, order[k].item));
  }
  return agc_list_value(agc_list_builder_finish(&sorted));
}

static bool counting(agc_native_kind kind) {
  return kind == AGC_NATIVE_RANGE_EACH || kind == AGC_NATIVE_TIMES || kind == AGC_NATIVE_UPTO ||
         kind == AGC_NATIVE_DOWNTO;
}

static void resume_stepper(agc_vm *vm) {
  agc_task *t = vm->task;
  agc_frame *frame = &t->frames[t->frame_count - 1];
  agc_native *st = frame->native;
  uint32_t base = frame->base;
  bool locked = !st->stepper->unlocked;
  if (locked) agc_sync_take(vm);
  agc_step next = st->stepper->step(vm, st->stepper, t->regs[base]);
  if (locked) agc_sync_drop(vm);
  /* An unlocked step locks its own sections (port.h) and must return with them closed, a park included. */
  else if (vm->sync_depth)
    agc_fail(vm, "RUNTIME-INTERNAL", "an unlocked step returned holding rt->sync", st->span);
  switch (next.kind) {
    case AGC_STEP_CALL:
    case AGC_STEP_CALL2:
    case AGC_STEP_CALL0: {
      count_step(vm, st->span);
      agc_value args[2] = {next.value, next.second};
      agc_value fn = agc_is(next.fn, AGC_T_VOID) ? st->fn : next.fn;
      uint32_t argc = next.kind == AGC_STEP_CALL2 ? 2 : next.kind == AGC_STEP_CALL0 ? 0 : 1;
      call_value(vm, t, fn, base + 1, args, argc, base, st->span);
      t->turn_cost++;
      apply_cost(vm);
      return;
    }
    case AGC_STEP_WAIT:
      if (!t->parking) agc_fail(vm, "RUNTIME-INTERNAL", "a step waited without parking", st->span);
      t->park_reg = base;
      return;
    case AGC_STEP_YIELD:
      /* The caller of resume_native returns AGC_TURN_YIELD when vm->yield is set; without it, it would run the
         native frame as bytecode. The frame stays, and the next turn resumes the step with a Void `last`. */
      if (!vm->yield) agc_fail(vm, "RUNTIME-INTERNAL", "a step yielded with turn left", st->span);
      t->regs[base] = agc_void();
      return;
    case AGC_STEP_END: finish_native(vm, next.value); return;
  }
}

static void resume_native(agc_vm *vm) {
  agc_task *t = vm->task;
  agc_frame *frame = &t->frames[t->frame_count - 1];
  agc_native *st = frame->native;
  uint32_t base = frame->base;
  if (st->kind == AGC_NATIVE_STEPPER) {
    resume_stepper(vm);
    return;
  }
  if (counting(st->kind)) {
    if (!st->more) {
      finish_native(vm, agc_void());
      return;
    }
    count_step(vm, st->span);
    agc_value arg = agc_int(st->cur);
    st->more = st->cur != st->last;
    if (st->more) st->cur += st->dir;
    call_value(vm, t, st->fn, base + 1, &arg, 1, base, st->span);
    return;
  }
  if (st->started) {
    agc_value got = t->regs[base];
    switch (st->kind) {
      case AGC_NATIVE_MAP:
      case AGC_NATIVE_SORT_BY: agc_list_builder_push(&st->out, got); break;
      case AGC_NATIVE_FILTER:
        if (agc_as_bool(vm, got)) st->kept[st->count++] = st->item;
        break;
      case AGC_NATIVE_ANY:
        if (agc_as_bool(vm, got)) {
          finish_native(vm, agc_bool(true));
          return;
        }
        break;
      case AGC_NATIVE_ALL:
        if (!agc_as_bool(vm, got)) {
          finish_native(vm, agc_bool(false));
          return;
        }
        break;
      case AGC_NATIVE_REDUCE: st->acc = got; break;
      default: break;
    }
  }
  st->started = true;
  if (agc_list_cursor_next(&st->items, &st->item)) {
    agc_value args[2];
    uint32_t argc = 0;
    if (st->kind == AGC_NATIVE_REDUCE) args[argc++] = st->acc;
    args[argc++] = st->item;
    call_value(vm, t, st->fn, base + 1, args, argc, base, st->span);
    t->turn_cost++;
    apply_cost(vm);
    return;
  }
  agc_value result = agc_void();
  switch (st->kind) {
    case AGC_NATIVE_MAP: result = agc_list_value(agc_list_builder_finish(&st->out)); break;
    case AGC_NATIVE_FILTER: result = agc_list_value(agc_list_from_array(st->kept, st->count)); break;
    case AGC_NATIVE_ANY: result = agc_bool(false); break;
    case AGC_NATIVE_ALL: result = agc_bool(true); break;
    case AGC_NATIVE_REDUCE: result = st->acc; break;
    case AGC_NATIVE_SORT_BY:
      result = agc_sort_by_keys(vm, agc_as_list(vm, st->list), agc_list_builder_finish(&st->out));
      break;
    default: break;
  }
  finish_native(vm, result);
}

static void push_native(agc_vm *vm, agc_native *st, uint32_t base) {
  agc_frame *frame = new_frame(vm->task);
  frame->function = 0;
  frame->pc = 0;
  frame->base = base;
  frame->ret = base;
  frame->tail = false;
  frame->native = st;
  resume_native(vm);
}

static void start_native(agc_vm *vm, agc_native_kind kind, uint32_t base, uint32_t span) {
  agc_native *st = agc_alloc(sizeof(agc_native));
  const agc_value *args = vm->task->regs + base;
  st->kind = kind;
  st->span = span;
  if (counting(kind)) {
    st->dir = 1;
    if (kind == AGC_NATIVE_RANGE_EACH) {
      st->more = agc_range_bounds(agc_as_range(vm, args[0]), &st->cur, &st->last);
      st->fn = args[1];
    } else if (kind == AGC_NATIVE_TIMES) {
      int64_t n = agc_as_int(vm, args[0]);
      st->more = n > 0;
      st->cur = 0;
      st->last = st->more ? n - 1 : 0;
      st->fn = args[1];
    } else {
      st->cur = agc_as_int(vm, args[0]);
      st->last = agc_as_int(vm, args[1]);
      st->fn = args[2];
      if (kind == AGC_NATIVE_DOWNTO) st->dir = -1;
      st->more = kind == AGC_NATIVE_DOWNTO ? st->cur >= st->last : st->cur <= st->last;
    }
    agc_as_fn(vm, st->fn);
  } else {
    st->list = args[0];
    if (kind == AGC_NATIVE_REDUCE) {
      st->acc = args[1];
      st->fn = args[2];
    } else {
      st->fn = args[1];
    }
    const agc_list *items = agc_as_list(vm, st->list);
    size_t len = agc_list_len(items);
    agc_as_fn(vm, st->fn);
    agc_list_cursor_begin(&st->items, items, 0);
    if (kind == AGC_NATIVE_MAP || kind == AGC_NATIVE_SORT_BY) agc_list_builder_sized(&st->out, len);
    if (kind == AGC_NATIVE_FILTER) st->kept = agc_alloc(agc_size_mul(len, sizeof(agc_value)));
  }
  push_native(vm, st, base);
}

/* The stepper that agc_task_call_block names. Never written: start_stepper only compares its address. */
static const agc_stepper call_block = {0};

void agc_task_call_block(agc_vm *vm) { vm->task->stepper = (agc_stepper *)(uintptr_t)&call_block; }

static void start_stepper(agc_vm *vm, const agc_builtin *b, uint32_t base, uint32_t span) {
  agc_task *t = vm->task;
  if (t->stepper == &call_block) {
    /* The block's frame returns straight to the call's register; the step and the turn cost are a stepper call's. */
    t->stepper = NULL;
    count_step(vm, span);
    call_value(vm, t, t->regs[base + b->arity - 1], base + 1, NULL, 0, base, span);
    t->turn_cost++;
    apply_cost(vm);
    return;
  }
  agc_native *st = agc_alloc(sizeof(agc_native));
  st->kind = AGC_NATIVE_STEPPER;
  st->span = span;
  st->stepper = t->stepper;
  st->fn = t->regs[base + b->arity - 1];
  t->stepper = NULL;
  /* A stepper with no block (the terminals of Lazy) names the function of each call in its step. */
  if (st->stepper->no_block)
    st->fn = agc_void();
  else
    agc_as_fn(vm, st->fn);
  push_native(vm, st, base);
}

static void replace_frame(agc_vm *vm, uint32_t function, uint32_t window, uint32_t span) {
  agc_task *t = vm->task;
  agc_frame *frame = &t->frames[t->frame_count - 1];
  const agc_function *callee = &vm->rt->program->functions[function];
  ensure_registers(vm, t, (size_t)frame->base + callee->registers, span);
  agc_value *R = t->regs + frame->base;
  memmove(R, R + window, (size_t)callee->params * sizeof(agc_value));
  frame->function = function;
  frame->pc = 0;
  frame->tail = true;
}

/* The failed try of a block that a Lazy terminal called (TRY_STEP, docs/vm/03-ir-and-bytecode.md §4.2): the error
   goes back to that terminal as for TRY, marked as an escape, so the terminal ends the pipeline with it instead of
   taking it as the block's value. The frame below must be the stepper of a Lazy terminal (agc_stepper.lazy); any other
   native frame, such as File.each_line, Profile.measure or List.map, is bytecode the front end never writes. Out of
   line and only on the failure path, so TRY and the loop keep their shape. */
static __attribute__((noinline, cold)) void mark_escape(agc_vm *vm, agc_task *t, uint32_t span) {
  agc_native *below = t->frame_count >= 2 ? t->frames[t->frame_count - 2].native : NULL;
  if (!below || below->kind != AGC_NATIVE_STEPPER || !below->stepper->lazy)
    agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: try-step outside a Lazy block", span);
  below->stepper->escaped = true;
}

static bool return_value(agc_vm *vm, agc_value result) {
  agc_task *t = vm->task;
  uint32_t ret = t->frames[t->frame_count - 1].ret;
  t->frame_count--;
  t->depth--;
  if (t->frame_count == 0) {
    t->result = result;
    return false;
  }
  t->regs[ret] = result;
  if (t->frames[t->frame_count - 1].native) resume_native(vm);
  return true;
}

/* Shared by the interpreted CALL case and the JIT's CALL boundary exit. The generated function has returned before
   this can grow the frame or register arrays or fail with agc_fail. */
static void call_instruction(agc_vm *vm, agc_task *t, uint32_t function, uint32_t base, uint16_t window, uint32_t span,
                             bool profiling) {
  if (profiling) profile_call(vm, function);
  push_frame(vm, t, function, base + window, base + window, span);
}

/* Shared by the interpreted RETURN case and the JIT's RETURN boundary exit. */
static bool return_instruction(agc_vm *vm, agc_value result) { return return_value(vm, result); }

static inline __attribute__((always_inline)) bool tags_are(const agc_value *a, const agc_value *b, agc_tag tag) {
  return a->tag == (uint32_t)tag && b->tag == (uint32_t)tag;
}

/* 1 when the values are equal, 0 when not, -1 for a pair of values that has no equality (hand-made bytecode): never a
   raw truthy int from libc, which -1 would be mistaken for. The tag tests come first, so the checked accessors after
   them never fail (the compiler drops their second test). Kept out of line, as gcc built it before the helpers took
   pointers: the turn loop is sensitive to its register use. */
static __attribute__((noinline)) int equal_values(agc_vm *vm, const agc_value *x, const agc_value *y) {
  if (tags_are(x, y, AGC_T_INT)) return agc_as_int(vm, *x) == agc_as_int(vm, *y);
  if (tags_are(x, y, AGC_T_FLOAT)) return agc_as_float(vm, *x) == agc_as_float(vm, *y);
  if (tags_are(x, y, AGC_T_NIL)) return 1;
  if (tags_are(x, y, AGC_T_STRING)) return agc_same_string(vm, agc_as_string(vm, *x), agc_as_string(vm, *y));
  if (tags_are(x, y, AGC_T_RANGE)) {
    const agc_range *a = agc_as_range(vm, *x), *b = agc_as_range(vm, *y);
    return a->start == b->start && a->end == b->end && a->exclusive == b->exclusive;
  }
  if (tags_are(x, y, AGC_T_BOOL)) return agc_as_bool(vm, *x) == agc_as_bool(vm, *y);
  int rest = agc_equal_rest(vm, x, y);
  if (rest < -1 || rest > 1) __builtin_unreachable();
  return rest;
}

/* equal_values for SAME: values of two tags are never the same, a NaN is the same as a NaN, and 0.0 is not the same
   as -0.0. */
static int same_values(agc_vm *vm, const agc_value *x, const agc_value *y) {
  if (x->tag != y->tag) return 0;
  if (agc_is(*x, AGC_T_FLOAT)) {
    double a = agc_as_float(vm, *x), b = agc_as_float(vm, *y);
    /* isnan and signbit return any nonzero int (mingw-w64's isnan gives -1), so each is turned into 0 or 1. */
    return isnan(a) ? isnan(b) != 0 : a == b && (signbit(a) != 0) == (signbit(b) != 0);
  }
  return equal_values(vm, x, y);
}

OP_HELPER agc_status agc_op_add_i(agc_vm *vm, agc_value *dst, const agc_value *a, const agc_value *b) {
  int64_t result;
  if (!tags_are(a, b, AGC_T_INT)) return AGC_STATUS_WRONG_TAG;
  if (__builtin_add_overflow(agc_as_int(vm, *a), agc_as_int(vm, *b), &result)) return AGC_STATUS_OVERFLOW;
  *dst = agc_int(result);
  return AGC_STATUS_OK;
}

OP_HELPER agc_status agc_op_sub_i(agc_vm *vm, agc_value *dst, const agc_value *a, const agc_value *b) {
  int64_t result;
  if (!tags_are(a, b, AGC_T_INT)) return AGC_STATUS_WRONG_TAG;
  if (__builtin_sub_overflow(agc_as_int(vm, *a), agc_as_int(vm, *b), &result)) return AGC_STATUS_OVERFLOW;
  *dst = agc_int(result);
  return AGC_STATUS_OK;
}

OP_HELPER agc_status agc_op_mul_i(agc_vm *vm, agc_value *dst, const agc_value *a, const agc_value *b) {
  int64_t result;
  if (!tags_are(a, b, AGC_T_INT)) return AGC_STATUS_WRONG_TAG;
  if (__builtin_mul_overflow(agc_as_int(vm, *a), agc_as_int(vm, *b), &result)) return AGC_STATUS_OVERFLOW;
  *dst = agc_int(result);
  return AGC_STATUS_OK;
}

OP_HELPER agc_status agc_op_div_i(agc_vm *vm, agc_value *dst, const agc_value *a, const agc_value *b) {
  if (!tags_are(a, b, AGC_T_INT)) return AGC_STATUS_WRONG_TAG;
  int64_t dividend = agc_as_int(vm, *a), divisor = agc_as_int(vm, *b);
  if (divisor == 0) return AGC_STATUS_DIVISION_BY_ZERO;
  if (dividend == INT64_MIN && divisor == -1) return AGC_STATUS_OVERFLOW;
  *dst = agc_int(dividend / divisor);
  return AGC_STATUS_OK;
}

OP_HELPER agc_status agc_op_mod_i(agc_vm *vm, agc_value *dst, const agc_value *a, const agc_value *b) {
  if (!tags_are(a, b, AGC_T_INT)) return AGC_STATUS_WRONG_TAG;
  int64_t dividend = agc_as_int(vm, *a), divisor = agc_as_int(vm, *b);
  if (divisor == 0) return AGC_STATUS_DIVISION_BY_ZERO;
  *dst = agc_int(divisor == -1 ? 0 : dividend % divisor);
  return AGC_STATUS_OK;
}

OP_HELPER agc_status agc_op_neg_i(agc_vm *vm, agc_value *dst, const agc_value *a) {
  if (!agc_is(*a, AGC_T_INT)) return AGC_STATUS_WRONG_TAG;
  int64_t integer = agc_as_int(vm, *a);
  if (integer == INT64_MIN) return AGC_STATUS_OVERFLOW;
  *dst = agc_int(-integer);
  return AGC_STATUS_OK;
}

OP_HELPER agc_status agc_op_add_f(agc_vm *vm, agc_value *dst, const agc_value *a, const agc_value *b) {
  if (!tags_are(a, b, AGC_T_FLOAT)) return AGC_STATUS_WRONG_TAG;
  *dst = agc_float(agc_as_float(vm, *a) + agc_as_float(vm, *b));
  return AGC_STATUS_OK;
}

OP_HELPER agc_status agc_op_sub_f(agc_vm *vm, agc_value *dst, const agc_value *a, const agc_value *b) {
  if (!tags_are(a, b, AGC_T_FLOAT)) return AGC_STATUS_WRONG_TAG;
  *dst = agc_float(agc_as_float(vm, *a) - agc_as_float(vm, *b));
  return AGC_STATUS_OK;
}

OP_HELPER agc_status agc_op_mul_f(agc_vm *vm, agc_value *dst, const agc_value *a, const agc_value *b) {
  if (!tags_are(a, b, AGC_T_FLOAT)) return AGC_STATUS_WRONG_TAG;
  *dst = agc_float(agc_as_float(vm, *a) * agc_as_float(vm, *b));
  return AGC_STATUS_OK;
}

/* The divisor is checked first, so a zero divisor fails with RUNTIME-DIVISION-BY-ZERO whatever the left operand. */
OP_HELPER agc_status agc_op_div_f(agc_vm *vm, agc_value *dst, const agc_value *a, const agc_value *b) {
  if (!agc_is(*b, AGC_T_FLOAT)) return AGC_STATUS_WRONG_TAG;
  double divisor = agc_as_float(vm, *b);
  if (divisor == 0) return AGC_STATUS_DIVISION_BY_ZERO;
  if (!agc_is(*a, AGC_T_FLOAT)) return AGC_STATUS_WRONG_TAG;
  *dst = agc_float(agc_as_float(vm, *a) / divisor);
  return AGC_STATUS_OK;
}

OP_HELPER agc_status agc_op_neg_f(agc_vm *vm, agc_value *dst, const agc_value *a) {
  if (!agc_is(*a, AGC_T_FLOAT)) return AGC_STATUS_WRONG_TAG;
  *dst = agc_float(-agc_as_float(vm, *a));
  return AGC_STATUS_OK;
}

OP_HELPER agc_status agc_op_lt_i(agc_vm *vm, agc_value *dst, const agc_value *a, const agc_value *b) {
  if (!tags_are(a, b, AGC_T_INT)) return AGC_STATUS_WRONG_TAG;
  *dst = agc_bool(agc_as_int(vm, *a) < agc_as_int(vm, *b));
  return AGC_STATUS_OK;
}

OP_HELPER agc_status agc_op_le_i(agc_vm *vm, agc_value *dst, const agc_value *a, const agc_value *b) {
  if (!tags_are(a, b, AGC_T_INT)) return AGC_STATUS_WRONG_TAG;
  *dst = agc_bool(agc_as_int(vm, *a) <= agc_as_int(vm, *b));
  return AGC_STATUS_OK;
}

OP_HELPER agc_status agc_op_lt_f(agc_vm *vm, agc_value *dst, const agc_value *a, const agc_value *b) {
  if (!tags_are(a, b, AGC_T_FLOAT)) return AGC_STATUS_WRONG_TAG;
  *dst = agc_bool(agc_as_float(vm, *a) < agc_as_float(vm, *b));
  return AGC_STATUS_OK;
}

OP_HELPER agc_status agc_op_le_f(agc_vm *vm, agc_value *dst, const agc_value *a, const agc_value *b) {
  if (!tags_are(a, b, AGC_T_FLOAT)) return AGC_STATUS_WRONG_TAG;
  *dst = agc_bool(agc_as_float(vm, *a) <= agc_as_float(vm, *b));
  return AGC_STATUS_OK;
}

OP_HELPER agc_status agc_op_eq(agc_vm *vm, agc_value *dst, const agc_value *a, const agc_value *b) {
  int equal = equal_values(vm, a, b);
  if (equal < 0) return AGC_STATUS_WRONG_TAG;
  *dst = agc_bool(equal);
  return AGC_STATUS_OK;
}

OP_HELPER agc_status agc_op_ne(agc_vm *vm, agc_value *dst, const agc_value *a, const agc_value *b) {
  int equal = equal_values(vm, a, b);
  if (equal < 0) return AGC_STATUS_WRONG_TAG;
  *dst = agc_bool(!equal);
  return AGC_STATUS_OK;
}

OP_HELPER agc_status agc_op_same(agc_vm *vm, agc_value *dst, const agc_value *a, const agc_value *b) {
  int same = same_values(vm, a, b);
  if (same < 0) return AGC_STATUS_WRONG_TAG;
  *dst = agc_bool(same);
  return AGC_STATUS_OK;
}

OP_HELPER agc_status agc_op_list_len(agc_vm *vm, agc_value *dst, const agc_value *list) {
  if (!agc_is(*list, AGC_T_LIST)) return AGC_STATUS_WRONG_TAG;
  *dst = agc_int((int64_t)list_len(agc_as_list(vm, *list)));
  return AGC_STATUS_OK;
}

OP_HELPER agc_status agc_op_list_get(agc_vm *vm, agc_value *dst, const agc_value *list, const agc_value *index) {
  if (!agc_is(*list, AGC_T_LIST) || !agc_is(*index, AGC_T_INT)) return AGC_STATUS_WRONG_TAG;
  const agc_list *l = agc_as_list(vm, *list);
  int64_t x = agc_as_int(vm, *index);
  if (x < 0 || (uint64_t)x >= list_len(l)) return AGC_STATUS_INDEX_OUT_OF_RANGE;
  *dst = list_at(l, (size_t)x);
  return AGC_STATUS_OK;
}

/* CONCAT joins two Strings and charges the joined bytes, as the interpreter's case did; the caller applies the cost.
   Any other pair is hand-made bytecode (the checker keeps `+` to two Strings or two numbers), so it is WRONG_TAG and
   dst is left alone. The two String pointers are read before dst is written, so dst may be an operand. */
OP_HELPER agc_status agc_op_concat(agc_vm *vm, agc_value *dst, const agc_value *a, const agc_value *b) {
  if (!tags_are(a, b, AGC_T_STRING)) return AGC_STATUS_WRONG_TAG;
  const agc_string *x = agc_as_string(vm, *a), *y = agc_as_string(vm, *b);
  agc_string *joined = agc_concat(x, y);
  agc_charge_bytes(vm, joined->bytes);
  *dst = agc_string_value(joined);
  return AGC_STATUS_OK;
}

/* TO_TEXT prints any value through the checked text form, which charges a compound, String or Json form itself;
   the caller applies the cost. A Void at the top level or inside a list, map value, set, struct, enum or Result is
   hand-made bytecode (the checker rejects a Void value with CHECK-VOID-VALUE): the checked form reports it instead
   of failing, so the helper answers WRONG_TAG with dst left alone. Structs and enums come from loader-checked
   instructions, and a Json never holds a non-finite Float (JSON.parse and JSON.from refuse those), so on a loaded
   program the checked form fails for nothing else here. Unlike EQ, which answers shallow pairs without walking them
   (equal_values returns -1 past Ints, Floats, Nils, Strings, Ranges, Bools and Bytes), TO_TEXT walks and formats
   arbitrarily deep values; the check keeps that walk inside the helper's status contract. */
OP_HELPER agc_status agc_op_to_text(agc_vm *vm, agc_value *dst, const agc_value *v) {
  if (agc_is(*v, AGC_T_VOID)) return AGC_STATUS_WRONG_TAG;
  int64_t cost = vm->task->turn_cost;
  agc_string *text;
  if (!agc_text_checked(vm, *v, &text)) {
    /* The partial walk may have charged key re-hashes; a failing helper leaves the cost alone. */
    vm->task->turn_cost = cost;
    return AGC_STATUS_WRONG_TAG;
  }
  *dst = agc_string_value(text);
  return AGC_STATUS_OK;
}

static _Noreturn void index_out_of_range(agc_vm *vm, int64_t index, size_t len, uint32_t span) {
  char text[96];
  int n = snprintf(text, sizeof text, "index %" PRId64 " is outside a list of length %zu", index, len);
  char *message = agc_alloc_atomic((size_t)n + 1);
  memcpy(message, text, (size_t)n + 1);
  agc_fail(vm, "RUNTIME-INDEX-OUT-OF-RANGE", message, span);
}

__attribute__((noinline, cold)) _Noreturn void agc_op_fail(agc_vm *vm, agc_status status, const agc_value *a,
                                                            const agc_value *b, uint32_t span) {
  switch (status) {
    case AGC_STATUS_OVERFLOW:
      agc_fail(vm, "RUNTIME-INTEGER-OVERFLOW", "Int result is outside the 64-bit range", span);
    case AGC_STATUS_DIVISION_BY_ZERO: agc_fail(vm, "RUNTIME-DIVISION-BY-ZERO", "division by zero", span);
    case AGC_STATUS_INDEX_OUT_OF_RANGE:
      assert(a && b);
      index_out_of_range(vm, agc_as_int(vm, *b), list_len(agc_as_list(vm, *a)), span);
    case AGC_STATUS_WRONG_TAG: agc_wrong_tag(vm);
    case AGC_STATUS_OK:
    case AGC_STATUS_COUNT: break;
  }
  agc_fail(vm, "RUNTIME-INTERNAL", "an opcode helper failed with no error", span);
}

/* agc_op_fail for the running instruction of the interpreter, read back from the top frame (frame->pc is written
   before each instruction runs), so the hot loop passes only the status and keeps no operand live for the cold call.
   Only LIST_GET's status needs the operands. */
static __attribute__((noinline, cold)) _Noreturn void op_failed(agc_vm *vm, agc_status status) {
  const agc_task *t = vm->task;
  const agc_frame *frame = &t->frames[t->frame_count - 1];
  const agc_function *f = &vm->rt->program->functions[frame->function];
  agc_instr in = f->code[frame->pc - 1];
  const agc_value *R = t->regs + frame->base;
  bool operands = status == AGC_STATUS_INDEX_OUT_OF_RANGE;
  agc_op_fail(vm, status, operands ? &R[in.b] : NULL, operands ? &R[in.c] : NULL, f->spans[frame->pc - 1]);
}

static _Noreturn void key_not_found(agc_vm *vm, agc_value key, uint32_t span) {
  static const char before[] = "key ", after[] = " is not in the map";
  const agc_string *form = agc_debug(vm, key);
  size_t len = agc_size_add(agc_size_add(sizeof before - 1, form->bytes), sizeof after);
  char *message = agc_alloc_atomic(len);
  memcpy(message, before, sizeof before - 1);
  memcpy(message + sizeof before - 1, form->data, form->bytes);
  memcpy(message + sizeof before - 1 + form->bytes, after, sizeof after);
  agc_fail(vm, "RUNTIME-KEY-NOT-FOUND", message, span);
}

/* The turn ends in a wait (docs/vm/10-io-multicore.md §10.2.3). The state stays PARKING (or WOKEN): the scheduler
   decides about the cancel flag and the trace first, and then publishes PARKED with agc_task_commit_park (agc_task_end_turn
   reads the flag once more after it). */
static agc_turn_result park_task(agc_task *t) {
  t->parking = false;
  return AGC_TURN_PARKED;
}

/* The frame transition of a CALL, TAIL_CALL or CALL_VALUE exit of run_compiled at instruction OUT.pc of F, whose
   frame (at BASE) is on top: a CALL pushes the callee's frame as the interpreter's CALL does, and a CALL_VALUE (in
   vm/jit/jit.c, so that no code is added here) the frame of the function value as its CALL_VALUE does; a TAIL_CALL
   replaces the top frame (a natively called one too, as the exit unwound the native calls) as the interpreter's
   TAIL_CALL does, with no step, turn cost or depth. Each may grow the arrays or fail as it does there. Returns the
   callee. Out of line so that run_compiled keeps its size: the turn loops after it keep their addresses, and so
   --jit off its code layout. */
static __attribute__((noinline)) uint32_t call_exit(agc_vm *vm, agc_jit *jit, const agc_function *f, agc_jit_exit out,
                                                    uint32_t base) {
  if (out.status == AGC_JIT_EXIT_CALL_VALUE) return agc_jit_call_value_exit(vm, jit, f, out, base);
  agc_instr in = f->code[out.pc];
  uint32_t function = (uint32_t)in.b | ((uint32_t)in.c << 16);
  if (AGC_TRACE_ON(jit->trace, AGC_TRACE_JIT)) agc_jit_count_transition(jit);
  if (out.status == AGC_JIT_EXIT_TAIL_CALL)
    replace_frame(vm, function, in.a, f->spans[out.pc]);
  else
    call_instruction(vm, vm->task, function, base, in.a, f->spans[out.pc], false);
  return function;
}

/* Runs the top frame in compiled code (vm/jit/jit.h) when its function has some, from frame->pc, and handles the
   exits as the interpreter would handle the instruction at the exit's pc: a slow STEP runs step_slow, a turn cost is
   applied, and a failure is raised here, outside compiled code. An exit from a natively called function comes with
   that function's frame on top, which is the frame the exit is about from then on. CALL, TAIL_CALL, CALL_VALUE and
   RETURN use the shared frame handlers and go on in the code of the new top frame when it has code, else reload;
   other unsupported instructions return to the opcode switch at frame->pc, after a reload when the top frame is not
   FRAME any more (the reload enters the code at that instruction, which exits again at once). A block call (a builtin
   row with a native kind, such as `filter`) starts here too, as a leaf builtin is called here: its native frame calls
   the block, whose frames go on in the block's code, and each RETURN of the block resumes the native frame. A function
   that `on` compiled for native calls only is entered here only to resume it, or at its first instruction when a
   native frame called it (a block whose call began in a turn that ended). Only the jit copy of the turn loop calls
   it; nothing here changes that loop, whose plain copy's machine code follows every edit of it. */
static __attribute__((noinline)) AGC_JIT_CALLER compiled_result run_compiled(agc_vm *vm, agc_jit *jit,
                                                                             agc_frame *frame) {
  agc_task *t = vm->task;
  if (!frame->pc && agc_jit_native_only(jit, frame->function) && (frame == t->frames || !frame[-1].native))
    return COMPILED_NONE;
  agc_jit_code code = agc_jit_code_of(jit, frame->function, frame->pc);
  const agc_program *p = vm->rt->program;
  const agc_function *f = &p->functions[frame->function];
  if (!code || frame->pc >= f->count) return COMPILED_NONE;
  agc_frame *const entry = frame;
  agc_value *R = t->regs + frame->base;
  uint32_t pc = frame->pc, depth = t->frame_count;
  for (;;) {
    agc_jit_exit out = code(vm, R, p->constants, pc);
    if (__builtin_expect(t->frame_count != depth, 0) || frame->tail) {
      /* Native calls are on the frames, not on the C stack any more, and a native tail call (which sets the frame's
         tail flag) may have made the frame another function's: the exit is the top frame's, whose function was called
         or tail-called natively, so it has code. */
      depth = t->frame_count;
      frame = &t->frames[depth - 1];
      f = &p->functions[frame->function];
      R = t->regs + frame->base;
      code = atomic_load_explicit(&jit->code[frame->function], memory_order_acquire);
    }
    frame->pc = pc = out.pc + 1;
    switch (out.status) {
      case AGC_JIT_EXIT_STEP:
        step_slow(vm, f->code[out.pc].a, f->spans[out.pc]);
        if (vm->yield) return COMPILED_YIELD;
        break;
      case AGC_JIT_EXIT_COST:
        if (apply_cost(vm)) return COMPILED_YIELD;
        break;
      /* A builtin that compiled code called (agc_jit_call_builtin) returned and ended the turn, or failed: its
         failure, recorded with the stack of that moment, goes on to the turn's target from here. */
      case AGC_JIT_EXIT_YIELD: return COMPILED_YIELD;
      case AGC_JIT_EXIT_RAISE: unwind(vm);
      /* The callee's frame is on top (call_exit), and goes on in its code when it has some, else reloads. */
      case AGC_JIT_EXIT_CALL:
      case AGC_JIT_EXIT_TAIL_CALL:
      case AGC_JIT_EXIT_CALL_VALUE: {
        uint32_t function = call_exit(vm, jit, f, out, frame->base);
        code = agc_jit_callee_code(jit, function, false);
        if (!code) return COMPILED_RELOAD;
        pc = 0;
        break;
      }
      case AGC_JIT_EXIT_RETURN: {
        agc_instr in = f->code[out.pc];
        if (AGC_TRACE_ON(jit->trace, AGC_TRACE_JIT)) agc_jit_count_transition(jit);
        if (!return_instruction(vm, R[in.a])) return COMPILED_DONE;
        if (t->parking) return COMPILED_PARKED;
        if (vm->yield) return COMPILED_YIELD;
        /* The caller goes on in its code when it has some; a native frame or a caller without code reloads. */
        const agc_frame *top = &t->frames[t->frame_count - 1];
        code = top->native ? NULL : atomic_load_explicit(&jit->code[top->function], memory_order_acquire);
        if (!code || top->pc >= p->functions[top->function].count) return COMPILED_RELOAD;
        pc = top->pc;
        break;
      }
      case AGC_JIT_EXIT_INTERPRET: {
        /* A leaf builtin is called here, as the interpreter's CALL_BUILTIN calls it, and the code goes on after it:
           a leaf never parks, yields, charges cost or touches the frames, so nothing else of the turn loop runs. */
        agc_instr in = f->code[out.pc];
        uint32_t bx = (uint32_t)in.b | ((uint32_t)in.c << 16);
        const agc_builtin *b = in.op == AGC_OP_CALL_BUILTIN ? p->builtins[bx] : NULL;
        bool tracing = AGC_TRACE_ON(jit->trace, AGC_TRACE_JIT);
        if (b && b->leaf) {
          if (tracing) agc_jit_count_leaf(jit);
          R[in.a] = call_leaf(vm, b, R + in.a, f->spans[out.pc]);
          break;
        }
        /* A block call starts as the interpreter's CALL_BUILTIN starts it, with frame->pc already past the call (the
           stack trace and the return read it). Its native frame has called the block (the frame on top now, which goes
           on in its code when it has some), or, for no item, written the result and gone, and the code goes on after
           the call. The native frame counts the steps and the turn cost of each call of the block. */
        if (b && b->native) {
          if (tracing) agc_jit_count_block(jit);
          start_native(vm, b->native, frame->base + in.a, f->spans[out.pc]);
          if (vm->yield) return COMPILED_YIELD;
          if (t->frame_count == depth) break;
          const agc_frame *top = &t->frames[t->frame_count - 1];
          code = top->native ? NULL : agc_jit_callee_code(jit, top->function, true);
          if (!code) return COMPILED_RELOAD;
          /* No `top->pc >= count` test, unlike RETURN: the block's frame is new, at pc 0, and the loader rejects an
             empty function. */
          pc = top->pc;
          break;
        }
        frame->pc = out.pc;
        if (frame != entry) return COMPILED_RELOAD;
        if (tracing) agc_jit_count_exit(jit, frame->function, out.pc);
        return COMPILED_ONE;
      }
      default: op_failed(vm, (agc_status)out.status);
    }
    /* The top frame may have changed (a RETURN into a native frame may even push another one, and a block call
       pushes two or none), and new_frame and push_frame may have moved the frames and the register file. */
    depth = t->frame_count;
    frame = &t->frames[depth - 1];
    f = &p->functions[frame->function];
    R = t->regs + frame->base;
  }
}

/* The span of the running instruction, read only where a failure or a call needs it. */
#define SPAN spans[pc - 1]

/* An opcode helper's status turned into the failure of the running instruction (op_failed). */
#define CHECK(status)                                                                     \
  do {                                                                                    \
    agc_status status_ = (status);                                                        \
    if (__builtin_expect(status_ != AGC_STATUS_OK, 0)) op_failed(vm, status_);            \
  } while (0)
#define BINARY(helper) CHECK(helper(vm, &R[in.a], &R[in.b], &R[in.c]))
#define UNARY(helper) CHECK(helper(vm, &R[in.a], &R[in.b]))

/* The second instruction of a fused pair, fetched as the loop fetches one. */
#define FUSED_NEXT()                              \
  do {                                            \
    in = code[pc++];                              \
    bx = (uint32_t)in.b | ((uint32_t)in.c << 16); \
    frame->pc = pc;                               \
  } while (0)

/* The STEP half of a fused instruction (AGC_FUSED_STEP_*, written by the loader on a STEP whose next instruction has
   that opcode). It is STEP itself: the same fast path, and the same slow path, which may stop the run at the STEP's
   span or yield with frame->pc on the next instruction, before it runs, so the resumed task runs it alone. Then the
   next instruction is fetched as the loop would fetch it, and its case runs it with a direct jump instead of a second
   dispatch. */
#define FUSED_STEP()                        \
  do {                                      \
    if (vm->next_stop > in.a) {             \
      vm->next_stop -= in.a;                \
    } else {                                \
      step_slow(vm, in.a, SPAN);            \
      if (vm->yield) return AGC_TURN_YIELD; \
    }                                       \
    FUSED_NEXT();                           \
  } while (0)

/* The CONST half of a fused instruction (AGC_FUSED_CONST_*): the CONST's own write, kept because a later instruction
   may read the register, then the next instruction (an Int operator or a compare, which may read the constant there)
   fetched as above, so its failure has its own span and frame->pc. */
#define FUSED_CONST()                \
  do {                               \
    R[in.a] = p->constants[bx];      \
    FUSED_NEXT();                    \
  } while (0)

/* The turn loop keeps the state of the top frame in locals (its code, spans, register window and next pc) and
 * reloads them (`reload`) only after an instruction that can change which frame runs or move the frames or the
 * registers: CALL, CALL_VALUE, TAIL_CALL, RETURN, a failing TRY, and a builtin that starts a native frame. A
 * builtin that returns normally cannot move them: push_frame, replace_frame and new_frame are called only from this
 * file, on the task that runs, and a builtin never pushes a frame of the running task (Task.spawn pushes the
 * child's). frame->pc is still written before each instruction runs, as the stack trace of a failure, a park and a
 * yield read it. The plain copy, the profiling copy and the jit copy (--jit on or always; it enters compiled code at
 * each reload) are three copies of this loop, so the plain copy has no test of the JIT at all. */
static inline __attribute__((always_inline)) agc_turn_result turn_loop(agc_vm *vm, bool profiling, bool jitting) {
  const agc_program *p = vm->rt->program;
  agc_task *t = vm->task;
  if (t->frame_count == 0) return AGC_TURN_DONE;
  if (t->frames[t->frame_count - 1].native) {
    resume_native(vm);
    if (t->parking) return park_task(t);
    if (vm->yield) return AGC_TURN_YIELD;
  }
  agc_frame *frame;
  const agc_instr *code;
  const uint32_t *spans;
  agc_value *R;
  uint32_t base, pc;
  /* Only the profiling copy uses these; the plain copy drops them. */
  agc_profile *profile = profiling ? vm->profile : NULL;
  uint32_t before = AGC_OP_COUNT;
  /* Only the jit copy uses it: the pc after an instruction that compiled code left to the interpreter, where the loop
     enters the code again. An instruction that changes the frame reloads first, which clears it; one that jumps
     elsewhere leaves it unmet until the loop comes by. */
  uint32_t resume = UINT32_MAX;
reload:
  if (profiling) {
    profile->reloads++;
    before = AGC_OP_COUNT;
  }
  frame = &t->frames[t->frame_count - 1];
  if (jitting) {
    resume = UINT32_MAX;
    if (agc_jit_may_run(vm->rt->jit, frame->function)) {
      compiled_result ran = run_compiled(vm, vm->rt->jit, frame);
      if (ran == COMPILED_YIELD) return AGC_TURN_YIELD;
      if (ran == COMPILED_PARKED) return park_task(t);
      if (ran == COMPILED_DONE) return AGC_TURN_DONE;
      if (ran == COMPILED_RELOAD) goto reload;
      if (ran == COMPILED_ONE) resume = frame->pc + 1;
    }
  }
  code = p->functions[frame->function].code;
  spans = p->functions[frame->function].spans;
  base = frame->base;
  R = t->regs + base;
  pc = frame->pc;
  for (;;) {
    /* A stale resume is harmless: reload rebuilds code, spans, base, R and
       pc from the frame, so landing on this pc by another path just enters
       the code at the frame's instruction. */
    if (jitting && pc == resume) {
      frame->pc = pc;
      goto reload;
    }
    agc_instr in = code[pc];
    if (profiling) {
      /* The profiling copy runs a fused STEP as a plain STEP, and its next instruction as one of its own, so the
         opcode and pair counts describe the program's bytecode, the same with or without fusing. */
      if (in.op >= AGC_OP_COUNT && in.op < AGC_FUSED_END)
        in.op = in.op >= AGC_FUSED_CONST_FIRST ? AGC_OP_CONST : AGC_OP_STEP;
      profile_op(profile, &before, in.op);
    }
    uint32_t bx = (uint32_t)in.b | ((uint32_t)in.c << 16);
    pc++;
    frame->pc = pc;
    switch (in.op) {
      case AGC_OP_MOVE:
      op_move:
        R[in.a] = R[in.b];
        break;
      case AGC_OP_CONST:
      op_const:
        R[in.a] = p->constants[bx];
        break;
      case AGC_OP_GLOBAL:
      op_global: {
        /* The loader checked bx against global_count. A zeroed slot has tag AGC_T_VOID, and no module constant
           has type Void (docs/future/44-module-constants.md §44.5), so it means "never set": only a hand-made
           file reads one (or a slot it unset with GLOBAL_SET of a Void). */
        agc_value g = p->globals[bx];
        if (g.tag == AGC_T_VOID)
          agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: global read before it was set", SPAN);
        R[in.a] = g;
        break;
      }
      case AGC_OP_GLOBAL_SET:
        /* The one write to a loaded program. The loader allows it only in the entry function, which has no
           backward jump and cannot be called, so each GLOBAL_SET runs at most once, in the main task, before
           main. Later readers, on this thread or any other, see a table that is never written again
           (agc_program.globals). */
        p->globals[bx] = R[in.a];
        break;
      case AGC_OP_STEP:
        if (vm->next_stop > in.a) {
          vm->next_stop -= in.a;
          break;
        }
        step_slow(vm, in.a, SPAN);
        if (vm->yield) return AGC_TURN_YIELD;
        break;
      case AGC_FUSED_STEP_MOVE: FUSED_STEP(); goto op_move;
      case AGC_FUSED_STEP_CONST: FUSED_STEP(); goto op_const;
      case AGC_FUSED_STEP_FIELD: FUSED_STEP(); goto op_field;
      case AGC_FUSED_STEP_LIST_GET: FUSED_STEP(); goto op_list_get;
      case AGC_FUSED_STEP_IS_VARIANT: FUSED_STEP(); goto op_is_variant;
      case AGC_FUSED_STEP_GLOBAL: FUSED_STEP(); goto op_global;
      case AGC_FUSED_STEP_ARITH_I: FUSED_STEP(); goto op_arith_i;
      case AGC_FUSED_STEP_LT_I: FUSED_STEP(); goto op_lt_i;
      case AGC_FUSED_STEP_RETURN: FUSED_STEP(); goto op_return;
      case AGC_FUSED_STEP_CONST_ARITH_I: FUSED_STEP(); goto op_const_arith_i;
      case AGC_FUSED_STEP_CONST_DIV_I: FUSED_STEP(); goto op_const_div_i;
      case AGC_FUSED_STEP_CONST_MOD_I: FUSED_STEP(); goto op_const_mod_i;
      case AGC_FUSED_STEP_CONST_LT_I: FUSED_STEP(); goto op_const_lt_i;
      case AGC_FUSED_STEP_CONST_LE_I: FUSED_STEP(); goto op_const_le_i;
      case AGC_FUSED_STEP_CONST_EQ: FUSED_STEP(); goto op_const_eq;
      case AGC_FUSED_STEP_CONST_NE: FUSED_STEP(); goto op_const_ne;
      case AGC_FUSED_CONST_ARITH_I:
      op_const_arith_i:
        FUSED_CONST();
        goto op_arith_i;
      case AGC_FUSED_CONST_DIV_I:
      op_const_div_i:
        FUSED_CONST();
        goto op_div_i;
      case AGC_FUSED_CONST_MOD_I:
      op_const_mod_i:
        FUSED_CONST();
        goto op_mod_i;
      case AGC_FUSED_CONST_LT_I:
      op_const_lt_i:
        FUSED_CONST();
        goto op_lt_i;
      case AGC_FUSED_CONST_LE_I:
      op_const_le_i:
        FUSED_CONST();
        goto op_le_i;
      case AGC_FUSED_CONST_EQ:
      op_const_eq:
        FUSED_CONST();
        goto op_eq;
      case AGC_FUSED_CONST_NE:
      op_const_ne:
        FUSED_CONST();
        goto op_ne;
      case AGC_OP_ADD_I:
      case AGC_OP_SUB_I:
      case AGC_OP_MUL_I:
      op_arith_i: {
        if (in.op == AGC_OP_ADD_I)
          BINARY(agc_op_add_i);
        else if (in.op == AGC_OP_SUB_I)
          BINARY(agc_op_sub_i);
        else
          BINARY(agc_op_mul_i);
        break;
      }
      case AGC_OP_DIV_I:
      op_div_i:
        BINARY(agc_op_div_i);
        break;
      case AGC_OP_MOD_I:
      op_mod_i:
        BINARY(agc_op_mod_i);
        break;
      case AGC_OP_NEG_I:
        UNARY(agc_op_neg_i);
        break;
      case AGC_OP_ADD_F: BINARY(agc_op_add_f); break;
      case AGC_OP_SUB_F: BINARY(agc_op_sub_f); break;
      case AGC_OP_MUL_F: BINARY(agc_op_mul_f); break;
      case AGC_OP_DIV_F: BINARY(agc_op_div_f); break;
      case AGC_OP_NEG_F: UNARY(agc_op_neg_f); break;
      case AGC_OP_LT_F: BINARY(agc_op_lt_f); break;
      case AGC_OP_LE_F: BINARY(agc_op_le_f); break;
      case AGC_OP_CONCAT:
        BINARY(agc_op_concat);
        if (t->turn_cost && apply_cost(vm)) return AGC_TURN_YIELD;
        break;
      case AGC_OP_TO_TEXT:
        UNARY(agc_op_to_text);
        if (t->turn_cost && apply_cost(vm)) return AGC_TURN_YIELD;
        break;
      case AGC_OP_INSPECT:
        R[in.a] = agc_string_value(agc_debug(vm, R[in.b]));
        if (t->turn_cost && apply_cost(vm)) return AGC_TURN_YIELD;
        break;
      case AGC_OP_LIST:
        R[in.a] = in.c ? agc_list_value(agc_list_from_array(&R[in.b], in.c)) : vm->rt->empty_list;
        break;
      case AGC_OP_LIST_LEN: UNARY(agc_op_list_len); break;
      case AGC_OP_LIST_GET:
      op_list_get:
        BINARY(agc_op_list_get);
        break;
      case AGC_OP_MAP: {
        agc_map *m = agc_as_map(vm, vm->rt->empty_map);
        for (uint32_t k = 0; k < in.c; k++)
          m = agc_map_put(vm, m, R[(uint32_t)in.b + 2 * k], R[(uint32_t)in.b + 2 * k + 1]);
        R[in.a] = agc_map_value(m);
        if (t->turn_cost && apply_cost(vm)) return AGC_TURN_YIELD;
        break;
      }
      case AGC_OP_MAP_GET: {
        agc_value found;
        if (!agc_map_get(vm, agc_as_map(vm, R[in.b]), R[in.c], &found)) key_not_found(vm, R[in.c], SPAN);
        R[in.a] = found;
        if (t->turn_cost && apply_cost(vm)) return AGC_TURN_YIELD;
        break;
      }
      case AGC_OP_STRUCT: {
        uint32_t n = p->structs[in.c].count;
        agc_struct *st = agc_new_struct(in.c, n);
        for (uint32_t k = 0; k < n; k++) st->fields[k] = R[(uint32_t)in.b + k];
        R[in.a] = agc_struct_value(st);
        break;
      }
      case AGC_OP_STRUCT_WITH: {
        /* R[b] is the receiver and R[b+1..] the new values, in the order of
           the update's fields. The loader checked the field indexes against
           the struct's field count. Every C creator of a struct goes through
           agc_builtin_struct, so a receiver of the declared type has that
           count; the test below keeps the invariant at the write (as
           agc_struct_def_of does) so a field index can never leave the copy. */
        const agc_update_def *u = &p->updates[in.c];
        const agc_struct *old = agc_as_struct(vm, R[in.b]);
        if (old->type != u->type || old->n != p->structs[u->type].count)
          agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: struct update of another struct", 0);
        agc_struct *st = agc_new_struct(old->type, old->n);
        memcpy(st->fields, old->fields, (size_t)old->n * sizeof(agc_value));
        for (uint32_t k = 0; k < u->count; k++) st->fields[u->fields[k]] = R[(uint32_t)in.b + 1 + k];
        R[in.a] = agc_struct_value(st);
        /* The copy is linear in the field count (up to 65535), unlike a
           STRUCT whose fields the program wrote one by one, so it is charged
           by size as CONCAT is. */
        agc_charge_bytes(vm, (size_t)old->n * sizeof(agc_value));
        if (t->turn_cost && apply_cost(vm)) return AGC_TURN_YIELD;
        break;
      }
      case AGC_OP_FIELD:
      op_field: {
        const agc_struct *st = agc_as_struct(vm, R[in.b]);
        if (in.c >= st->n) agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: field index out of range", 0);
        R[in.a] = st->fields[in.c];
        break;
      }
      case AGC_OP_ENUM: {
        const agc_variant_def *v = &p->variants[in.c];
        if (v->arity == 0) {
          R[in.a] = agc_enum_value(v->shared);
          break;
        }
        agc_enum *e = agc_new_enum(in.c, v->arity);
        for (uint32_t k = 0; k < v->arity; k++) e->payload[k] = R[(uint32_t)in.b + k];
        R[in.a] = agc_enum_value(e);
        break;
      }
      case AGC_OP_IS_VARIANT:
      op_is_variant:
        R[in.a] = agc_bool(agc_as_enum(vm, R[in.b])->variant == in.c);
        break;
      case AGC_OP_PAYLOAD: {
        const agc_enum *e = agc_as_enum(vm, R[in.b]);
        if (in.c >= e->n) agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: payload index out of range", 0);
        R[in.a] = e->payload[in.c];
        break;
      }
      case AGC_OP_SAME:
        BINARY(agc_op_same);
        if (t->turn_cost && apply_cost(vm)) return AGC_TURN_YIELD;
        break;
      case AGC_OP_NOT: R[in.a] = agc_bool(!agc_as_bool(vm, R[in.b])); break;
      case AGC_OP_LT_I:
      op_lt_i:
        BINARY(agc_op_lt_i);
        break;
      case AGC_OP_LE_I:
      op_le_i:
        BINARY(agc_op_le_i);
        break;
      case AGC_OP_EQ:
      op_eq:
        BINARY(agc_op_eq);
        if (t->turn_cost && apply_cost(vm)) return AGC_TURN_YIELD;
        break;
      case AGC_OP_NE:
      op_ne:
        BINARY(agc_op_ne);
        if (t->turn_cost && apply_cost(vm)) return AGC_TURN_YIELD;
        break;
      case AGC_OP_JUMP: pc = bx; break;
      case AGC_OP_JUMP_IF_FALSE:
        if (!agc_as_bool(vm, R[in.a])) pc = bx;
        break;
      case AGC_OP_JUMP_IF_TRUE:
        if (agc_as_bool(vm, R[in.a])) pc = bx;
        break;
      case AGC_OP_CALL:
        call_instruction(vm, t, bx, base, in.a, SPAN, profiling);
        goto reload;
      case AGC_OP_CALL_VALUE: {
        uint32_t at = base + in.a;
        call_value(vm, t, R[in.a], at + 1, NULL, in.b, at, SPAN);
        goto reload;
      }
      case AGC_OP_CLOSURE: {
        uint32_t n = p->functions[bx].captures;
        agc_fn *f = agc_new_fn(bx, n);
        for (uint32_t k = 0; k < n; k++) f->captured[k] = R[(uint32_t)in.a + k];
        R[in.a] = agc_fn_value(f);
        break;
      }
      case AGC_OP_TAIL_CALL:
        if (profiling) profile_call(vm, bx);
        replace_frame(vm, bx, in.a, SPAN);
        goto reload;
      case AGC_OP_RANGE:
        R[in.a] = agc_range_value(agc_as_int(vm, R[in.b]), agc_as_int(vm, R[(uint32_t)in.b + 1]), in.c != 0);
        break;
      case AGC_OP_RANGE_BOUNDS: {
        int64_t first, last;
        bool more = agc_range_bounds(agc_as_range(vm, R[in.b]), &first, &last);
        R[in.a] = agc_int(first);
        R[(uint32_t)in.a + 1] = agc_int(last);
        R[(uint32_t)in.a + 2] = agc_bool(more);
        break;
      }
      case AGC_OP_CALL_BUILTIN: {
        agc_value *args = R + in.a;
        const agc_builtin *b = p->builtins[bx];
        if (b->leaf) {
          if (profiling) profile->builtin_leaf++;
          args[0] = profiling ? profile_builtin(vm, b, bx, args, SPAN, true) : call_leaf(vm, b, args, SPAN);
          break;
        }
        if (b->native) {
          if (profiling) profile_builtin_call(vm, bx);
          start_native(vm, b->native, base + in.a, SPAN);
          if (vm->yield) return AGC_TURN_YIELD;
          goto reload;
        }
        if (profiling) profile->builtin_tail++;
        uint64_t units = 0;
        if (b->cost == AGC_COST_SIZE)
          for (uint32_t k = 0; k < b->arity; k++) units += agc_value_units(args[k]);
        agc_value result = profiling ? profile_builtin(vm, b, bx, args, SPAN, false) : call_builtin(vm, b, args, SPAN);
        if (t->stepper) {
          start_stepper(vm, b, base + in.a, SPAN);
          if (t->parking) return park_task(t);
          if (vm->yield) return AGC_TURN_YIELD;
          goto reload;
        }
        if (t->parking) {
          if (t->retry) frame->pc = pc - 1;
          t->park_reg = base + in.a;
          return park_task(t);
        }
        args[0] = result;
        if (b->cost == AGC_COST_SIZE) agc_charge(vm, units + agc_value_units(result));
        if (t->turn_cost) apply_cost(vm);
        if (vm->yield) return AGC_TURN_YIELD;
        break;
      }
      case AGC_OP_RETURN:
      op_return:
        if (!return_instruction(vm, R[in.a])) return AGC_TURN_DONE;
        if (t->parking) return park_task(t);
        if (vm->yield) return AGC_TURN_YIELD;
        goto reload;
      case AGC_OP_TRY:
      case AGC_OP_TRY_STEP: {
        const agc_result *r = agc_as_result(vm, R[in.b]);
        if (r->ok) {
          R[in.a] = r->value;
        } else {
          if (in.op == AGC_OP_TRY_STEP)
            mark_escape(vm, t, SPAN);
          else if (t->frame_count == 1 && t == vm->rt->main)
            agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: try in the entry function", SPAN);
          if (!return_value(vm, R[in.b])) return AGC_TURN_DONE;
          if (t->parking) return park_task(t);
          if (vm->yield) return AGC_TURN_YIELD;
          goto reload;
        }
        break;
      }
      case AGC_OP_IS_OK: R[in.a] = agc_bool(agc_as_result(vm, R[in.b])->ok); break;
      case AGC_OP_RESULT_VALUE: R[in.a] = agc_as_result(vm, R[in.b])->value; break;
      default: agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: unknown opcode", 0);
    }
  }
}

#undef UNARY
#undef BINARY
#undef CHECK
#undef FUSED_CONST
#undef FUSED_STEP
#undef FUSED_NEXT
#undef SPAN

/* The three copies of the turn loop are functions of their own: the compiler lays out blocks and allocates registers
   for each function apart, so a change to the JIT's copy, or to the choice in agc_run_turn, does not reshape the plain
   one. With the three copies in agc_run_turn, a change to the jit copy alone made case 7% slower with --jit off, and
   with the plain copy inline there, one more test before it changed a third of its instructions. */
static __attribute__((noinline)) agc_turn_result jit_turn(agc_vm *vm) { return turn_loop(vm, false, true); }
static __attribute__((noinline)) agc_turn_result profile_turn(agc_vm *vm) { return turn_loop(vm, true, false); }
static __attribute__((noinline)) agc_turn_result plain_turn(agc_vm *vm) { return turn_loop(vm, false, false); }

/* The profile counts the bytecode's instructions, so a profiled run never runs compiled code. A run with a JIT runs
   the plain copy, the one of --jit off, for the turns agc_jit_turn turns down while no code is published. */
agc_turn_result agc_run_turn(agc_vm *vm) {
  if (AGC_PROFILE_ON(vm)) return profile_turn(vm);
  if (vm->rt->jit && agc_jit_turn(vm->rt->jit, vm)) return jit_turn(vm);
  return plain_turn(vm);
}

/* True when the RETURN of RESULT by the block frame of FUNCTION into the native frame ST below it only makes ST call
   the block again, with the same function value: resume_native would neither end the call nor fail, take a slow step
   or park. So the block's value decides nothing yet (a Bool for filter, any? and all?, and not the one that ends any?
   or all?), an item is left, and a counting call (times, upto, downto, each of a Range) has its step on the fast
   path. A stepper is never one: its step may lock, park or name another function. */
static bool block_goes_on(agc_vm *vm, const agc_native *st, agc_value result, uint32_t function) {
  /* The tag tests keep agc_as_fn and agc_as_bool from failing here, under compiled code. */
  if (!agc_is(st->fn, AGC_T_FN) || agc_as_fn(vm, st->fn)->function != function) return false;
  /* Only the kinds handled by agc_jit_block_return: a kind added later takes the RETURN exit until it is. */
  switch (st->kind) {
    case AGC_NATIVE_RANGE_EACH:
    case AGC_NATIVE_TIMES:
    case AGC_NATIVE_UPTO:
    case AGC_NATIVE_DOWNTO: return st->more && vm->next_stop > 1;
    case AGC_NATIVE_FILTER:
      if (!agc_is(result, AGC_T_BOOL)) return false;
      break;
    case AGC_NATIVE_ANY:
      if (!agc_is(result, AGC_T_BOOL) || agc_as_bool(vm, result)) return false;
      break;
    case AGC_NATIVE_ALL:
      if (!agc_is(result, AGC_T_BOOL) || !agc_as_bool(vm, result)) return false;
      break;
    case AGC_NATIVE_MAP:
    case AGC_NATIVE_SORT_BY:
    case AGC_NATIVE_REDUCE:
    case AGC_NATIVE_EACH: break;
    default: return false;
  }
  return st->items.index < agc_list_len(st->items.list);
}

/* The RETURN of RESULT at no native depth in compiled code (vm/jit/jit.h) when the frame below is the native frame of a
   block call that calls the block again (block_goes_on). It does what the interpreter's RETURN does there
   (return_value, then resume_native and its call_value) in place: the next call's frame would take the same slot with
   the same function, base, ret and depth, and its registers fit already (the first call grew them), so the frame
   starts over at instruction 0 with the next arguments and the captures of the function value in its registers.
   Nothing here can fail: call_value's checks passed for the same function value and argument count at the first
   call, and compiled code never runs with the profile on. A counting call takes its step on the fast path; a list
   call charges the turn cost of a call, which may end the turn. Returns the frame's registers, for the code to go on
   at instruction 0 (or at AGC_JIT_PC_RESTART's YIELD exit), or NULL with nothing done, for the RETURN exit. Below plain_turn and out of line, so the turn
   loops keep their code. */
__attribute__((noinline)) agc_value *agc_jit_block_return(agc_vm *vm, const agc_value *result) {
  agc_task *t = vm->task;
  uint32_t n = t->frame_count;
  if (n < 2 || !t->frames[n - 2].native) return NULL;
  agc_frame *frame = &t->frames[n - 1];
  /* A frame that a native tail call reached runs another function's code than the one run_compiled entered, and
     run_compiled reloads that code after an exit only while the tail flag is set, which this would clear. */
  if (frame->tail) return NULL;
  agc_native *st = t->frames[n - 2].native;
  /* Read first: RESULT may be one of the registers that the next arguments overwrite. */
  agc_value got = *result;
  if (!block_goes_on(vm, st, got, frame->function)) return NULL;
  t->regs[frame->ret] = got;
  agc_value *R = t->regs + frame->base;
  uint32_t argc = 0;
  if (counting(st->kind)) {
    vm->next_stop--;
    R[argc++] = agc_int(st->cur);
    st->more = st->cur != st->last;
    if (st->more) st->cur += st->dir;
  } else {
    if (st->kind == AGC_NATIVE_MAP || st->kind == AGC_NATIVE_SORT_BY)
      agc_list_builder_push(&st->out, got);
    else if (st->kind == AGC_NATIVE_FILTER && agc_as_bool(vm, got))
      st->kept[st->count++] = st->item;
    else if (st->kind == AGC_NATIVE_REDUCE)
      st->acc = got;
    agc_list_cursor_next(&st->items, &st->item);
    if (st->kind == AGC_NATIVE_REDUCE) R[argc++] = st->acc;
    R[argc++] = st->item;
  }
  const agc_fn *fn = agc_as_fn(vm, st->fn);
  if (fn->n) memcpy(R + argc, fn->captured, (size_t)fn->n * sizeof(agc_value));
  frame->pc = 0;
  /* As push_frame leaves it (the flag is clear already: see above); stack traces read it. */
  frame->tail = false;
  if (!counting(st->kind)) {
    t->turn_cost++;
    apply_cost(vm);
  }
  return R;
}
