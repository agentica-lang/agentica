#include "agc.h"

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

void agc_task_wake(agc_vm *vm, agc_task *t) {
  if (t->state == AGC_TASK_PARKED) enqueue(vm, t);
}

void agc_task_enqueue(agc_task **head, agc_task **tail, agc_task *t) {
  t->next = NULL;
  if (*tail)
    (*tail)->next = t;
  else
    *head = t;
  *tail = t;
}

void agc_task_wake_all(agc_vm *vm, agc_task **head, agc_task **tail) {
  agc_task *t = *head;
  *head = *tail = NULL;
  while (t) {
    agc_task *next = t->next;
    t->next = NULL;
    agc_task_wake(vm, t);
    t = next;
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
  agc_task_wake_all(vm, &t->waiters, &t->waiters_tail);
}

static void resume(agc_vm *vm, agc_task *t) {
  if (t->parked) {
    agc_value result = agc_io_finish(vm, t);
    if (!t->retry) t->regs[t->park_reg] = result;
  }
  t->retry = false;
}

agc_outcome agc_vm_run(agc_vm *vm) {
  if (setjmp(vm->fail) == 0) {
    agc_task_enter(vm, vm->main, vm->rt->program->entry);
    enqueue(vm, vm->main);
    for (;;) {
      agc_task *t = dequeue(vm);
      if (!t) {
        if (!agc_io_poll(vm, true))
          agc_fail(vm, "RUNTIME-INTERNAL", "every task is waiting and nothing can wake them", 0);
        continue;
      }
      vm->task = t;
      t->state = AGC_TASK_RUNNING;
      agc_turn_begin(vm);
      resume(vm, t);
      agc_turn_result r = agc_turn_charge(vm) ? AGC_TURN_YIELD : agc_run_turn(vm);
      agc_turn_finish(vm);
      if (r == AGC_TURN_DONE) {
        if (t == vm->main) break;
        finish_task(vm, t);
      } else if (r == AGC_TURN_YIELD) {
        enqueue(vm, t);
      }
      agc_io_poll(vm, false);
    }
    vm->rt->outcome.kind = AGC_DONE;
  }
  return vm->rt->outcome;
}

static agc_value builtin_spawn(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_task *child = agc_new_task();
  agc_random_seed(&child->random, agc_random_next(&vm->task->random));
  agc_task_call(vm, child, args[0], args[1], span);
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

static const agc_io_kind sleep_io = {NULL, slept, slept, NULL};

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
