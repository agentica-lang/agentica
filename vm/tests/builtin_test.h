#ifndef AGC_BUILTIN_TEST_H
#define AGC_BUILTIN_TEST_H

#include "../core.h"

#include <assert.h>
#include <setjmp.h>
#include <stdio.h>
#include <string.h>

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

/* The code of the failure (agc_fail) of a call of builtin, or "nothing" when it returns. No local lives across the
   setjmp. */
static inline const char *agc_test_fail_code(agc_vm *vm, const agc_builtin *builtin, agc_value *args) {
  if (setjmp(vm->fail) != 0) return vm->outcome->code;
  (void)builtin->fn(vm, args, 0);
  return "nothing";
}

/* A call of builtin (named name) that must fail (agc_fail) with code; it asserts and says what came instead. */
static inline void agc_test_fails(agc_vm *vm, const char *name, const agc_builtin *builtin, agc_value *args,
                                  const char *code) {
  assert(builtin);
  const char *got = agc_test_fail_code(vm, builtin, args);
  if (strcmp(got, code) != 0) fprintf(stderr, "%s/%u: got %s, expected %s\n", name, builtin->arity, got, code);
  assert(strcmp(got, code) == 0);
}

#endif
