#include "core.h"

#include <inttypes.h>
#include <string.h>

static void enqueue(agc_vm *vm, agc_task *t) {
  t->state = AGC_TASK_READY;
  t->next = NULL;
  if (vm->ready_tail)
    vm->ready_tail->next = t;
  else
    vm->ready = t;
  vm->ready_tail = t;
}

static agc_task *dequeue(agc_vm *vm) {
  agc_task *t = vm->ready;
  if (!t) return NULL;
  vm->ready = t->next;
  if (!vm->ready) vm->ready_tail = NULL;
  t->next = NULL;
  return t;
}

void agc_task_wake(agc_vm *vm, agc_task *t, const char *by) {
  if (t->state != AGC_TASK_PARKED) return;
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "wake task=%" PRIu64 " by=%s", t->id, by);
  enqueue(vm, t);
}

void agc_task_enqueue(agc_task **head, agc_task **tail, agc_task *t) {
  t->wait_next = NULL;
  if (*tail)
    (*tail)->wait_next = t;
  else
    *head = t;
  *tail = t;
}

void agc_task_wake_all(agc_vm *vm, agc_task **head, agc_task **tail, const char *by) {
  agc_task *t = *head;
  *head = *tail = NULL;
  while (t) {
    agc_task *next = t->wait_next;
    t->wait_next = NULL;
    agc_task_wake(vm, t, by);
    t = next;
  }
}

void agc_task_remove(agc_task **head, agc_task **tail, const agc_task *t) {
  agc_task *previous = NULL;
  for (agc_task *k = *head; k; previous = k, k = k->wait_next) {
    if (k != t) continue;
    if (previous)
      previous->wait_next = k->wait_next;
    else
      *head = k->wait_next;
    if (*tail == k) *tail = previous;
    k->wait_next = NULL;
    return;
  }
}

void agc_task_park(agc_vm *vm, bool retry) {
  vm->task->parking = true;
  vm->task->retry = retry;
}

void agc_task_stepper(agc_vm *vm, agc_stepper *stepper) { vm->task->stepper = stepper; }

static void adopt(agc_task *parent, agc_task *child) {
  child->parent = parent;
  child->prev_sibling = NULL;
  child->next_sibling = parent->children;
  if (parent->children) parent->children->prev_sibling = child;
  parent->children = child;
}

static void leave_parent(agc_task *t) {
  if (t->prev_sibling)
    t->prev_sibling->next_sibling = t->next_sibling;
  else if (t->parent)
    t->parent->children = t->next_sibling;
  if (t->next_sibling) t->next_sibling->prev_sibling = t->prev_sibling;
  t->parent = t->prev_sibling = t->next_sibling = NULL;
}

void agc_task_close_done(agc_vm *vm, agc_task *t) {
  if (--t->closing == 0) agc_task_wake_all(vm, &t->waiters, &t->waiters_tail, "await");
}

static void finish_task(agc_vm *vm, agc_task *t) {
  t->left_children = t->children != NULL;
  agc_close_owned(vm, t);
  t->state = AGC_TASK_DONE;
  t->regs = NULL;
  t->reg_capacity = 0;
  t->frames = NULL;
  t->frame_capacity = 0;
  t->cursor = NULL;
  t->turn_cost = 0;
  if (!t->group) vm->tasks_done++;
  while (t->children) {
    agc_task *child = t->children;
    leave_parent(child);
    if (t->parent) adopt(t->parent, child);
  }
  leave_parent(t);
  if (!t->closing) agc_task_wake_all(vm, &t->waiters, &t->waiters_tail, "await");
  agc_end_fn end = t->end;
  t->end = NULL;
  if (end) end(vm, t);
}

static void leave_ready(agc_vm *vm, const agc_task *t) {
  agc_task *previous = NULL;
  for (agc_task *k = vm->ready; k; previous = k, k = k->next) {
    if (k != t) continue;
    if (previous)
      previous->next = k->next;
    else
      vm->ready = k->next;
    if (vm->ready_tail == k) vm->ready_tail = previous;
    k->next = NULL;
    return;
  }
}

