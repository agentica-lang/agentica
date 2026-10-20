/* Test support for the C tests where the test's thread plays the I/O thread and a second thread plays a scheduler
   (job, net): the hop to that thread, the loop's pumping and close, and the hand-over of a detached job. */
#ifndef AGC_IO_HARNESS_H
#define AGC_IO_HARNESS_H

#include "../core.h"

#include <assert.h>
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
