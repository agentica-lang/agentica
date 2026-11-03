#ifndef AGC_BUILTIN_TEST_H
#define AGC_BUILTIN_TEST_H

#include "../core.h"

#include <assert.h>
#include <setjmp.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#if defined(__SANITIZE_ADDRESS__)
#define AGC_TEST_ASAN 1
#elif defined(__has_feature)
#if __has_feature(address_sanitizer)
#define AGC_TEST_ASAN 1
#endif
#endif
#if AGC_TEST_ASAN
/* From <sanitizer/asan_interface.h>, declared here because clang-tidy may not find the compiler's own headers. */
void *__asan_get_current_fake_stack(void);
void *__asan_addr_is_in_fake_stack(void *fake_stack, void *addr, void **beg, void **end);
#endif

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

/* True when P points into the C stack below the caller's frame, where the frames of a call that just failed were (the
   stack grows down on every platform the VM supports; 64 KB is deeper than any failing builtin goes), or, under ASan,
   into the fake stack that holds the locals of instrumented frames. */
static __attribute__((noinline, unused)) bool agc_test_on_dead_stack(const void *p) {
  uintptr_t at = (uintptr_t)p, frame = (uintptr_t)__builtin_frame_address(0);
  if (at < frame && frame - at < 65536) return true;
#if AGC_TEST_ASAN
  if (__asan_addr_is_in_fake_stack(__asan_get_current_fake_stack(), (void *)(uintptr_t)p, NULL, NULL)) return true;
#endif
  return false;
}

/* A call of builtin (named name) that must fail (agc_fail) with code; it asserts and says what came instead. */
static inline void agc_test_fails(agc_vm *vm, const char *name, const agc_builtin *builtin, agc_value *args,
                                  const char *code) {
  assert(builtin);
  const char *got = agc_test_fail_code(vm, builtin, args);
  /* agc_fail keeps only the pointer to its message and longjmps, so a message built in a stack buffer of the failed
     call is dead before the driver prints it (#1029). */
  if (strcmp(got, "nothing") != 0) assert(!agc_test_on_dead_stack(vm->outcome->message));
  if (strcmp(got, code) != 0) fprintf(stderr, "%s/%u: got %s, expected %s\n", name, builtin->arity, got, code);
  assert(strcmp(got, code) == 0);
}

#endif