static void unlink_task(agc_vm *vm, agc_task *t) {
  if (t->state == AGC_TASK_READY) leave_ready(vm, t);
  if (t->parked) agc_io_detach(vm, t);
  if (t->lock_wait) agc_handle_leave(vm, t);
  if (t->channel.channel) agc_channel_leave(vm, t);
  if (t->output.out) agc_output_leave(vm, t);
  if (t->awaiting) agc_task_remove(&t->awaiting->waiters, &t->awaiting->waiters_tail, t);
  t->awaiting = NULL;
  agc_task_remove(&vm->rt->in.waiters, &vm->rt->in.waiters_tail, t);
  t->parking = t->retry = false;
}

static void end_cancelled(agc_vm *vm, agc_task *t) {
  unlink_task(vm, t);
  finish_task(vm, t);
}

static void cancel_one(agc_vm *vm, agc_task *t) {
  t->cancelled = true;
  if (!t->group) AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "cancel task=%" PRIu64, t->id);
  if (t->state == AGC_TASK_RUNNING)
    vm->yield = true;
  else
    end_cancelled(vm, t);
}

/* Children before parents, so each cancelled task has no live child left
   to move; a running task only gets its flag and ends after its builtin. */
void agc_task_cancel(agc_vm *vm, agc_task *root) {
  if (root == vm->main || root->state == AGC_TASK_DONE || root->cancelled) return;
  agc_task *t = root;
  uint64_t count = 0;
  for (;;) {
    agc_task *child = t->children;
    while (child && child->cancelled) child = child->next_sibling;
    if (child) {
      t = child;
      continue;
    }
    agc_task *up = t->parent;
    cancel_one(vm, t);
    count++;
    if (t == root) break;
    t = up;
  }
  if (vm->task && vm->task->state == AGC_TASK_RUNNING) agc_charge(vm, count);
}

static void resume(agc_vm *vm, agc_task *t) {
  if (t->parked) {
    agc_value result = agc_io_finish(vm, t);
    if (!t->retry) t->regs[t->park_reg] = result;
  }
  t->retry = false;
}

static void trace_spawn(const agc_vm *vm, const agc_task *t, const agc_task *parent) {
  const agc_trace *tr = &vm->rt->trace;
  if (!AGC_TRACE_ON(tr, AGC_TRACE_SCHED) || !t->frame_count) return;
  const agc_string *name = vm->rt->program->functions[t->frames[0].function].name;
  if (parent && parent->group)
    AGC_TRACE(tr, AGC_TRACE_SCHED, "spawn task=%" PRIu64 " parent=group:%" PRIu64 " fn=%.*s", t->id,
              parent->parent ? parent->parent->id : 0, agc_trace_len(name->bytes), name->data);
  else
    AGC_TRACE(tr, AGC_TRACE_SCHED, "spawn task=%" PRIu64 " parent=%" PRIu64 " fn=%.*s", t->id, parent ? parent->id : 0,
              agc_trace_len(name->bytes), name->data);
}

static void trace_turn(const agc_vm *vm, const agc_task *t, agc_turn_result r, bool ran) {
  const agc_trace *tr = &vm->rt->trace;
  if (!AGC_TRACE_ON(tr, AGC_TRACE_SCHED)) return;
  int64_t used = 0;
  if (__builtin_sub_overflow((int64_t)AGC_TURN_STEPS, vm->turn_left, &used) ||
      __builtin_sub_overflow(used, vm->turn_cost_used, &used) || used < 0)
    used = 0;
  const char *why = !ran ? "fail" : r == AGC_TURN_DONE ? "done" : r == AGC_TURN_PARKED ? "park" : "yield";
  AGC_TRACE(tr, AGC_TRACE_SCHED, "turn task=%" PRIu64 " steps=%" PRId64 " cost=%" PRId64 " why=%s", t->id, used,
            vm->turn_cost_used, why);
}

