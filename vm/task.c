#include "agc.h"

#include <inttypes.h>

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

static void finish_task(agc_vm *vm, agc_task *t) {
  t->state = AGC_TASK_DONE;
  t->regs = NULL;
  t->reg_capacity = 0;
  t->frames = NULL;
  t->frame_capacity = 0;
  t->cursor = NULL;
  vm->tasks_done++;
  agc_task_wake_all(vm, &t->waiters, &t->waiters_tail, "await");
}

static void resume(agc_vm *vm, agc_task *t) {
  if (t->parked) {
    agc_value result = agc_io_finish(vm, t);
    if (!t->retry) t->regs[t->park_reg] = result;
  }
  t->retry = false;
}

static void trace_spawn(const agc_vm *vm, const agc_task *t, uint64_t parent) {
  const agc_trace *tr = &vm->rt->trace;
  if (!AGC_TRACE_ON(tr, AGC_TRACE_SCHED) || !t->frame_count) return;
  const agc_string *name = vm->rt->program->functions[t->frames[0].function].name;
  AGC_TRACE(tr, AGC_TRACE_SCHED, "spawn task=%" PRIu64 " parent=%" PRIu64 " fn=%.*s", t->id, parent,
            agc_trace_len(name->bytes), name->data);
}

static void trace_turn(const agc_vm *vm, const agc_task *t, agc_turn_result r) {
  const agc_trace *tr = &vm->rt->trace;
  if (!AGC_TRACE_ON(tr, AGC_TRACE_SCHED)) return;
  int64_t used = 0;
  if (__builtin_sub_overflow((int64_t)AGC_TURN_STEPS, vm->turn_left, &used) ||
      __builtin_sub_overflow(used, vm->turn_cost_used, &used) || used < 0)
    used = 0;
  const char *why = r == AGC_TURN_DONE ? "done" : r == AGC_TURN_PARKED ? "park" : "yield";
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
  uint64_t task = vm->task ? vm->task->id : 0;
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

agc_outcome agc_vm_run(agc_vm *vm) {
  const agc_trace *tr = &vm->rt->trace;
  if (setjmp(vm->fail) == 0) {
    agc_task_enter(vm, vm->main, vm->rt->program->entry);
    trace_spawn(vm, vm->main, 0);
    enqueue(vm, vm->main);
    for (;;) {
      agc_task *t = dequeue(vm);
      if (!t) {
        if (!agc_io_poll(vm, true)) {
          AGC_TRACE(tr, AGC_TRACE_SCHED, "stall pending=%" PRIu64, pending_tasks(vm) + 1);
          agc_fail(vm, "RUNTIME-INTERNAL", "every task is waiting and nothing can wake them", 0);
        }
        continue;
      }
      vm->task = t;
      t->state = AGC_TASK_RUNNING;
      agc_turn_begin(vm);
      resume(vm, t);
      agc_turn_result r = agc_turn_charge(vm) ? AGC_TURN_YIELD : agc_run_turn(vm);
      agc_turn_finish(vm);
      trace_turn(vm, t, r);
      trace_gc(vm, "turn");
      if (r == AGC_TURN_DONE) {
        if (t == vm->main) {
          AGC_TRACE(tr, AGC_TRACE_SCHED, "cancel pending=%" PRIu64, pending_tasks(vm));
          break;
        }
        finish_task(vm, t);
      } else if (r == AGC_TURN_YIELD) {
        enqueue(vm, t);
      }
      agc_io_poll(vm, false);
    }
    vm->rt->outcome.kind = AGC_DONE;
  }
  trace_end(vm);
  return vm->rt->outcome;
}

static agc_value builtin_spawn(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_task *child = agc_new_task(vm);
  agc_random_seed(&child->random, agc_random_next(&vm->task->random));
  child->input_seen = vm->rt->in.eof_seq;
  agc_task_call(vm, child, args[0], args[1], span);
  trace_spawn(vm, child, vm->task->id);
  enqueue(vm, child);
  return agc_task_value(child);
}

static agc_value builtin_await(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_task *target = agc_as_task(vm, args[0]);
  if (target->state == AGC_TASK_DONE) return target->result;
  agc_task_enqueue(&target->waiters, &target->waiters_tail, vm->task);
  agc_task_park(vm, true);
  return agc_void();
}

static agc_value slept(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)data;
  (void)context;
  return agc_void();
}

static const agc_io_kind sleep_io = {NULL, slept, slept, NULL, false, "sleep"};

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

const agc_builtin agc_task_builtins[] = {
  {"Task.spawn", 2, builtin_spawn, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Task.await", 1, builtin_await, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Task.sleep", 1, builtin_sleep, AGC_NATIVE_NONE, AGC_COST_NONE},
};

const size_t agc_task_builtin_count = sizeof agc_task_builtins / sizeof agc_task_builtins[0];
