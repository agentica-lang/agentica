/* Test support for the C tests where the test's thread plays the I/O thread and a second thread plays a scheduler
   (job, net): the hop to that thread, the loop's pumping and close, and the hand-over of a detached job. */
#ifndef AGC_IO_HARNESS_H
#define AGC_IO_HARNESS_H

#include "../core.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <uv.h>

typedef struct {
  void (*fn)(void *arg);
  void *arg;
} agc_test_hop;

/* What the second thread runs, with the registration the garbage collector needs. */
static inline void agc_test_hop_main(void *arg) {
  agc_test_hop *h = arg;
  assert(agc_gc_thread_enter());
  h->fn(h->arg);
  agc_gc_thread_leave();
}

/* Runs FN on a second thread and waits for it: the thread plays a scheduler, and the loop's thread (the caller) does
   not touch the VM meanwhile. */
static inline void agc_test_on_thread(void (*fn)(void *arg), void *arg) {
  agc_test_hop h = {fn, arg};
  uv_thread_t thread;
  assert(uv_thread_create(&thread, agc_test_hop_main, &h) == 0);
  assert(uv_thread_join(&thread) == 0);
}

/* A builtin call made on the scheduler thread for one task. agc_test_call_of fills the first four arguments; a call of
   more sets the others itself. */
typedef struct {
  agc_vm *vm;
  agc_task *task;
  const char *name;
  uint32_t arity;
  agc_value args[6];
  agc_value result;
  bool parked;
} agc_test_call;

static inline agc_test_call agc_test_call_of(agc_vm *vm, agc_task *task, const char *name, uint32_t arity,
                                             agc_value a, agc_value b, agc_value c, agc_value d) {
  agc_test_call made;
  memset(&made, 0, sizeof made);
  made.vm = vm;
  made.task = task;
  made.name = name;
  made.arity = arity;
  made.args[0] = a;
  made.args[1] = b;
  made.args[2] = c;
  made.args[3] = d;
  return made;
}

/* Calls the builtin as a scheduler does (run it with agc_test_on_thread). A call made while its task is parked (a
   close beside a waiting read) leaves the task as it is, as a second task's call would. */
static inline void agc_test_call_builtin(void *arg) {
  agc_test_call *c = arg;
  const agc_builtin *b = agc_find_builtin((const uint8_t *)c->name, strlen(c->name), c->arity);
  assert(b);
  c->vm->task = c->task;
  bool beside = c->task->parked != NULL;
  if (!beside) {
    atomic_store(&c->task->state, AGC_TASK_RUNNING);
    c->task->parking = false;
  }
  c->result = b->fn(c->vm, c->args, 0);
  c->parked = !beside && c->task->parked != NULL;
  if (c->parked) {
    assert(c->task->parking);
    c->task->parking = false;
    assert(agc_task_commit_park(c->task));
  }
}

/* Starts the call on the scheduler thread; true when its task parked on a job (the START is in the inbox). */
static inline bool agc_test_start(agc_test_call *c) {
  agc_test_on_thread(agc_test_call_builtin, c);
  return c->parked;
}

/* Runs the loop until the task wakes, and empties the run queue. */
static inline void agc_test_wait_woken(agc_vm *vm, agc_task *task) {
  while (task->state == AGC_TASK_PARKED) assert(agc_io_poll(vm, true));
  while (agc_runq_pop(vm->rt->runq)) {}
}

static inline void agc_test_take_on_thread(void *arg) {
  agc_test_call *c = arg;
  c->vm->task = c->task;
  atomic_store(&c->task->state, AGC_TASK_RUNNING);
  c->result = agc_io_finish(c->vm, c->task);
  assert(!c->task->parked);
}

/* The task, resumed on the scheduler thread, ends its job there: the `done` or `expired` half runs on that thread. */
static inline agc_value agc_test_take(agc_test_call *c) {
  agc_test_on_thread(agc_test_take_on_thread, c);
  return c->result;
}

/* Starts the runtime for a VM whose loop runs on the test's thread while other threads call builtins. */
static inline void agc_test_io_vm(agc_vm *vm) {
  agc_init();
  agc_gc_allow_threads();
  agc_io_init();
  agc_vm_init(vm, NULL, stdout, stderr, INT64_MAX);
}

/* Closes the loop, running what is still queued; the run's loop is gone afterwards. */
static inline void agc_test_settle_loop(agc_vm *vm) {
  bool closed = false;
  for (int attempt = 0; attempt < 500 && !closed; attempt++) closed = agc_io_close(vm);
  assert(closed && vm->rt->loop == NULL);
}

static inline void agc_test_pump_until_idle(agc_vm *vm) {
  while (uv_loop_alive(agc_io_uv(vm))) (void)agc_io_poll(vm, true);
}

static inline void agc_test_count_timers(uv_handle_t *handle, void *arg) {
  if (handle->type == UV_TIMER && uv_is_active(handle)) *(uint64_t *)arg += 1;
}

/* How many job timers are armed on the loop. */
static inline uint64_t agc_test_armed_timers(agc_vm *vm) {
  uint64_t count = 0;
  uv_walk(agc_io_uv(vm), agc_test_count_timers, &count);
  return count;
}

/* Runs the loop until the I/O role hands a detached job to the schedulers (the run queue's nudge), and takes the
   nudge. */
static inline void agc_test_wait_for_hand_over(agc_vm *vm) {
  while (!agc_runq_nudged(vm->rt->runq)) assert(agc_io_poll(vm, true));
  assert(agc_runq_take_nudge(vm->rt->runq));
}

/* On the scheduler's thread: ends the jobs handed over, and finds none left. */
static inline void agc_test_service(agc_vm *vm) {
  assert(agc_io_service(vm));
  assert(!agc_io_service(vm));
}

#endif