static void trace_gc(agc_vm *vm, const char *when) {
  const agc_trace *tr = &vm->rt->trace;
  agc_gc_info info;
  if (!AGC_TRACE_ON(tr, AGC_TRACE_GC) || !agc_gc_stats(&info) || info.collections == vm->gc_seen) return;
  vm->gc_seen = info.collections;
  AGC_TRACE(tr, AGC_TRACE_GC,
            "collect at=%s count=%" PRIu64 " heap=%" PRIu64 " free=%" PRIu64 " since=%" PRIu64, when,
            info.collections, info.heap, info.free, info.since);
}

static void trace_end(agc_vm *vm) {
  const agc_trace *tr = &vm->rt->trace;
  const agc_outcome *o = &vm->rt->outcome;
  uint64_t task = vm->task && vm->task->state == AGC_TASK_RUNNING ? vm->task->id : 0;
  if (o->kind == AGC_FAILED)
    AGC_TRACE(tr, AGC_TRACE_SCHED, "fail task=%" PRIu64 " code=%s", task, o->code);
  else if (o->kind == AGC_EXITED)
    AGC_TRACE(tr, AGC_TRACE_SCHED, "exit task=%" PRIu64 " code=%" PRId64, task, o->exit_code);
  trace_gc(vm, "end");
}

static uint64_t pending_tasks(const agc_vm *vm) {
  uint64_t made = atomic_load(&vm->rt->next_task_id) - 1;
  return made > vm->tasks_done + 1 ? made - vm->tasks_done - 1 : 0;
}

/* No await can observe a hidden task (an HTTP connection task), so of its
   unobserved crashes only the first per test is kept; the others are
   counted on it, which bounds the list in a long-running server. */
static agc_task **quiet_slot(agc_vm *vm, const agc_task *t) {
  if (!t->hidden) return NULL;
  return t->test ? &t->test->quiet : &vm->quiet;
}

/* Runs under the run-level target: a failure here ends the run. */
static void crash(agc_vm *vm, agc_task *t) {
  agc_outcome *o = &vm->rt->outcome;
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "crash task=%" PRIu64 " code=%s", t->id, o->code);
  t->crash = agc_crash_text(vm->rt->program, o);
  t->crash_code = o->code;
  t->crash_message = agc_utf8_decode((const uint8_t *)o->message, o->message_len, "\xEF\xBF\xBD", false);
  t->crash_span = o->span;
  t->crashed = true;
  vm->crash_count++;
  agc_task **quiet = quiet_slot(vm, t);
  if (quiet && *quiet) {
    (*quiet)->quiet_more++;
  } else {
    if (quiet) *quiet = t;
    t->crash_prev = vm->crashes_tail;
    if (vm->crashes_tail)
      vm->crashes_tail->crash_next = t;
    else
      vm->crashes = t;
    vm->crashes_tail = t;
  }
  agc_notice notice;
  agc_print_diagnostic(agc_notice_begin(&vm->rt->err, &notice), vm->rt->program, o, vm->rt->style, true);
  agc_notice_end(&notice, AGC_NOTICE_QUEUED);
  o->kind = AGC_DONE;
  unlink_task(vm, t);
  for (agc_task *child = t->children, *next; child; child = next) {
    next = child->next_sibling;
    agc_task_cancel(vm, child);
  }
  finish_task(vm, t);
}

static bool fatal(const agc_vm *vm, const agc_task *t) {
  const agc_outcome *o = &vm->rt->outcome;
  return t == vm->main || o->kind != AGC_FAILED || strcmp(o->code, "RUNTIME-STEP-LIMIT") == 0 ||
         strcmp(o->code, "RUNTIME-INTERNAL") == 0;
}

static bool run_turn(agc_vm *vm, agc_task *t, agc_turn_result *r) {
  if (setjmp(vm->turn)) {
    vm->in_turn = false;
    return false;
  }
  vm->in_turn = true;
  resume(vm, t);
  *r = agc_turn_charge(vm) ? AGC_TURN_YIELD : agc_run_turn(vm);
  vm->in_turn = false;
  return true;
}

static agc_task *first_unobserved(const agc_vm *vm) {
  for (agc_task *t = vm->crashes; t; t = t->crash_next)
    if (!t->observed) return t;
  return NULL;
}

