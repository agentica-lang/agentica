#ifndef AGC_BUILTIN_TEST_H
#define AGC_BUILTIN_TEST_H

#include "../core.h"

#include <assert.h>

static inline agc_value agc_test_call(agc_vm *vm, agc_task *task, const agc_builtin *builtin, agc_value *args) {
  assert(builtin);
  task->state = AGC_TASK_RUNNING;
  task->parking = false;
  vm->task = task;
  agc_value result = builtin->fn(vm, args, 0);
  if (!task->parking) return result;
  task->parking = false;
  task->state = AGC_TASK_PARKED;
  while (task->state == AGC_TASK_PARKED) assert(agc_io_poll(vm, true));
  while (agc_runq_pop(vm->rt->runq)) {}
  task->state = AGC_TASK_RUNNING;
  return agc_io_finish(vm, task);
}

#endif
