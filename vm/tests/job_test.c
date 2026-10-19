/*
 * A job on the loop (docs/vm/16-architecture.md §16.5): a timer against a completion in both orders, a cancel against a
 * completion, and a request that another thread posts to the I/O thread's inbox.
 */
#include "../core.h"
#include "test_support.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <uv.h>

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
typedef struct {
  uv_sem_t entered, go;
  _Atomic int worked;
  int value;
} gate;

static int dropped, finished_calls;

static void gate_work(void *data) {
  gate *g = data;
  uv_sem_post(&g->entered);
  uv_sem_wait(&g->go);
  g->value = 7;
  atomic_store_explicit(&g->worked, 1, memory_order_release);
}

static agc_value gate_done(agc_vm *vm, void *data, agc_value context) {
  gate *g = data;
  finished_calls++;
  int64_t value = g->value + agc_as_int(vm, context);
  uv_sem_destroy(&g->entered);
  uv_sem_destroy(&g->go);
  free(g);
  return agc_int(value);
}

static agc_value gate_expired(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)data;
  (void)context;
  return agc_int(-1);
}

/* Reached after the pool work and the timer are over, so the work has written `value` already. */
static void gate_drop(void *data) {
  gate *g = data;
  assert(g->value == 7);
  uv_sem_destroy(&g->entered);
  uv_sem_destroy(&g->go);
  free(g);
  dropped++;
}

static const agc_io_kind gate_io = {gate_work, gate_done, gate_expired, gate_drop, false, "gate", NULL};

static gate *new_gate(void) {
  gate *g = calloc(1, sizeof *g);
  assert(g && uv_sem_init(&g->entered, 0) == 0 && uv_sem_init(&g->go, 0) == 0);
  return g;
}

static agc_vm vm;

/* The task parks on a gated job, as a builtin would. The pool work waits for the test to open the gate, so which
   event comes first is decided by the test and not by timing. */
static agc_task *park_on(gate *g, int64_t timeout_ms) {
  agc_task *task = vm.task;
  agc_io_start(&vm, &gate_io, g, agc_int(100), timeout_ms);
  assert(task->parked && task->parking);
  task->parking = false;
  task->state = AGC_TASK_PARKED;
  return task;
}

static void wait_woken(agc_task *task) {
  while (task->state == AGC_TASK_PARKED) assert(agc_io_poll(&vm, true));
  while (agc_runq_pop(vm.rt->runq)) {}
}

static int64_t take(agc_task *task) {
  task->state = AGC_TASK_RUNNING;
  agc_value result = agc_io_finish(&vm, task);
  assert(!task->parked);
  return agc_as_int(&vm, result);
}

static void settle_loop(void) {
  bool closed = false;
  for (int attempt = 0; attempt < 500 && !closed; attempt++) closed = agc_io_close(&vm);
  assert(closed && vm.loop == NULL);
}

/* The timer wins while the work is still blocked, and the work ends before the task runs: the first outcome stands,
   so the task sees the timeout. The work's end changes nothing, and its data is dropped once, after it finished. */
static void test_timer_before_completion(void) {
  gate *g = new_gate();
  agc_task *task = park_on(g, 1);
  uv_sem_wait(&g->entered);
  wait_woken(task);
  uv_sem_post(&g->go);
  while (!atomic_load_explicit(&g->worked, memory_order_acquire)) {}
  assert(agc_io_poll(&vm, true));
  assert(take(task) == -1);
  settle_loop();
  assert(dropped == 1 && finished_calls == 0);
  dropped = 0;
}

/* The work ends first: the task gets the result, and a timer that fires before the task runs changes nothing. */
static void test_completion_before_timer(void) {
  gate *g = new_gate();
  uv_sem_post(&g->go);
  agc_task *task = park_on(g, 10);
  wait_woken(task);
  uint64_t due = agc_clock_ms() + 30;
  while (agc_clock_ms() < due) {}
  agc_io_poll(&vm, false);
  assert(take(task) == 107);
  settle_loop();
  assert(dropped == 0 && finished_calls == 1);
  finished_calls = 0;
}

/* A cancel sets the outcome to CANCELLED: a completion that comes later does not wake the task, and the detached
   ending takes the result and frees the job. */
static void test_cancel_before_completion(void) {
  gate *g = new_gate();
  agc_task *task = park_on(g, 60000);
  uv_sem_wait(&g->entered);
  agc_io_detach(&vm, task);
  uv_sem_post(&g->go);
  while (finished_calls == 0) assert(agc_io_poll(&vm, true));
  assert(task->state == AGC_TASK_PARKED && !task->parked);
  settle_loop();
  assert(finished_calls == 1 && dropped == 0);
  finished_calls = 0;
  task->state = AGC_TASK_RUNNING;
}

static agc_value nap_done(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)data;
  (void)context;
  return agc_int(1);
}

static const agc_io_kind nap_io = {NULL, nap_done, nap_done, NULL, false, "nap", NULL};

static void extend_later(void *arg) {
  agc_io_extend(arg, 1);
}

/* Another thread asks to move the timer of a job that waits for a minute. The loop belongs to this thread once the
   inbox exists, so the request goes through the inbox, wakes the loop, and the timer then fires within the test's
   deadline. Without the request the job would wait a minute. */
static void test_request_from_another_thread(void) {
  assert(agc_io_share(&vm, false));
  agc_task *task = vm.task;
  agc_io_job *job = agc_io_start(&vm, &nap_io, NULL, agc_void(), 60000);
  assert(task->parked && task->parking);
  task->parking = false;
  task->state = AGC_TASK_PARKED;
  uv_thread_t thread;
  assert(uv_thread_create(&thread, extend_later, job) == 0);
  wait_woken(task);
  assert(uv_thread_join(&thread) == 0);
  assert(take(task) == 1);
  settle_loop();
}
#endif

int main(void) {
  agc_test_deadline(120);
#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
  agc_init();
  agc_io_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  test_timer_before_completion();
  test_completion_before_timer();
  test_cancel_before_completion();
  test_request_from_another_thread();
#endif
  puts("job tests passed");
  return 0;
}