bool agc_report_unobserved(agc_vm *vm) {
  const agc_task *first = first_unobserved(vm);
  if (!first) return false;
  agc_notice notice;
  agc_print_unobserved(agc_notice_begin(&vm->rt->err, &notice), vm->crash_count - vm->observed_count, first->crash,
                       vm->rt->style);
  agc_notice_end(&notice, AGC_NOTICE_QUEUED);
  return true;
}

void agc_task_observe(agc_vm *vm, agc_task *t) {
  if (t->observed) return;
  t->observed = true;
  vm->observed_count += 1 + t->quiet_more;
  agc_task **quiet = quiet_slot(vm, t);
  if (quiet && *quiet == t) *quiet = NULL;
  if (t->crash_prev)
    t->crash_prev->crash_next = t->crash_next;
  else if (vm->crashes == t)
    vm->crashes = t->crash_next;
  if (t->crash_next)
    t->crash_next->crash_prev = t->crash_prev;
  else if (vm->crashes_tail == t)
    vm->crashes_tail = t->crash_prev;
  t->crash_next = t->crash_prev = NULL;
}

/* A stop signal ends the run between turns as an exit with 128 + signal;
   vm/main.c then raises it again after the exit path. */
static void check_stop(agc_vm *vm) {
  int sig = agc_io_stop_signal();
  if (sig) agc_stop(vm, sig);
}

agc_outcome agc_vm_run(agc_vm *vm) {
  if (setjmp(vm->fail) == 0) {
    agc_task_enter(vm, vm->main, vm->rt->program->entry);
    trace_spawn(vm, vm->main, NULL);
    enqueue(vm, vm->main);
    for (;;) {
      agc_task *t = dequeue(vm);
      if (!t) {
        check_stop(vm);
        if (!agc_io_poll(vm, true)) {
          check_stop(vm);
          AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "stall pending=%" PRIu64, pending_tasks(vm) + 1);
          agc_fail(vm, "RUNTIME-INTERNAL", "every task is waiting and nothing can wake them", 0);
        }
        continue;
      }
      vm->task = t;
      t->state = AGC_TASK_RUNNING;
      agc_turn_begin(vm);
      agc_turn_result r = AGC_TURN_DONE;
      bool ran = run_turn(vm, t, &r);
      agc_turn_finish(vm);
      trace_turn(vm, t, r, ran);
      trace_gc(vm, "turn");
      if (!ran) {
        if (fatal(vm, t)) longjmp(vm->fail, 1);
        crash(vm, t);
      } else if (t->cancelled) {
        end_cancelled(vm, t);
      } else if (r == AGC_TURN_DONE) {
        if (t == vm->main) {
          AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "cancel pending=%" PRIu64, pending_tasks(vm));
          break;
        }
        finish_task(vm, t);
      } else if (r == AGC_TURN_YIELD) {
        enqueue(vm, t);
      }
      agc_io_poll(vm, false);
      check_stop(vm);
    }
    vm->rt->outcome.kind = AGC_DONE;
    if (agc_report_unobserved(vm)) {
      vm->rt->outcome.kind = AGC_EXITED;
      vm->rt->outcome.exit_code = 1;
    }
  }
  trace_end(vm);
  return vm->rt->outcome;
}

agc_task *agc_task_spawn_in(agc_vm *vm, agc_task *parent, agc_value fn, const agc_value *args, uint32_t argc,
                            uint32_t span) {
  agc_task *child = agc_new_task(vm);
  child->input_seen = vm->rt->in.eof_seq;
  child->test = vm->task->test;
  agc_task_call(vm, child, fn, args, argc, span);
  adopt(parent, child);
  trace_spawn(vm, child, parent);
  enqueue(vm, child);
  return child;
}

agc_task *agc_task_spawn(agc_vm *vm, agc_value fn, const agc_value *args, uint32_t argc, uint32_t span) {
  return agc_task_spawn_in(vm, vm->task, fn, args, argc, span);
}

/* A node of the task tree that never runs: the parent of an HTTP server's
   connection tasks, so cancelling it reaches every one of them and their
   descendants. It has no id and is not counted as a task. */
agc_task *agc_task_group(agc_vm *vm) {
  agc_task *g = agc_alloc(sizeof(agc_task));
  g->group = true;
  g->state = AGC_TASK_PARKED;
  g->result = agc_void();
  g->test = vm->task->test;
  adopt(vm->task, g);
  return g;
}

agc_task *agc_task_spawn_seeded(agc_vm *vm, agc_task *parent, agc_value fn, const agc_value *args, uint32_t argc,
                                uint32_t span) {
  uint64_t seed = agc_random_next(&vm->task->random);
  agc_task *child = agc_task_spawn_in(vm, parent, fn, args, argc, span);
  agc_random_seed(&child->random, seed);
  return child;
}

static agc_resource *owned_by_caller(agc_vm *vm, agc_value handle) {
  agc_resource *r = agc_owned_of(vm, handle);
  return r && r->owner == vm->task ? r : NULL;
}

bool agc_task_owns(agc_vm *vm, agc_value handle) { return owned_by_caller(vm, handle) != NULL; }

agc_task *agc_task_spawn_owning(agc_vm *vm, agc_task *parent, agc_value fn, agc_value handle, uint32_t span) {
  agc_resource *r = agc_is(handle, AGC_T_CHANNEL) ? agc_channel_claim(vm, agc_as_channel(vm, handle))
                                                  : owned_by_caller(vm, handle);
  if (!r)
    agc_fail(vm, "RUNTIME-HANDLE-NOT-OWNED", "the calling task does not own this handle, or it is closed", span + 2);
  agc_task *child = agc_task_spawn_seeded(vm, parent, fn, &handle, 1, span);
  agc_hand_over(r, child);
  return child;
}

static agc_value builtin_spawn(agc_vm *vm, agc_value *args, uint32_t span) {
  return agc_task_value(agc_task_spawn_seeded(vm, vm->task, args[0], &args[1], 1, span));
}

static agc_value builtin_spawn_owning(agc_vm *vm, agc_value *args, uint32_t span) {
  return agc_task_value(agc_task_spawn_owning(vm, vm->task, args[0], args[1], span));
}

bool agc_task_join(agc_vm *vm, agc_task *target) {
  vm->task->awaiting = NULL;
  if (target->state == AGC_TASK_DONE && !target->closing) return false;
  vm->task->awaiting = target;
  agc_task_enqueue(&target->waiters, &target->waiters_tail, vm->task);
  agc_task_park(vm, true);
  return true;
}

/* A timed waiter holds a timer and ends by itself, so it is not an edge of the chain. */
static bool awaits_caller(agc_vm *vm, const agc_task *target) {
  uint64_t hops = 0;
  const agc_task *t = target;
  while (t && t != vm->task) {
    t = t->await_deadline ? NULL : t->awaiting;
    hops++;
  }
  agc_charge(vm, hops);
  return t != NULL;
}

static agc_value outcome(agc_vm *vm, agc_task *target, uint32_t span, bool result) {
  if (target->crashed) {
    agc_task_observe(vm, target);
    if (result) return agc_result_value(false, agc_string_value(target->crash));
    agc_fail_text(vm, "RUNTIME-TASK-CRASHED", target->crash, span);
  }
  if (target->cancelled) {
    if (result) return agc_error_value("task: cancelled");
    agc_fail(vm, "RUNTIME-TASK-CANCELLED", "task was cancelled", span);
  }
  return target->result;
}

static agc_value await_task(agc_vm *vm, agc_value task, uint32_t span, bool result) {
  agc_task *target = agc_as_task(vm, task);
  if (target->state != AGC_TASK_DONE && awaits_caller(vm, target))
    agc_fail(vm, "RUNTIME-TASK-AWAIT-CYCLE", "this await would wait for a task that is waiting for this task", span);
  if (agc_task_join(vm, target)) return agc_void();
  return outcome(vm, target, span, result);
}

static agc_runtime *await_variants(agc_vm *vm) {
  agc_runtime *rt = vm->rt;
  if (!rt->await_found) {
    rt->await_done = agc_builtin_variant(vm, "Await", "Done", 1);
    rt->await_timed_out = agc_builtin_variant(vm, "Await", "TimedOut", 0);
    rt->await_found = true;
  }
  return rt;
}

static agc_value await_done(agc_vm *vm, agc_value value) {
  agc_enum *e = agc_new_enum(await_variants(vm)->await_done, 1);
  e->payload[0] = value;
  return agc_enum_value(e);
}

static agc_value await_timed_out(agc_vm *vm) {
  return agc_enum_value(vm->rt->program->variants[await_variants(vm)->await_timed_out].shared);
}

static void leave_target(agc_task *t) {
  if (!t->awaiting) return;
  agc_task_remove(&t->awaiting->waiters, &t->awaiting->waiters_tail, t);
  t->awaiting = NULL;
}

static agc_value await_timeout(agc_vm *vm, agc_value *args, uint32_t span, bool result) {
  agc_task *target = agc_as_task(vm, args[0]);
  int64_t timeout = agc_as_int(vm, args[1]);
  if (timeout <= 0) agc_fail(vm, "RUNTIME-INVALID-DURATION", "await timeout must be positive milliseconds", span + 2);
  agc_task *t = vm->task;
  leave_target(t);
  if (target->state == AGC_TASK_DONE && !target->closing) {
    t->await_deadline = 0;
    return await_done(vm, outcome(vm, target, span, result));
  }
  uint64_t now = agc_io_now(vm);
  if (!t->await_deadline) t->await_deadline = now + (uint64_t)timeout;
  if (t->await_deadline <= now) {
    t->await_deadline = 0;
    return await_timed_out(vm);
  }
  t->awaiting = target;
  agc_task_enqueue(&target->waiters, &target->waiters_tail, t);
  agc_io_start(vm, &agc_wait_io, NULL, agc_void(), (int64_t)(t->await_deadline - now));
  agc_task_park(vm, true);
  return agc_void();
}

static agc_value builtin_await(agc_vm *vm, agc_value *args, uint32_t span) {
  return await_task(vm, args[0], span, false);
}

static agc_value builtin_await_result(agc_vm *vm, agc_value *args, uint32_t span) {
  return await_task(vm, args[0], span, true);
}

static agc_value builtin_await_timeout(agc_vm *vm, agc_value *args, uint32_t span) {
  return await_timeout(vm, args, span, false);
}

static agc_value builtin_await_timeout_result(agc_vm *vm, agc_value *args, uint32_t span) {
  return await_timeout(vm, args, span, true);
}

static agc_value slept(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)data;
  (void)context;
  return agc_void();
}

static const agc_io_kind sleep_io = {NULL, slept, slept, NULL, false, "sleep", NULL};

static agc_value builtin_sleep(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t ms = agc_as_int(vm, args[0]);
  if (ms < 0) agc_fail(vm, "RUNTIME-INVALID-DURATION", "sleep duration must be nonnegative", span + 1);
  if (ms == 0 || vm->rt->no_files) {
    vm->yield = true;
    return agc_void();
  }
  agc_io_start(vm, &sleep_io, NULL, agc_void(), ms);
  return agc_void();
}

static agc_value builtin_pending_count(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  return agc_int((int64_t)pending_tasks(vm));
}

static agc_value builtin_unobserved_crash(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  const agc_task *t = first_unobserved(vm);
  if (!t) return agc_error_value("no unobserved crash");
  return agc_result_value(true, agc_string_value(t->crash));
}

const agc_builtin agc_task_builtins[] = {
  {"Task.spawn", 2, builtin_spawn, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Task.await", 1, builtin_await, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Task.await", 2, builtin_await_timeout, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Task.sleep", 1, builtin_sleep, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Task.pending_count", 0, builtin_pending_count, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Task.await_result", 1, builtin_await_result, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Task.await_result", 2, builtin_await_timeout_result, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Task.unobserved_crash", 0, builtin_unobserved_crash, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Task.spawn_owning", 2, builtin_spawn_owning, AGC_NATIVE_NONE, AGC_COST_NONE},
};

const size_t agc_task_builtin_count = sizeof agc_task_builtins / sizeof agc_task_builtins[0];
